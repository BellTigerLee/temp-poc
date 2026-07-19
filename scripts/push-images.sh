#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
revision="${1:?40-character source revision is required}"
generated_values="${2:?generated values output path is required}"

[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "revision must be a 40-character lowercase Git SHA" >&2
  exit 2
}
echo "push-images.sh is deprecated; delegating to build-images.sh" >&2
exec "$root/scripts/build-images.sh" --push \
  --generated-values "$generated_values" "$revision"
