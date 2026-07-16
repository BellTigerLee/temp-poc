#!/usr/bin/env bash
set -euo pipefail

revision=${1:?40-character source revision is required}
case "$revision" in
  (*[!0-9a-f]*|'') echo "source revision must be lowercase hexadecimal" >&2; exit 2 ;;
esac
[ "${#revision}" -eq 40 ] || { echo "source revision must contain 40 characters" >&2; exit 2; }

for component in dataset-ingest batch-analyzer report-generator; do
  image="docker.io/belltigerlee/temp-poc-${component}:sha-${revision}"
  docker build --file "images/${component}/Containerfile" --tag "$image" .
done
