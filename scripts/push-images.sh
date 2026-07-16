#!/usr/bin/env bash
set -euo pipefail

revision=${1:?40-character source revision is required}
for component in dataset-ingest batch-analyzer report-generator; do
  docker push "docker.io/belltigerlee/temp-poc-${component}:sha-${revision}"
done
