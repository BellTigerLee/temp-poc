#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$ROOT/.github/workflows/promote.yaml"

fail() {
  echo "$*" >&2
  exit 1
}

[ -f "$workflow" ] || fail "promotion workflow is missing"
grep -Fq -- '- main' "$workflow" || fail "main branch trigger is missing"
grep -Fq 'paths-ignore:' "$workflow" || fail "generated values commits must be ignored"
grep -Fq -- '- chart/values.yaml' "$workflow" ||
  fail "chart values are not excluded from recursive builds"
grep -Fq 'permissions:' "$workflow" || fail "workflow permissions are not declared"
grep -Fq 'contents: write' "$workflow" || fail "workflow cannot commit chart values"
grep -Fq './scripts/test.sh' "$workflow" || fail "local validation is not executed"
grep -Fq './scripts/build-images.sh --push "$GITHUB_SHA"' "$workflow" ||
  fail "images are not built and pushed from the exact source SHA"
grep -Fq './scripts/create-promotion-payload.sh "$RUNNER_TEMP/promotion.json" "$GITHUB_SHA"' \
  "$workflow" || fail "registry digests are not captured in a promotion payload"
grep -Fq './scripts/apply-image-metadata.sh "$RUNNER_TEMP/promotion.json"' "$workflow" ||
  fail "built image metadata is not applied to chart values"
grep -Fq 'git add chart/values.yaml' "$workflow" ||
  fail "chart values are not committed"
grep -Fq 'git push origin "HEAD:refs/heads/$GITHUB_REF_NAME"' "$workflow" ||
  fail "chart values commit is not pushed to this repository"
if grep -Eiq 'scalex-federation|SCALEX_PROMOTION_APP|gh pr (create|edit)' "$workflow"; then
  fail "workflow must not update the Federation repository"
fi

while IFS= read -r action; do
  [[ "$action" =~ @[0-9a-f]{40}$ ]] || fail "GitHub Action is not commit-pinned: $action"
done < <(sed -nE 's/^[[:space:]]*uses:[[:space:]]*([^[:space:]]+).*$/\1/p' "$workflow")

echo "promotion workflow contracts passed"
