#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

uv sync --frozen
uv run ruff format --check
uv run ruff check
uv run basedpyright
uv run pytest -q
helm lint --strict chart
helm template temp-poc chart --namespace scalex-temp-poc > "$tmp/rendered.yaml"
scripts/validate-render.sh "$tmp/rendered.yaml"
tests/test-chart-layout.sh
tests/test-promotion-scripts.sh
tests/test-promotion-workflow.sh
tests/test-publish-promotion-artifact.sh
git diff --check
