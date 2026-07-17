#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
registry="${IMAGE_REGISTRY:-docker.io/belltigerlee}"
docker_bin="${DOCKER_BIN:-docker}"

usage() {
  cat <<'EOF'
Usage: ./scripts/create-promotion-payload.sh OUTPUT [REVISION]

Resolve the registry digest for every temp-poc image tagged with REVISION and
write the strict ScaleX ReleasePromotion JSON payload. REVISION defaults to the
current Git commit.

Environment:
  IMAGE_REGISTRY  Registry namespace (default: docker.io/belltigerlee)
  DOCKER_BIN      Docker-compatible executable used for inspection
EOF
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || {
  usage >&2
  exit 2
}

output="$1"
revision="${2:-$(git -C "$root" rev-parse HEAD)}"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "revision must be a 40-character lowercase Git SHA" >&2
  exit 2
}
[ "$revision" != 0000000000000000000000000000000000000000 ] || {
  echo "revision cannot be the all-zero placeholder" >&2
  exit 2
}
registry="${registry%/}"
[ -n "$registry" ] || {
  echo "registry must not be empty" >&2
  exit 2
}
command -v "$docker_bin" >/dev/null 2>&1 || {
  echo "Docker-compatible command not found: $docker_bin" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "required command not found: jq" >&2
  exit 1
}
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

components=(
  'datasetIngest:dataset-ingest'
  'batchAnalyzer:batch-analyzer'
  'reportGenerator:report-generator'
)
for mapping in "${components[@]}"; do
  key="${mapping%%:*}"
  suffix="${mapping#*:}"
  repository="$registry/temp-poc-$suffix"
  tag="sha-$revision"
  repo_digests="$($docker_bin image inspect "$repository:$tag" --format '{{json .RepoDigests}}')"
  digest="$(jq -er --arg prefix "$repository@" '
    .[] | select(startswith($prefix)) | sub("^[^@]+@"; "")
  ' <<<"$repo_digests")" || {
    echo "pushed image has no matching repository digest: $repository:$tag" >&2
    exit 1
  }
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "registry returned an invalid manifest digest: $repository:$tag" >&2
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
done

mv "$tmp" "$output"
trap - EXIT
echo "wrote promotion payload: $output"
