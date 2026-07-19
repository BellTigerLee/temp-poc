#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISHER="$ROOT/scripts/publish-promotion-artifact.sh"
FAKE_ORAS="$ROOT/tests/fixtures/fake-oras.sh"
REPOSITORY=registry.example.com/team/temp-poc-promotions
PASSWORD='publisher-test-secret'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

[ -x "$PUBLISHER" ]
[ -x "$FAKE_ORAS" ]
! grep -Fq 'latest-verified' "$PUBLISHER"
! grep -Eq 'run_oras[[:space:]]+tag' "$PUBLISHER"

current_sha=1111111111111111111111111111111111111111

make_payload() {
  local output="$1" revision="$2" digit="${3:-1}"
  jq -n --arg revision "$revision" --arg digit "$digit" '
    def image($repository; $tag; $n): {
      repository: ("registry.example.com/team/" + $repository),
      tag: $tag,
      digest: ("sha256:" + ($n * 64)),
      sourceRevision: $revision
    };
    {
      apiVersion: "scalex.io/v1alpha1",
      kind: "ReleasePromotion",
      release: "temp-poc",
      source: {
        repoURL: "https://github.com/BellTigerLee/temp-poc.git",
        path: "chart",
        revision: $revision
      },
      images: {
        "custom-worker": image("custom-worker"; "v0.1.0"; $digit),
        "external-data": image("external-data"; "v2.3.4"; "2")
      }
    }
  ' >"$output"
}

make_payload_with_repo() {
  local output="$1" revision="$2" component="$3" repository="$4"
  make_payload "$output" "$revision"
  jq --arg component "$component" --arg repository "$repository" \
    '.images[$component].repository = $repository' "$output" >"$tmp/rewrite.json"
  mv "$tmp/rewrite.json" "$output"
}

current_payload="$tmp/current.json"
different_payload="$tmp/different.json"
make_payload "$current_payload" "$current_sha"
make_payload "$different_payload" "$current_sha" 9

new_state() {
  mkdir -p "$tmp/$1"
  printf '%s' "$tmp/$1"
}

run_publish() {
  local state="$1" payload="$2" revision="$3" run_id="$4" fault="${5:-}"
  FAKE_ORAS_STATE="$state" \
  FAKE_ORAS_FAULT="$fault" \
  FAKE_ORAS_PASSWORD="$PASSWORD" \
  ORAS_BIN="$FAKE_ORAS" \
  PROMOTION_REPOSITORY="$REPOSITORY" \
  HARBOR_PLAIN_HTTP=true \
  HARBOR_USERNAME=robot \
  HARBOR_PASSWORD="$PASSWORD" \
  GITHUB_RUN_ID="$run_id" \
  GITHUB_RUN_ATTEMPT=1 \
    "$PUBLISHER" "$payload" "$revision"
}

seed() {
  FAKE_ORAS_STATE="$1" "$FAKE_ORAS" fixture seed "$2" "$3"
}

resolve() {
  FAKE_ORAS_STATE="$1" "$FAKE_ORAS" fixture resolve "$2"
}

assert_cleanup() {
  local state="$1"
  ! grep -R -Fq "$PASSWORD" "$state"
  while IFS= read -r config; do [ ! -e "$config" ]; done <"$state/config-paths.log"
}

happy="$(new_state happy)"
happy_stdout="$(run_publish "$happy" "$current_payload" "$current_sha" 101 2>"$happy/stderr")"
[[ "$happy_stdout" =~ ^sha256:[0-9a-f]{64}$ ]]
[ "$(resolve "$happy" "$REPOSITORY:sha-$current_sha-run-101-attempt-1")" = "$happy_stdout" ]
assert_cleanup "$happy"
grep -q -- '--plain-http' "$happy/commands.log"
! grep -q '^tag ' "$happy/commands.log"

pushes="$(grep -c '^push ' "$happy/commands.log")"
[ "$(run_publish "$happy" "$current_payload" "$current_sha" 101)" = "$happy_stdout" ]
[ "$(grep -c '^push ' "$happy/commands.log")" = "$pushes" ]

expect_pre_tag_failure() {
  local fault="$1" state
  state="$(new_state "failure-$fault")"
  if run_publish "$state" "$current_payload" "$current_sha" 200 "$fault" \
      >"$state/stdout" 2>"$state/stderr"; then
    echo "failure unexpectedly passed: $fault" >&2
    exit 1
  fi
  ! grep -q '^tag ' "$state/commands.log"
  assert_cleanup "$state"
}

for fault in login push fetch pull bad_layer bad_bytes; do
  expect_pre_tag_failure "$fault"
done

collision="$(new_state collision)"
seed "$collision" "$REPOSITORY:sha-$current_sha-run-400-attempt-1" "$different_payload"
if run_publish "$collision" "$current_payload" "$current_sha" 400 \
    >"$collision/stdout" 2>"$collision/stderr"; then
  echo 'immutable collision unexpectedly passed' >&2
  exit 1
fi
assert_cleanup "$collision"

invalid="$(new_state invalid)"
jq '.images = {}' "$current_payload" >"$tmp/invalid.json"
if run_publish "$invalid" "$tmp/invalid.json" "$current_sha" 500 \
    >"$invalid/stdout" 2>"$invalid/stderr"; then
  echo 'invalid payload unexpectedly passed' >&2
  exit 1
fi
[ ! -e "$invalid/commands.log" ]

foreign="$(new_state foreign)"
make_payload_with_repo "$tmp/foreign.json" "$current_sha" custom-worker 'attacker.example/foreign/image'
if run_publish "$foreign" "$tmp/foreign.json" "$current_sha" 501 \
    >"$foreign/stdout" 2>"$foreign/stderr"; then
  echo 'foreign repository unexpectedly passed' >&2
  exit 1
fi
[ ! -e "$foreign/commands.log" ]

invalid_tag="$(new_state invalid-tag)"
jq '.images["custom-worker"].tag = "bad/tag"' "$current_payload" >"$tmp/invalid-tag.json"
if run_publish "$invalid_tag" "$tmp/invalid-tag.json" "$current_sha" 502 \
    >"$invalid_tag/stdout" 2>"$invalid_tag/stderr"; then
  echo 'invalid image tag unexpectedly passed' >&2
  exit 1
fi
[ ! -e "$invalid_tag/commands.log" ]

rm -rf "$tmp"
trap - EXIT INT TERM
[ ! -e "$tmp" ]
echo 'promotion artifact publisher tests passed'
