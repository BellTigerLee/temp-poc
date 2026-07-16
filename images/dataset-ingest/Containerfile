FROM ghcr.io/astral-sh/uv:0.11.16@sha256:440fd6477af86a2f1b38080c539f1672cd22acb1b1a47e321dba5158ab08864d AS uv
FROM python:3.13.11-slim-bookworm@sha256:20080e807bfc404f8450b185cf0fc95d553462673598549613735f70a5b4d5d0 AS builder
ENV UV_PROJECT_ENVIRONMENT=/opt/venv UV_LINK_MODE=copy UV_NO_CACHE=1
WORKDIR /build
COPY --from=uv /uv /uvx /bin/
COPY pyproject.toml uv.lock README.md ./
COPY src ./src
RUN uv sync --frozen --no-dev --no-editable

FROM python:3.13.11-slim-bookworm@sha256:20080e807bfc404f8450b185cf0fc95d553462673598549613735f70a5b4d5d0
ENV HOME=/tmp PATH=/opt/venv/bin:$PATH PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY --from=builder /opt/venv /opt/venv
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["temp-poc-dataset-ingest"]
