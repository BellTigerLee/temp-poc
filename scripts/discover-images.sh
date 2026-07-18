#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
images_dir="${IMAGES_DIR:-$root/images}"

[ -d "$images_dir" ] || {
  echo "images directory not found: $images_dir" >&2
  exit 1
}

count=0
while IFS= read -r -d '' dockerfile; do
  component="$(basename "$(dirname "$dockerfile")")"
  [[ "$component" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || {
    echo "image directory must use lowercase kebab-case: $component" >&2
    exit 1
  }

  IFS='-' read -r -a words <<<"$component"
  key="${words[0]}"
  for word in "${words[@]:1}"; do
    key+="${word^}"
  done

  printf '%s\t%s\t%s\n' "$key" "$component" "$dockerfile"
  count=$((count + 1))
done < <(find "$images_dir" -mindepth 2 -maxdepth 2 -type f -name Dockerfile -print0 | LC_ALL=C sort -z)

[ "$count" -gt 0 ] || {
  echo "no images/*/Dockerfile files found under: $images_dir" >&2
  exit 1
}
