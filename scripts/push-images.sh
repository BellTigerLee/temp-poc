#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
revision="${1:?40-character source revision is required}"
registry="${IMAGE_REGISTRY:-docker.io/belltigerlee}"
docker_bin="${DOCKER_BIN:-docker}"

[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "revision must be a 40-character lowercase Git SHA" >&2
  exit 2
}
registry="${registry%/}"
inventory="$("$root/scripts/discover-images.sh")"
while IFS=$'\t' read -r _ component _; do
  "$docker_bin" push "$registry/temp-poc-$component:sha-$revision"
done <<<"$inventory"
