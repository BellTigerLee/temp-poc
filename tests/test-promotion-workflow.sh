#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$ROOT/.github/workflows/promote.yaml"

fail() {
  echo "$*" >&2
  exit 1
}

[ -f "$workflow" ] || fail "promotion workflow is missing"
grep -Fq 'experiment/candidate-feature-packages' "$workflow" ||
  fail "promotion branch trigger is missing"
grep -Fq 'permissions:' "$workflow" || fail "workflow permissions are not declared"
grep -Fq 'contents: read' "$workflow" || fail "source workflow token must be read-only"
if grep -Fq "SCALEX_PROMOTION_ENABLED" "$workflow"; then
  fail "promotion workflow must not depend on an opt-in variable"
fi
grep -Fq './scripts/test.sh' "$workflow" || fail "local validation is not executed"
grep -Fq './scripts/build-images.sh --push "$GITHUB_SHA"' "$workflow" ||
  fail "images are not built and pushed from the exact source SHA"
grep -Fq './scripts/create-promotion-payload.sh "$RUNNER_TEMP/promotion.json" "$GITHUB_SHA"' \
  "$workflow" || fail "registry digests are not captured in a promotion payload"
grep -Fq 'scripts/promote-release.sh temp-poc "$RUNNER_TEMP/promotion.json"' "$workflow" ||
  fail "Federation promotion entry point is not executed"
grep -Fq 'gh pr create' "$workflow" || fail "promotion Pull Request is not created"
if grep -Eiq '(gh pr merge|--auto([[:space:]]|$)|git push[^\n]*[[:space:]]main([[:space:]]|$))' "$workflow"; then
  fail "promotion workflow may not merge or push main directly"
fi

while IFS= read -r action; do
  [[ "$action" =~ @[0-9a-f]{40}$ ]] || fail "GitHub Action is not commit-pinned: $action"
done < <(sed -nE 's/^[[:space:]]*uses:[[:space:]]*([^[:space:]]+).*$/\1/p' "$workflow")

echo "promotion workflow contracts passed"
