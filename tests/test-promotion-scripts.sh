#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
revision=1111111111111111111111111111111111111111

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

if DOCKER_BIN="$ROOT/tests/fixtures/fake-docker.sh" \
    "$ROOT/scripts/create-promotion-payload.sh" "$tmp/invalid.json" main \
    >"$tmp/invalid.out" 2>"$tmp/invalid.err"; then
  echo "mutable revision unexpectedly produced a promotion payload" >&2
  exit 1
fi
grep -Fq 'revision must be a 40-character lowercase Git SHA' "$tmp/invalid.err"

echo "promotion payload tests passed"
