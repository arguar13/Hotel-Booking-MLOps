FROM mcr.microsoft.com/devcontainers/python:1-3.12-bullseye

# --no-install-recommends: otherwise apt pulls in dozens of suggested packages
# nobody uses, growing the image and its attack surface.
RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client awscli \
    && rm -rf /var/lib/apt/lists/*

# The devcontainers base image ships the non-root `vscode` user that VS Code
# connects as. Poetry is installed for that user, not root, so the project's
# virtualenv belongs to it.
USER vscode
ENV PATH="/home/vscode/.local/bin:$PATH"

RUN curl -sSL https://install.python-poetry.org | python3 -

# .venv inside the project, where VS Code finds the interpreter on its own
RUN poetry config virtualenvs.in-project true
