#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ ! -d "$ROOT/chart/templates/karmada" ] || {
  echo "legacy chart/templates/karmada directory must not exist" >&2
  exit 1
}

for file in \
  chart/templates/policy/propagation/batch-analyzer.yaml \
  chart/templates/policy/propagation/dataset-ingest.yaml \
  chart/templates/policy/propagation/report-generator.yaml \
  chart/templates/policy/overrides/services.yaml; do
  [ -f "$ROOT/$file" ] || {
    echo "missing policy template: $file" >&2
    exit 1
  }
done

echo "chart policy layout passed"
