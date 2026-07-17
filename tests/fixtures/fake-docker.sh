#!/usr/bin/env bash
set -euo pipefail

[ "$1 $2 $3" != "buildx imagetools inspect" ] || {
  echo 'ERROR: failed to do request: Head "https://registry.example.com/v2/": connection refused' >&2
  exit 1
}
[ "$#" -eq 5 ] || {
  echo "unexpected docker argument count" >&2
  exit 1
}
[ "$1 $2" = "image inspect" ] || {
  echo "unexpected docker command" >&2
  exit 1
}
[ "$4" = --format ] || {
  echo "missing digest format" >&2
  exit 1
}
[ "$5" = '{{json .RepoDigests}}' ] || {
  echo "unexpected digest format" >&2
  exit 1
}

case "$3" in
  */temp-poc-dataset-ingest:*) digit=1 ;;
  */temp-poc-batch-analyzer:*) digit=2 ;;
  */temp-poc-report-generator:*) digit=3 ;;
  *)
    echo "unexpected image reference: $3" >&2
    exit 1
    ;;
esac
repository="${3%:*}"
printf '["%s@sha256:%064d"]\n' "$repository" "$digit"
