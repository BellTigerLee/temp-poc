#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
revision=1111111111111111111111111111111111111111

mkdir -p "$tmp/images/custom-worker"
: >"$tmp/images/custom-worker/Dockerfile"
cat >"$tmp/values.yaml" <<'YAML'
images:
  custom-worker:
    repository: registry.example.com/team/custom-worker
    tag: v0.1.0
    pullPolicy: IfNotPresent
  external-data:
    repository: registry.example.com/team/external-data
    tag: v2.3.4
    pullPolicy: Always
YAML

FAKE_DOCKER_LOG="$tmp/docker.log" VALUES_FILE="$tmp/values.yaml" \
  IMAGES_DIR="$tmp/images" DOCKER_BIN="$ROOT/tests/fixtures/fake-docker.sh" \
  "$ROOT/scripts/build-images.sh" --push \
    --generated-values "$tmp/generated-values.yaml" "$revision" >/dev/null

[ "$(grep -c '^build ' "$tmp/docker.log")" -eq 1 ]
[ "$(grep -c '^push ' "$tmp/docker.log")" -eq 1 ]
[ "$(grep -c '^pull ' "$tmp/docker.log")" -eq 1 ]
[ "$(grep -c '^image inspect ' "$tmp/docker.log")" -eq 2 ]
grep -Fq 'registry.example.com/team/custom-worker:v0.1.0' "$tmp/docker.log"
grep -Fq 'registry.example.com/team/external-data:v2.3.4' "$tmp/docker.log"
! grep -Fq ':latest' "$tmp/docker.log"

yq e -o=json '.' "$tmp/generated-values.yaml" | jq -e --arg revision "$revision" '
  (.images | keys | sort) == ["custom-worker", "external-data"] and
  all(.images[];
    (.digest | test("^sha256:[0-9a-f]{64}$")) and
    .sourceRevision == $revision
  )
' >/dev/null

VALUES_FILE="$tmp/values.yaml" "$ROOT/scripts/create-promotion-payload.sh" \
  "$tmp/promotion.json" "$tmp/generated-values.yaml" "$revision" >/dev/null
jq -e --arg revision "$revision" '
  .source.revision == $revision and
  (.images | keys | sort) == ["custom-worker", "external-data"] and
  .images["custom-worker"].repository == "registry.example.com/team/custom-worker" and
  .images["custom-worker"].tag == "v0.1.0" and
  all(.images[];
    .sourceRevision == $revision and
    (.digest | test("^sha256:[0-9a-f]{64}$"))
  )
' "$tmp/promotion.json" >/dev/null

FAKE_DOCKER_LOG="$tmp/chart-docker.log" DOCKER_BIN="$ROOT/tests/fixtures/fake-docker.sh" \
  "$ROOT/scripts/build-images.sh" --push \
    --generated-values "$tmp/chart-generated-values.yaml" "$revision" >/dev/null
[ "$(grep -c '^build ' "$tmp/chart-docker.log")" -eq 3 ]
[ "$(grep -c '^push ' "$tmp/chart-docker.log")" -eq 3 ]
! grep -q '^pull ' "$tmp/chart-docker.log"

helm template temp-poc "$ROOT/chart" --namespace scalex-temp-poc \
  --values "$tmp/chart-generated-values.yaml" >"$tmp/rendered.yaml"
"$ROOT/scripts/validate-render.sh" "$tmp/rendered.yaml"
grep -Eq 'image: ".*:v0\.1\.0@sha256:[0-9a-f]{64}"' "$tmp/rendered.yaml"

if VALUES_FILE="$tmp/values.yaml" DOCKER_BIN="$ROOT/tests/fixtures/fake-docker.sh" \
    "$ROOT/scripts/build-images.sh" --push "$revision" \
    >"$tmp/missing-generated.out" 2>"$tmp/missing-generated.err"; then
  echo "push without generated values output unexpectedly passed" >&2
  exit 1
fi
grep -Fq -- '--push requires --generated-values' "$tmp/missing-generated.err"

sed 's/tag: v0.1.0/tag: bad\/tag/' "$tmp/values.yaml" >"$tmp/invalid-tag-values.yaml"
if VALUES_FILE="$tmp/invalid-tag-values.yaml" DOCKER_BIN="$ROOT/tests/fixtures/fake-docker.sh" \
    "$ROOT/scripts/build-images.sh" --push \
    --generated-values "$tmp/invalid-tag-generated.yaml" "$revision" \
    >"$tmp/invalid-tag.out" 2>"$tmp/invalid-tag.err"; then
  echo "invalid OCI tag unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'images values must be a non-empty kebab-case map' "$tmp/invalid-tag.err"

mkdir -p "$tmp/external-only"
sed '/custom-worker:/,/pullPolicy: IfNotPresent/d; s/tag: v2.3.4/tag: latest/' \
  "$tmp/values.yaml" >"$tmp/external-only-values.yaml"
FAKE_DOCKER_LOG="$tmp/external-only.log" VALUES_FILE="$tmp/external-only-values.yaml" \
  IMAGES_DIR="$tmp/external-only/missing-images" \
  DOCKER_BIN="$ROOT/tests/fixtures/fake-docker.sh" \
  "$ROOT/scripts/build-images.sh" --push \
    --generated-values "$tmp/external-only-generated.yaml" "$revision" >/dev/null
grep -Fq 'pull registry.example.com/team/external-data:latest' "$tmp/external-only.log"
! grep -q '^build ' "$tmp/external-only.log"

if VALUES_FILE="$tmp/values.yaml" "$ROOT/scripts/create-promotion-payload.sh" \
    "$tmp/invalid.json" "$tmp/generated-values.yaml" main \
    >"$tmp/invalid.out" 2>"$tmp/invalid.err"; then
  echo "mutable revision unexpectedly produced a promotion payload" >&2
  exit 1
fi
grep -Fq 'revision must be a 40-character lowercase Git SHA' "$tmp/invalid.err"

echo "image metadata script tests passed"
