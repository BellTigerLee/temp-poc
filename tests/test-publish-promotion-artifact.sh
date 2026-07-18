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
grep -Fq 'ls-remote --exit-code origin refs/heads/main' "$PUBLISHER"
! grep -Fq 'merge-base' "$PUBLISHER"
! grep -Fq 'channel-current' "$PUBLISHER"

history="$tmp/history"
git init -q "$history"
git -C "$history" config user.name 'Publisher Test'
git -C "$history" config user.email publisher@example.com
git -C "$history" remote add origin "$history"
printf 'stale\n' >"$history/release"
git -C "$history" add release
git -C "$history" commit -q -m stale
stale_sha="$(git -C "$history" rev-parse HEAD)"
printf 'current\n' >"$history/release"
git -C "$history" commit -q -am current
current_sha="$(git -C "$history" rev-parse HEAD)"
git -C "$history" update-ref refs/heads/main "$current_sha"

make_payload() {
  local output="$1" revision="$2" digit="${3:-1}"
  jq -n --arg revision "$revision" --arg digit "$digit" '
    def image($suffix; $n): {
      repository: ("registry.example.com/team/temp-poc-" + $suffix),
      tag: ("sha-" + $revision),
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
        datasetIngest: image("dataset-ingest"; $digit),
        batchAnalyzer: image("batch-analyzer"; "2"),
        reportGenerator: image("report-generator"; "3")
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
stale_payload="$tmp/stale.json"
different_payload="$tmp/different.json"
make_payload "$current_payload" "$current_sha"
make_payload "$stale_payload" "$stale_sha"
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
  HARBOR_USERNAME=robot \
  HARBOR_PASSWORD="$PASSWORD" \
  GITHUB_RUN_ID="$run_id" \
  GITHUB_RUN_ATTEMPT=1 \
  GIT_DIR="$history/.git" \
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
[ "$(resolve "$happy" "$REPOSITORY:latest-verified")" = "$happy_stdout" ]
[ "$(resolve "$happy" "$REPOSITORY:sha-$current_sha-run-101-attempt-1")" = "$happy_stdout" ]
assert_cleanup "$happy"

pushes="$(grep -c '^push ' "$happy/commands.log")"
[ "$(run_publish "$happy" "$current_payload" "$current_sha" 101)" = "$happy_stdout" ]
[ "$(grep -c '^push ' "$happy/commands.log")" = "$pushes" ]

stale="$(new_state stale)"
seed "$stale" "$REPOSITORY:latest-verified" "$current_payload"
stale_before="$(resolve "$stale" "$REPOSITORY:latest-verified")"
stale_stdout="$(run_publish "$stale" "$stale_payload" "$stale_sha" 102 2>"$stale/stderr")"
[[ "$stale_stdout" =~ ^sha256:[0-9a-f]{64}$ ]]
[ "$(resolve "$stale" "$REPOSITORY:latest-verified")" = "$stale_before" ]
[ "$(resolve "$stale" "$REPOSITORY:sha-$stale_sha-run-102-attempt-1")" = "$stale_stdout" ]
grep -Fq 'origin main moved; immutable promotion retained without channel update' "$stale/stderr"
! grep -q '^tag ' "$stale/commands.log"
assert_cleanup "$stale"

expect_pre_tag_failure() {
  local fault="$1" state before
  state="$(new_state "failure-$fault")"
  seed "$state" "$REPOSITORY:latest-verified" "$stale_payload"
  before="$(resolve "$state" "$REPOSITORY:latest-verified")"
  if run_publish "$state" "$current_payload" "$current_sha" 200 "$fault" \
      >"$state/stdout" 2>"$state/stderr"; then
    echo "failure unexpectedly passed: $fault" >&2
    exit 1
  fi
  [ "$(resolve "$state" "$REPOSITORY:latest-verified")" = "$before" ]
  ! grep -q '^tag ' "$state/commands.log"
  assert_cleanup "$state"
}

for fault in login push fetch pull bad_layer bad_bytes tag; do
  expect_pre_tag_failure "$fault"
done

post="$(new_state post-resolve)"
seed "$post" "$REPOSITORY:latest-verified" "$stale_payload"
post_before="$(resolve "$post" "$REPOSITORY:latest-verified")"
if run_publish "$post" "$current_payload" "$current_sha" 300 post_resolve \
    >"$post/stdout" 2>"$post/stderr"; then
  echo 'post-resolution mismatch unexpectedly passed' >&2
  exit 1
fi
grep -q '^tag ' "$post/commands.log"
[ "$(resolve "$post" "$REPOSITORY:latest-verified")" != "$post_before" ]
grep -Fq 'latest-verified does not resolve to the verified artifact digest' "$post/stderr"
assert_cleanup "$post"

collision="$(new_state collision)"
seed "$collision" "$REPOSITORY:latest-verified" "$stale_payload"
seed "$collision" "$REPOSITORY:sha-$current_sha-run-400-attempt-1" "$different_payload"
collision_before="$(resolve "$collision" "$REPOSITORY:latest-verified")"
if run_publish "$collision" "$current_payload" "$current_sha" 400 \
    >"$collision/stdout" 2>"$collision/stderr"; then
  echo 'immutable collision unexpectedly passed' >&2
  exit 1
fi
[ "$(resolve "$collision" "$REPOSITORY:latest-verified")" = "$collision_before" ]
assert_cleanup "$collision"

invalid="$(new_state invalid)"
jq 'del(.images.reportGenerator)' "$current_payload" >"$tmp/invalid.json"
if run_publish "$invalid" "$tmp/invalid.json" "$current_sha" 500 \
    >"$invalid/stdout" 2>"$invalid/stderr"; then
  echo 'invalid payload unexpectedly passed' >&2
  exit 1
fi
[ ! -e "$invalid/commands.log" ]

foreign="$(new_state foreign)"
make_payload_with_repo "$tmp/foreign.json" "$current_sha" datasetIngest 'attacker.example/foreign/image'
if run_publish "$foreign" "$tmp/foreign.json" "$current_sha" 501 \
    >"$foreign/stdout" 2>"$foreign/stderr"; then
  echo 'foreign repository unexpectedly passed' >&2
  exit 1
fi
[ ! -e "$foreign/commands.log" ]

suffix="$(new_state suffix)"
make_payload_with_repo "$tmp/suffix.json" "$current_sha" reportGenerator 'registry.example.com/team/temp-poc-report-generator-evil'
if run_publish "$suffix" "$tmp/suffix.json" "$current_sha" 502 \
    >"$suffix/stdout" 2>"$suffix/stderr"; then
  echo 'wrong component suffix unexpectedly passed' >&2
  exit 1
fi
[ ! -e "$suffix/commands.log" ]

rm -rf "$tmp"
trap - EXIT INT TERM
[ ! -e "$tmp" ]
echo 'promotion artifact publisher tests passed'
