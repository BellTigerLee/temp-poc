#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 6 ] || {
  echo "unexpected docker argument count" >&2
  exit 1
}
[ "$1 $2 $3" = "buildx imagetools inspect" ] || {
  echo "unexpected docker command" >&2
  exit 1
}
[ "$5" = --format ] || {
  echo "missing digest format" >&2
  exit 1
}
[ "$6" = '{{json .Manifest}}' ] || {
  echo "unexpected digest format" >&2
  exit 1
}

case "$4" in
  */temp-poc-dataset-ingest:*) digit=1 ;;
  */temp-poc-batch-analyzer:*) digit=2 ;;
  */temp-poc-report-generator:*) digit=3 ;;
  *)
    echo "unexpected image reference: $4" >&2
    exit 1
    ;;
esac
printf '{"digest":"sha256:%064d"}\n' "$digit"
