#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
registry=${IMAGE_REGISTRY:-docker.io/belltigerlee}
docker_bin=${DOCKER_BIN:-docker}
revision=""
push=false
latest=false

usage() {
  cat <<'EOF'
Usage: ./scripts/build-images.sh [OPTIONS] [REVISION]

Build all temp-poc component images. REVISION defaults to the current Git commit.

Options:
  --push                 Push each image after it is built
  --latest               Also tag and push each image as latest (requires --push)
  --registry REGISTRY    Image registry namespace (default: docker.io/belltigerlee)
  -h, --help             Show this help

Environment:
  IMAGE_REGISTRY         Alternative default for --registry
  DOCKER_BIN             Docker-compatible executable (default: docker)
EOF
}

while (($#)); do
  case "$1" in
    --push)
      push=true
      shift
      ;;
    --latest)
      latest=true
      shift
      ;;
    --registry)
      (($# >= 2)) || { echo "--registry requires a value" >&2; exit 2; }
      registry=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      [[ -z $revision ]] || { echo "only one revision may be specified" >&2; exit 2; }
      revision=$1
      shift
      ;;
  esac
done

revision=${revision:-$(git -C "$root" rev-parse HEAD)}
[[ $revision =~ ^[0-9a-f]{40}$ ]] || {
  echo "revision must be a 40-character lowercase Git SHA" >&2
  exit 2
}
registry=${registry%/}
[[ -n $registry ]] || { echo "registry must not be empty" >&2; exit 2; }
$latest && ! $push && {
  echo "--latest requires --push" >&2
  exit 2
}
command -v "$docker_bin" >/dev/null 2>&1 || {
  echo "Docker-compatible command not found: $docker_bin" >&2
  exit 1
}

inventory="$("$root/scripts/discover-images.sh")"
while IFS=$'\t' read -r _ component dockerfile; do
  repository="$registry/temp-poc-$component"
  sha_ref="$repository:sha-$revision"
  "$docker_bin" build --file "$dockerfile" --tag "$sha_ref" "$root"
done <<<"$inventory"

if $push; then
  while IFS=$'\t' read -r _ component _; do
    repository="$registry/temp-poc-$component"
    sha_ref="$repository:sha-$revision"
    "$docker_bin" push "$sha_ref"
  done <<<"$inventory"
fi

if $latest; then
  while IFS=$'\t' read -r _ component _; do
    repository="$registry/temp-poc-$component"
    sha_ref="$repository:sha-$revision"
    "$docker_bin" tag "$sha_ref" "$repository:latest"
    "$docker_bin" push "$repository:latest"
  done <<<"$inventory"
fi
