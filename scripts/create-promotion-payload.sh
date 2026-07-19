#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
values="${VALUES_FILE:-$root/chart/values.yaml}"
yq_bin="${YQ_BIN:-yq}"

usage() {
  cat <<'EOF'
Usage: ./scripts/create-promotion-payload.sh OUTPUT GENERATED_VALUES [REVISION]

Merge user-managed image values with CI-generated digest/sourceRevision values
and write the ScaleX ReleasePromotion JSON payload.

Environment:
  VALUES_FILE  User-managed values file (default: chart/values.yaml)
  YQ_BIN       yq-compatible executable (default: yq)
EOF
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || {
  usage >&2
  exit 2
}

output="$1"
generated_values="$2"
revision="${3:-$(git -C "$root" rev-parse HEAD)}"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "revision must be a 40-character lowercase Git SHA" >&2
  exit 2
}
[ "$revision" != 0000000000000000000000000000000000000000 ] || {
  echo "revision cannot be the all-zero placeholder" >&2
  exit 2
}
[ -f "$values" ] || { echo "values file not found: $values" >&2; exit 1; }
[ -f "$generated_values" ] || { echo "generated values file not found: $generated_values" >&2; exit 1; }
for tool in jq "$yq_bin"; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "required command not found: $tool" >&2
    exit 1
  }
done
[ -d "$(dirname "$output")" ] || {
  echo "output directory does not exist: $(dirname "$output")" >&2
  exit 1
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
umask 077
jq -n --arg revision "$revision" '{
  apiVersion: "scalex.io/v1alpha1",
  kind: "ReleasePromotion",
  release: "temp-poc",
  source: {
    repoURL: "https://github.com/BellTigerLee/temp-poc.git",
    path: "chart",
    revision: $revision
  },
  images: {}
}' >"$tmp"

images_json="$("$yq_bin" e -o=json '.images' "$values")"
metadata_json="$("$yq_bin" e -o=json '.images' "$generated_values")"
base_keys="$(jq -r 'keys[]' <<<"$images_json" | LC_ALL=C sort)"
metadata_keys="$(jq -r 'keys[]' <<<"$metadata_json" | LC_ALL=C sort)"
[ -n "$base_keys" ] && [ "$base_keys" = "$metadata_keys" ] || {
  echo "generated values must contain exactly the user-managed image keys" >&2
  exit 1
}

while IFS= read -r key; do
  repository="$(jq -er --arg key "$key" '.[$key].repository' <<<"$images_json")"
  tag="$(jq -er --arg key "$key" '.[$key].tag' <<<"$images_json")"
  digest="$(jq -er --arg key "$key" '.[$key].digest' <<<"$metadata_json")"
  source_revision="$(jq -er --arg key "$key" '.[$key].sourceRevision' <<<"$metadata_json")"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "generated image digest is invalid: $key" >&2
    exit 1
  }
  [ "$source_revision" = "$revision" ] || {
    echo "generated image source revision does not match: $key" >&2
    exit 1
  }

  next="$(mktemp)"
  jq --arg key "$key" \
    --arg repository "$repository" \
    --arg tag "$tag" \
    --arg digest "$digest" \
    --arg revision "$revision" \
    '.images[$key] = {
      repository: $repository,
      tag: $tag,
      digest: $digest,
      sourceRevision: $revision
    }' "$tmp" >"$next"
  mv "$next" "$tmp"
done <<<"$base_keys"

mv "$tmp" "$output"
trap - EXIT
echo "wrote promotion payload: $output"
