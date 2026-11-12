import asyncio
import logging
import os
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

# MLflow's HTTP client retries with its own backoff (5 attempts by default).
# Stacked under the tenacity retry in _load_model_with_retry, that turns a few
# bounded seconds into minutes, so the inner layer gets one attempt and
# tenacity owns the whole retry budget.
os.environ.setdefault("MLFLOW_HTTP_REQUEST_MAX_RETRIES", "1")

import mlflow.sklearn
import numpy as np
import pandas as pd
import psycopg2
import pybreaker
import structlog
from fastapi import FastAPI, HTTPException, Response, status
from mlflow.tracking import MlflowClient
from tenacity import retry, retry_if_exception_type, stop_after_attempt, wait_exponential

from monitoring import (
    FLUSH_INTERVAL_SECONDS,
    inference_logger,
    jsonable_features,
    new_prediction_id,
)
from schemas import BookingFeatures, LabelIngest, LabelIngestResponse, PredictionResponse

# One JSON object per line (timestamp, level, event, call-site context), ready
# for CloudWatch Logs / Elasticsearch without a parser.
structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.add_log_level,
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.processors.JSONRenderer(),
    ],
    wrapper_class=structlog.make_filtering_bound_logger(logging.INFO),
    logger_factory=structlog.PrintLoggerFactory(),
    cache_logger_on_first_use=True,
)
log = structlog.get_logger("hotel_mlops.api")

model = None

# The concrete registry version behind the alias, stored with every logged
# prediction: a promotion landing mid-window would otherwise mix two models in
# one drift statistic without anyone being able to tell.
model_version: str | None = None

# The Model Registry is the only source of the serving model (no local
# fallback), and only versions that passed the quality gate get the alias.
# Aliases, not the deprecated stages API.
MODEL_NAME = os.getenv("MODEL_REGISTRY_NAME", "HotelSegmentClassifier")
MODEL_ALIAS = os.getenv("MODEL_REGISTRY_ALIAS", "staging")

# How long to wait between attempts while there is still no model at all.
MODEL_RETRY_SECONDS = float(os.getenv("MODEL_RETRY_SECONDS", "15"))
# How often to re-read the alias once a model *is* loaded, to pick up a newly
# promoted version without a pod restart. 0 disables that (load once and stop).
MODEL_REFRESH_SECONDS = float(os.getenv("MODEL_REFRESH_SECONDS", "0"))


@retry(
    reraise=True,
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=2, max=10),
    retry=retry_if_exception_type(Exception),
)
def _load_model_with_retry(model_uri: str):
    """At most 3 attempts, capped exponential backoff - bounded, not infinite.

    A transient blip (registry mid-restart, brief network partition) self-heals
    without a full pod restart; a genuinely down registry still fails within
    seconds rather than hanging the container's startup indefinitely.
    """
    return _single_threaded(mlflow.sklearn.load_model(model_uri))


def _single_threaded(model):
    """Serve with n_jobs=1 on every estimator that has the parameter.

    The forest is trained with n_jobs=-1, which is right for fitting but not
    for serving: joblib sizes its thread pool from the cores the container
    can see, not from its CPU limit (500m), so concurrent requests would each
    start a pool and compete for half a core. A single-row prediction gains
    nothing from parallel trees (measured: same p50 at 0.5 CPU), so serving
    keeps one thread per request and lets uvicorn handle the concurrency.
    """
    n_jobs_params = {name: 1 for name in model.get_params() if name.endswith("n_jobs")}
    if n_jobs_params:
        model.set_params(**n_jobs_params)
    return model


def _resolve_model_version() -> str | None:
    """Ask the registry which version the served alias points at right now.

    Best effort by design: the API can serve perfectly well without knowing the
    version number, so a registry hiccup here degrades the *attribution* of a
    logged prediction, never the prediction itself.
    """
    try:
        return str(MlflowClient().get_model_version_by_alias(MODEL_NAME, MODEL_ALIAS).version)
    except Exception as e:  # noqa: BLE001
        log.warning("model_version_lookup_failed", alias=MODEL_ALIAS, error=str(e))
        return None


def _model_uri(version: str | None) -> str:
    """Pin the load to a concrete version whenever it is known.

    Loading `@alias` and asking which version it points at are two separate
    registry calls; a promotion landing between them would record the wrong
    version for every prediction this replica serves.
    """
    if version is not None:
        return f"models:/{MODEL_NAME}/{version}"
    return f"models:/{MODEL_NAME}@{MODEL_ALIAS}"


def load_model() -> None:
    """
    Loads the model version currently aliased MODEL_ALIAS from the MLflow
    Model Registry. If the registry is unreachable or has no version under
    that alias, `model` stays None and /predict fails explicitly with a 503
    instead of silently serving a stale, untracked local artifact.
    """
    global model, model_version

    tracking_uri = os.getenv("MLFLOW_TRACKING_URI", "http://mlflow-service:5000")
    mlflow.set_tracking_uri(tracking_uri)

    target_version = _resolve_model_version()
    model_uri = _model_uri(target_version)
    try:
        log.info("model_load_attempt", model_uri=model_uri)
        model = _load_model_with_retry(model_uri)
        model_version = target_version
        log.info("model_load_succeeded", model_uri=model_uri, model_version=model_version)
    except Exception as e:
        log.error(
            "model_load_failed",
            model_uri=model_uri,
            error=str(e),
            note="will keep retrying in the background; /ready stays 503 until it loads",
        )


