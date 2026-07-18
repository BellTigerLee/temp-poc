#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$ROOT/.github/workflows/promote.yaml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1" text="$2" message="$3"
  grep -Fq -- "$text" "$file" || fail "$message"
}

assert_excludes() {
  local file="$1" pattern="$2" message="$3"
  if grep -Eiq -- "$pattern" "$file"; then
    fail "$message"
  fi
}

assert_no_active_line() {
  local file="$1" pattern="$2" message="$3"
  if grep -Eq "^[[:space:]]*${pattern}" "$file"; then
    fail "$message"
  fi
}

validate_workflow() {
  local file="$1"

  [ -f "$file" ] || fail "promotion workflow is missing"
  assert_contains "$file" 'name: Build and push images' \
    "workflow does not use image publication semantics"
  assert_contains "$file" 'build-and-push-images:' \
    "image build-and-push job is missing"
  assert_contains "$file" '- main' "main branch trigger is missing"
  assert_contains "$file" 'workflow_dispatch: {}' "manual workflow trigger is missing"
  assert_contains "$file" 'paths-ignore:' "paths-ignore is missing"
  assert_contains "$file" '- chart/values.yaml' \
    "chart values are not excluded from recursive builds"
  assert_contains "$file" 'contents: read' "workflow contents permission is not read-only"
  assert_excludes "$file" 'contents:[[:space:]]*write' "workflow retains write permission"
  assert_contains "$file" 'group: temp-poc-image-publish-main' \
    "image publishers are not globally serialized"
  assert_contains "$file" 'cancel-in-progress: false' \
    "promotion publication can be interrupted by a newer run"

  assert_contains "$file" \
    'uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683' \
    "checkout action pin changed"
  assert_contains "$file" 'fetch-depth: 0' "full Git history is not checked out"
  assert_contains "$file" 'persist-credentials: false' \
    "checkout credentials are persisted"
  assert_contains "$file" \
    'uses: astral-sh/setup-uv@d0cc045d04ccac9d8b7881df0226f9e82c39688e' \
    "uv action pin changed"
  assert_contains "$file" 'version: 0.11.16' "uv version pin changed"
  assert_contains "$file" 'YQ_VERSION: v4.45.4' "yq version pin changed"
  assert_contains "$file" 'YQ_SHA256: b96de04645707e14a12f52c37e6266832e03c29e95b9b139cddcae7314466e69' \
    "yq checksum pin changed"
  assert_contains "$file" '# ORAS promotion publication is intentionally disabled for now.' \
    "temporary ORAS disablement is not documented in the workflow"
  assert_no_active_line "$file" 'uses:[[:space:]]+oras-project/setup-oras@' \
    "ORAS setup action is active"
  assert_no_active_line "$file" 'oras[[:space:]]+version' \
    "ORAS version assertion is active"

  assert_contains "$file" 'IMAGE_REGISTRY: 10.34.25.18/playerone' \
    "Harbor project is not the image registry"
  assert_contains "$file" '- work8' "work8 self-hosted runner label is missing"
  assert_contains "$file" './scripts/test.sh' "source and chart validation is not executed"
  assert_contains "$file" 'name: Authenticate to Harbor' "Harbor login step is missing"
  assert_contains "$file" 'HARBOR_USERNAME: ${{ secrets.HARBOR_USERNAME }}' \
    "Harbor username secret is not wired"
  assert_contains "$file" 'HARBOR_PASSWORD: ${{ secrets.HARBOR_PASSWORD }}' \
    "Harbor password secret is not wired"
  assert_contains "$file" 'docker login 10.34.25.18' "workflow does not log in to Harbor"
  assert_contains "$file" '--password-stdin' "registry passwords are not passed on stdin"
  assert_contains "$file" './scripts/build-images.sh --push --latest "$GITHUB_SHA"' \
    "images are not built and pushed from the exact source SHA"
  assert_contains "$file" './scripts/discover-images.sh' \
    "workflow does not validate the discovered image count"
  assert_contains "$file" \
    './scripts/create-promotion-payload.sh "$RUNNER_TEMP/promotion.json" "$GITHUB_SHA"' \
    "registry digests are not captured in a promotion payload"
  assert_no_active_line "$file" './scripts/publish-promotion-artifact\.sh' \
    "verified promotion publisher is active"

  assert_contains "$file" 'install -d -m 0700' "temporary auth directories are not mode 0700"
  assert_contains "$file" 'chmod 0600' "temporary registry config is not mode 0600"
  assert_contains "$file" 'if: always()' "unconditional runner credential cleanup is missing"
  assert_contains "$file" 'docker logout 10.34.25.18' "Docker logout cleanup is missing"
  assert_contains "$file" 'rm -rf "$RUNNER_TEMP/temp-poc-auth"' \
    "temporary auth cleanup is missing"

  assert_excludes "$file" 'apply-image-metadata\.sh' \
    "workflow still mutates chart image metadata"
  assert_excludes "$file" 'git[[:space:]]+(config|add|commit|push)' \
    "workflow still commits or pushes Git state"
  assert_excludes "$file" 'helm[[:space:]]+(lint|template)|validate-render\.sh' \
    "workflow retains redundant post-mutation chart rendering"
  assert_excludes "$file" 'scalex-federation|SCALEX_PROMOTION_APP|gh pr (create|edit)' \
    "workflow must not update the Federation repository"
  assert_excludes "$file" '(^|[[:space:]])image:[^#]*:latest' \
    "workflow must not deploy an image directly"

  if awk '
    /^[[:space:]]*run:[[:space:]]*\|/ {
      in_run = 1
      run_indent = match($0, /[^[:space:]]/) - 1
      next
    }
    in_run {
      if ($0 !~ /^[[:space:]]*$/) {
        current_indent = match($0, /[^[:space:]]/) - 1
        if (current_indent <= run_indent) in_run = 0
      }
      if (in_run && $0 ~ /\$\{\{[[:space:]]*secrets\./) found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$file"; then
    fail "workflow expands a secret inside a command or log line"
  fi

  while IFS= read -r action; do
    [[ "$action" =~ @[0-9a-f]{40}$ ]] || fail "GitHub Action is not commit-pinned: $action"
  done < <(sed -nE 's/^[[:space:]]*uses:[[:space:]]*([^[:space:]]+).*$/\1/p' "$file")
}

expect_rejected() {
  local fixture="$1" message="$2"
  if (validate_workflow "$fixture") >/dev/null 2>&1; then
    fail "$message"
  fi
}

validate_workflow "$workflow"

cp "$workflow" "$tmp/commit-back.yaml"
printf '\n      - run: git push origin HEAD:refs/heads/main\n' >>"$tmp/commit-back.yaml"
expect_rejected "$tmp/commit-back.yaml" "commit-back fixture was accepted"

sed 's/contents: read/contents: write/' "$workflow" >"$tmp/write-permission.yaml"
expect_rejected "$tmp/write-permission.yaml" "write-permission fixture was accepted"

sed '/if: always()/d' "$workflow" >"$tmp/missing-cleanup.yaml"
expect_rejected "$tmp/missing-cleanup.yaml" "missing-cleanup fixture was accepted"

sed 's/group: temp-poc-image-publish-main/group: temp-poc-image-${{ github.ref }}/' \
  "$workflow" >"$tmp/wrong-concurrency.yaml"
expect_rejected "$tmp/wrong-concurrency.yaml" "wrong-concurrency fixture was accepted"

echo "promotion workflow contracts passed"
