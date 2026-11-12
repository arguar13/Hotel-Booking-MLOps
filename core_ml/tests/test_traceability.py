import subprocess
from pathlib import Path

import src.traceability as traceability
from src.traceability import get_container_image_tag, get_dvc_data_hash, get_git_commit_hash


def test_get_git_commit_hash_prefers_ci_env_var(monkeypatch) -> None:
    monkeypatch.setenv("CI_COMMIT_SHA", "abc123")
    assert get_git_commit_hash() == "abc123"


def test_get_git_commit_hash_falls_back_to_git(monkeypatch) -> None:
    # git is stubbed so the test does not depend on the state of the checkout
    # (a repository with no commits yet has no HEAD to resolve).
    monkeypatch.delenv("CI_COMMIT_SHA", raising=False)
    fake_sha = "a" * 40
    calls = []

    def fake_run(argv, **kwargs):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, stdout=fake_sha + "\n", stderr="")

    monkeypatch.setattr(traceability.subprocess, "run", fake_run)
    assert get_git_commit_hash() == fake_sha
    assert calls == [["git", "rev-parse", "HEAD"]]


def test_get_git_commit_hash_is_unknown_when_git_fails(monkeypatch) -> None:
    monkeypatch.delenv("CI_COMMIT_SHA", raising=False)

    def failing_run(argv, **kwargs):
        raise subprocess.CalledProcessError(128, argv)

    monkeypatch.setattr(traceability.subprocess, "run", failing_run)
    assert get_git_commit_hash() == "unknown"


def test_get_container_image_tag_defaults_to_local_dev(monkeypatch) -> None:
    monkeypatch.delenv("CI_COMMIT_SHA", raising=False)
    monkeypatch.delenv("IMAGE_TAG", raising=False)
    assert get_container_image_tag() == "local-dev"


def test_get_container_image_tag_reads_ci_commit_sha(monkeypatch) -> None:
    monkeypatch.setenv("CI_COMMIT_SHA", "deadbeef")
    assert get_container_image_tag() == "deadbeef"


def test_get_dvc_data_hash_reads_dvc_add_sidecar(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.chdir(tmp_path)
    (tmp_path / "data.csv.dvc").write_text("outs:\n- md5: deadbeefcafe\n  path: data.csv\n")

    assert get_dvc_data_hash("data.csv") == "deadbeefcafe"


def test_get_dvc_data_hash_reads_pipeline_lock(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.chdir(tmp_path)
    (tmp_path / "dvc.lock").write_text(
        "schema: '2.0'\n"
        "stages:\n"
        "  clean_data:\n"
        "    outs:\n"
        "    - path: data/processed.csv\n"
        "      md5: feedface1234\n"
    )

    assert get_dvc_data_hash("data/processed.csv") == "feedface1234"


def test_get_dvc_data_hash_returns_unknown_when_untracked(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.chdir(tmp_path)
    assert get_dvc_data_hash("nonexistent.csv") == "unknown"