async def _model_loader_loop() -> None:
    """Retry the load while there is no model; then, optionally, follow the alias.

    Every rollout restarts the api and mlflow Deployments together, so the api
    often starts before the tracking server is up. With only the three bounded
    attempts above it would then serve 503 forever while /health stays 200, and
    Kubernetes would never restart it.

    With MODEL_REFRESH_SECONDS > 0 it also picks up a newly promoted version: a
    cheap alias lookup every interval, and a download only when it changed.
    """
    global model, model_version

    while True:
        if model is None:
            delay = MODEL_RETRY_SECONDS
        elif MODEL_REFRESH_SECONDS > 0:
            delay = MODEL_REFRESH_SECONDS
        else:
            return  # loaded, and refreshing is disabled - nothing left to do
        await asyncio.sleep(delay)

        # to_thread: mlflow's client is blocking, and this coroutine shares the
        # event loop that serves requests.
        target_version = await asyncio.to_thread(_resolve_model_version)
        if model is not None and (target_version is None or target_version == model_version):
            continue

        model_uri = _model_uri(target_version)
        try:
            loaded = await asyncio.to_thread(_load_model_with_retry, model_uri)
        except Exception as e:
            log.warning("model_load_retry_failed", model_uri=model_uri, error=str(e))
            continue
        was_missing = model is None
        model, model_version = loaded, target_version
        log.info(
            "model_load_succeeded" if was_missing else "model_refreshed",
            model_uri=model_uri,
            model_version=model_version,
        )


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    """Startup: load the model, open the prediction-log sink, start both loops.

    Shutdown: flush what is still queued. Delivery is at-most-once by design
    (see monitoring.py), so a batch lost to a hard kill is acceptable; dropping
    a full queue on every routine rollout, when draining it costs one write, is not.
    """
    await asyncio.to_thread(load_model)
    background: list[asyncio.Task] = []
    if model is None or MODEL_REFRESH_SECONDS > 0:
        background.append(asyncio.create_task(_model_loader_loop()))

    await asyncio.to_thread(inference_logger.start)
    if inference_logger.enabled:
        background.append(asyncio.create_task(_inference_log_flush_loop()))

    try:
        yield
    finally:
        for task in background:
            task.cancel()
        await asyncio.to_thread(inference_logger.close)


app = FastAPI(
    title="Hotel Market Segmentation API",
    description="MLOps API for multiclass market segment classification",
    version="1.0.0",
    lifespan=lifespan,
)


async def _inference_log_flush_loop() -> None:
    """Batch-drain the prediction queue on a fixed interval, forever.

    Runs on the same event loop that serves requests, so the blocking database
    write is pushed to a worker thread. `flush()` never raises, so this loop
    cannot die and silently stop persisting predictions - the failure mode that
    would make a drift report quietly describe a shrinking, unrepresentative
    sample instead of reporting that it had no data.
    """
    while True:
        await asyncio.sleep(FLUSH_INTERVAL_SECONDS)
        await asyncio.to_thread(inference_logger.flush)


@app.get("/health")
def health():
    """
    Liveness probe target: is the process itself alive and serving?

    Deliberately still 200 with `model_loaded=False`. A missing model is not a
    reason to kill the container - the background loader is retrying, and a
    restart would only make it start over. Readiness is what gates traffic; see
    /ready.
    """
    return {
        "status": "ok",
        "model_loaded": model is not None,
        "model_alias": MODEL_ALIAS,
        "model_version": model_version,
        # A degraded prediction sink must not fail readiness, but it silently
        # starves the drift check of data. `rows_dropped` climbing is the
        # signal that the next drift check will run on an unrepresentative
        # sample.
        "inference_logging": inference_logger.stats(),
    }


@app.get("/ready")
def ready(response: Response):
    """
    Readiness probe target: can this replica actually answer /predict?

    Returns 503 until a model is loaded, so Kubernetes keeps the pod out of the
    Service's endpoints instead of load-balancing requests onto a replica that
    can only answer 503. During a rollout that is the difference between a few
    seconds of one replica serving and clients seeing real errors.
    """
    if model is None:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "not_ready", "reason": "model not loaded yet"}
    return {"status": "ready", "model_alias": MODEL_ALIAS}


