#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
revision=1111111111111111111111111111111111111111

FAKE_DOCKER_LOG="$tmp/docker.log" DOCKER_BIN="$ROOT/tests/fixtures/fake-docker.sh" \
  IMAGE_REGISTRY=registry.example.com/team \
  "$ROOT/scripts/build-images.sh" --push --latest "$revision"
[ "$(grep -c '^build ' "$tmp/docker.log")" -eq 3 ]
[ "$(grep -c '^push ' "$tmp/docker.log")" -eq 6 ]
[ "$(grep -c '^tag ' "$tmp/docker.log")" -eq 3 ]
grep -Fq 'temp-poc-dataset-ingest:latest' "$tmp/docker.log"

DOCKER_BIN="$ROOT/tests/fixtures/fake-docker.sh" \
  IMAGE_REGISTRY=registry.example.com/team \
  "$ROOT/scripts/create-promotion-payload.sh" "$tmp/promotion.json" "$revision" >/dev/null

jq -e --arg revision "$revision" '
  .apiVersion == "scalex.io/v1alpha1" and
  .kind == "ReleasePromotion" and
  .release == "temp-poc" and
  .source == {
    repoURL: "https://github.com/BellTigerLee/temp-poc.git",
    path: "chart",
    revision: $revision
  } and
  (.images | keys | sort) == ["batchAnalyzer", "datasetIngest", "reportGenerator"] and
  all(.images[];
    .tag == ("sha-" + $revision) and
    .sourceRevision == $revision and
    (.repository | startswith("registry.example.com/team/temp-poc-")) and
    (.digest | test("^sha256:[0-9a-f]{64}$"))
  )
' "$tmp/promotion.json" >/dev/null

cp "$ROOT/chart/values.yaml" "$tmp/values.yaml"
schedule_before="$(yq e -r '.batchAnalyzer.schedule' "$tmp/values.yaml")"
"$ROOT/scripts/apply-image-metadata.sh" "$tmp/promotion.json" "$tmp/values.yaml" >/dev/null

for mapping in \
  datasetIngest:dataset-ingest \
  batchAnalyzer:batch-analyzer \
  reportGenerator:report-generator; do
  component="${mapping%%:*}"
  suffix="${mapping#*:}"
  COMPONENT="$component" yq e -e \
    '.images[strenv(COMPONENT)].repository == "registry.example.com/team/temp-poc-'"$suffix"'"' \
    "$tmp/values.yaml" >/dev/null
  COMPONENT="$component" REVISION="$revision" yq e -e \
    '.images[strenv(COMPONENT)].tag == "sha-" + strenv(REVISION)' \
    "$tmp/values.yaml" >/dev/null
done
yq e -e '.images[] | has("digest") == false and has("sourceRevision") == false' \
  "$tmp/values.yaml" >/dev/null
[ "$(yq e -r '.batchAnalyzer.schedule' "$tmp/values.yaml")" = "$schedule_before" ] || {
  echo "non-image chart values changed while applying image metadata" >&2
  exit 1
}

if DOCKER_BIN="$ROOT/tests/fixtures/fake-docker.sh" \
    "$ROOT/scripts/create-promotion-payload.sh" "$tmp/invalid.json" main \
    >"$tmp/invalid.out" 2>"$tmp/invalid.err"; then
  echo "mutable revision unexpectedly produced a promotion payload" >&2
  exit 1
fi
grep -Fq 'revision must be a 40-character lowercase Git SHA' "$tmp/invalid.err"

mkdir -p "$tmp/images/alpha" "$tmp/images/new-worker"
: >"$tmp/images/alpha/Dockerfile"
: >"$tmp/images/new-worker/Dockerfile"
IMAGES_DIR="$tmp/images" DOCKER_BIN="$ROOT/tests/fixtures/fake-docker.sh" \
  IMAGE_REGISTRY=registry.example.com/team \
  "$ROOT/scripts/create-promotion-payload.sh" "$tmp/dynamic.json" "$revision" >/dev/null
jq -e '(.images | keys | sort) == ["alpha", "newWorker"]' "$tmp/dynamic.json" >/dev/null

FAKE_DOCKER_LOG="$tmp/dynamic-docker.log" IMAGES_DIR="$tmp/images" \
  DOCKER_BIN="$ROOT/tests/fixtures/fake-docker.sh" IMAGE_REGISTRY=registry.example.com/team \
  "$ROOT/scripts/build-images.sh" --push --latest "$revision"
[ "$(grep -c '^build ' "$tmp/dynamic-docker.log")" -eq 2 ]
grep -Fq 'temp-poc-alpha:latest' "$tmp/dynamic-docker.log"
grep -Fq 'temp-poc-new-worker:latest' "$tmp/dynamic-docker.log"

mkdir -p "$tmp/empty-images"
if IMAGES_DIR="$tmp/empty-images" DOCKER_BIN="$ROOT/tests/fixtures/fake-docker.sh" \
    "$ROOT/scripts/build-images.sh" "$revision" >"$tmp/empty.out" 2>"$tmp/empty.err"; then
  echo "empty image inventory unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'no images/*/Dockerfile files found' "$tmp/empty.err"

echo "image metadata script tests passed"
