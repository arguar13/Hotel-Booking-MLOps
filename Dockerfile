FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    POETRY_VERSION=2.4.1

WORKDIR /app
ENV PYTHONPATH="/app/api"

# Optional local CA trust, only for machines behind a corporate/antivirus proxy
# that intercepts outbound TLS. `docker/local-c[a].crt` is a glob, so COPY
# matches nothing when the file is absent. A plain COPY rather than
# `--mount=type=secret` because the build must also work through
# testcontainers (Docker Engine API, no BuildKit secrets); a CA certificate is
# public data, so baking it into a layer leaks nothing. No-op in CI, where only
# the empty placeholder exists.
COPY docker/local-ca-placeholder.crt docker/local-c[a].crt /tmp/local-ca/
RUN sh -c 'for f in /tmp/local-ca/*; do [ -s "$f" ] && cp "$f" /usr/local/share/ca-certificates/local-ca.crt; done; update-ca-certificates; rm -rf /tmp/local-ca'
ENV PIP_CERT=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# Same Poetry that wrote poetry.lock: lock-version 2.1 needs Poetry >= 2.
RUN pip install --no-cache-dir poetry==$POETRY_VERSION

COPY api/pyproject.toml api/poetry.lock* ./
RUN poetry config virtualenvs.create false \
    && poetry install --only main --no-interaction --no-ansi --no-root

COPY api/ ./api/

# Serve as an unprivileged user. UID 1000 is fixed on purpose: it is what
# kubernetes/base/api.yaml's securityContext (runAsUser/runAsNonRoot) expects,
# and the kubelet rejects the pod if the image's user turns out to be root.
RUN useradd --create-home --uid 1000 appuser \
    && chown -R appuser:appuser /app
USER appuser

EXPOSE 8000
CMD ["uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000"]