def _predict_with_confidence(
    estimator: Any, input_data: pd.DataFrame
) -> tuple[str, float | None, float | None]:
    """Predict one row, returning the label plus its two uncertainty signals.

    `confidence` is the winning class probability; `margin` is the gap to the
    runner-up. Both are the standard unsupervised early-warning signals for
    concept drift: ground truth arrives with a reconciliation delay, so for as
    long as a window is unlabelled these are the only evidence available that
    the decision boundary no longer fits the traffic. Confidence alone is not
    enough - a model can stay confident while flipping between two classes it
    can no longer separate, and only the margin shows that.

    One forward pass, not two: for every scikit-learn classifier `predict` is
    defined as `classes_[argmax(predict_proba)]`, so taking the argmax here is
    identical to calling `predict` and half the work. Estimators without
    `predict_proba` (or without `classes_`) fall back to a plain label rather
    than failing - degrading the monitoring signal, never the endpoint.
    """
    predict_proba = getattr(estimator, "predict_proba", None)
    classes = getattr(estimator, "classes_", None)
    if predict_proba is None or classes is None:
        return str(estimator.predict(input_data)[0]), None, None

    probabilities = predict_proba(input_data)[0]
    ranked = np.argsort(probabilities)[::-1]
    confidence = float(probabilities[ranked[0]])
    runner_up = float(probabilities[ranked[1]]) if len(ranked) > 1 else 0.0
    return str(classes[ranked[0]]), confidence, confidence - runner_up


@app.post("/predict", response_model=PredictionResponse)
def predict_segment(features: BookingFeatures):
    """
    Predicts the market segment based on booking features.

    The response carries a `prediction_id`: quote it back on POST /feedback once
    the booking's true segment is known, and this prediction becomes part of the
    logged sample the drift check reads.
    """
    estimator = model
    if estimator is None:
        raise HTTPException(status_code=503, detail="Model is currently unavailable.")

    feature_map = features.model_dump()
    try:
        input_data = pd.DataFrame([feature_map])
        predicted_segment, confidence, margin = _predict_with_confidence(estimator, input_data)
    except Exception as e:
        # The full error goes to the log; the client gets a generic message
        # rather than a stack-trace fragment from inside the pipeline. Input
        # validation already happened in the schema, so reaching this is a
        # server-side problem (model/schema mismatch), hence 500, not 400.
        log.error("prediction_failed", error=str(e), model_version=model_version)
        raise HTTPException(status_code=500, detail="Prediction failed.") from e

    prediction_id = new_prediction_id()

    log.info(
        "prediction_succeeded",
        prediction_id=prediction_id,
        predicted_market_segment=predicted_segment,
        confidence=confidence,
        model_version=model_version,
    )

    # Non-blocking and non-fatal by construction: this is an in-memory
    # enqueue, flushed to Postgres in the background (see monitoring.py).
    inference_logger.record_prediction(
        prediction_id=prediction_id,
        model_name=MODEL_NAME,
        model_alias=MODEL_ALIAS,
        model_version=model_version,
        predicted_segment=predicted_segment,
        confidence=confidence,
        margin=margin,
        features=jsonable_features(feature_map),
    )

    return PredictionResponse(
        predicted_market_segment=predicted_segment,
        prediction_id=prediction_id,
        model_version=model_version,
        confidence=confidence,
        margin=margin,
    )


@app.post("/feedback", response_model=LabelIngestResponse, status_code=status.HTTP_202_ACCEPTED)
async def ingest_labels(labels: list[LabelIngest]):
    """Record the ground-truth segment for predictions already served.

    Delayed labels are what let the monitor measure concept drift (P(y|X)), not
    only data drift (P(X)): a booking's segment is settled when the reservation
    is reconciled against its channel, hours to days later, and a nightly job
    posts it here in batches.

    Unlike /predict the write is synchronous: labels are low-volume, come from a
    job that can retry, and an accuracy computed after silently losing a biased
    subset of them would mislead. A failure is a 503; the upsert is idempotent,
    so re-posting a whole batch is safe.
    """
    if not labels:
        return LabelIngestResponse(accepted=0, skipped=0)

    if not inference_logger.enabled:
        raise HTTPException(
            status_code=503,
            detail="Inference logging is disabled; there is no prediction log to label.",
        )

    # Drain this replica's pending predictions first. Predictions are persisted
    # asynchronously, so a caller that reconciles quickly can hold an id that has
    # not reached the table yet; flushing here closes that window for everything
    # this pod served. It cannot close it for a sibling replica, which is why
    # `skipped` exists and why the caller is expected to re-post.
    await asyncio.to_thread(inference_logger.flush)

    try:
        accepted = await asyncio.to_thread(
            inference_logger.record_labels,
            [
                (item.prediction_id, item.actual_market_segment, item.label_source)
                for item in labels
            ],
        )
    except pybreaker.CircuitBreakerError as e:
        log.warning("label_ingest_skipped", reason="circuit breaker open", count=len(labels))
        raise HTTPException(
            status_code=503, detail="Monitoring store unavailable; retry this batch."
        ) from e
    except (psycopg2.Error, OSError, RuntimeError) as e:
        log.error("label_ingest_failed", error=str(e), count=len(labels))
        raise HTTPException(status_code=503, detail="Could not record labels.") from e

    skipped = len(labels) - accepted
    if skipped:
        # Either the prediction is still queued somewhere, or the id was never
        # served at all. Both are the caller's cue to re-post the batch, which is
        # safe: the write is an idempotent upsert.
        log.info("label_ingest_partial", accepted=accepted, skipped=skipped)
    else:
        log.info("label_ingest_succeeded", accepted=accepted)
    return LabelIngestResponse(accepted=accepted, skipped=skipped)
