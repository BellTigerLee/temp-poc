#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
payload="${1:?image metadata payload is required}"
values="${2:-$root/chart/values.yaml}"

for tool in jq yq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "required command not found: $tool" >&2
    exit 1
  }
done
[ -f "$payload" ] || { echo "image metadata payload not found: $payload" >&2; exit 1; }
[ -f "$values" ] || { echo "chart values not found: $values" >&2; exit 1; }

revision="$(jq -er '.source.revision | select(type == "string")' "$payload")"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "payload revision must be a 40-character lowercase Git SHA" >&2
  exit 1
}

current_keys="$(yq e -r '.images | keys | .[]' "$values" | LC_ALL=C sort)"
[ -n "$current_keys" ] || { echo "chart values contain no images" >&2; exit 1; }

tmp="$(mktemp "${values}.tmp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cp "$values" "$tmp"
chmod --reference="$values" "$tmp"

while IFS= read -r component; do
  repository="$(jq -er --arg component "$component" \
    '.images[$component].repository | select(type == "string" and length > 0)' "$payload")"
  tag="$(jq -er --arg component "$component" \
    '.images[$component].tag | select(type == "string")' "$payload")"
  digest="$(jq -er --arg component "$component" \
    '.images[$component].digest | select(type == "string")' "$payload")"
  source_revision="$(jq -er --arg component "$component" \
    '.images[$component].sourceRevision | select(type == "string")' "$payload")"

  [ "$tag" = "sha-$revision" ] || {
    echo "image tag does not match payload revision: $component" >&2
    exit 1
  }
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "image digest is not an immutable sha256 digest: $component" >&2
    exit 1
  }
  [ "$source_revision" = "$revision" ] || {
    echo "image source revision does not match payload revision: $component" >&2
    exit 1
  }

  COMPONENT="$component" REPOSITORY="$repository" TAG="$tag" yq -i '
      .images[strenv(COMPONENT)].repository = strenv(REPOSITORY) |
      .images[strenv(COMPONENT)].tag = strenv(TAG)
    ' "$tmp"
done <<<"$current_keys"

mv "$tmp" "$values"
trap - EXIT
echo "updated chart image metadata: $values"
