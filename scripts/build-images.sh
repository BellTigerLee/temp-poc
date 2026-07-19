#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker_bin="${DOCKER_BIN:-docker}"
yq_bin="${YQ_BIN:-yq}"
images_dir="${IMAGES_DIR:-$root/images}"
values="${VALUES_FILE:-$root/chart/values.yaml}"
generated_values=""
revision=""
push=false

usage() {
  cat <<'EOF'
Usage: ./scripts/build-images.sh [OPTIONS] [REVISION]

Build all temp-poc component images. REVISION defaults to the current Git commit.

Options:
  --push                     Build/push local images and pull external images
  --values FILE              User-managed values file (default: chart/values.yaml)
  --generated-values FILE    Write CI-managed digest/sourceRevision values
  -h, --help             Show this help

Environment:
  VALUES_FILE        Alternative default for --values
  IMAGES_DIR         Dockerfile root (default: images)
  DOCKER_BIN         Docker-compatible executable (default: docker)
  YQ_BIN             yq-compatible executable (default: yq)
EOF
}

while (($#)); do
  case "$1" in
    --push)
      push=true
      shift
      ;;
    --values)
      (($# >= 2)) || { echo "--values requires a value" >&2; exit 2; }
      values=$2
      shift 2
      ;;
    --generated-values)
      (($# >= 2)) || { echo "--generated-values requires a value" >&2; exit 2; }
      generated_values=$2
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
[ -f "$values" ] || { echo "values file not found: $values" >&2; exit 1; }
$push && [[ -z $generated_values ]] && {
  echo "--push requires --generated-values" >&2
  exit 2
}
[[ -z $generated_values ]] || $push || {
  echo "--generated-values requires --push" >&2
  exit 2
}
[[ -z $generated_values ]] || [ -d "$(dirname "$generated_values")" ] || {
  echo "generated values directory does not exist: $(dirname "$generated_values")" >&2
  exit 1
}
for tool in "$docker_bin" "$yq_bin" jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "required command not found: $tool" >&2
    exit 1
  }
done

images_json="$("$yq_bin" e -o=json '.images' "$values")"
jq -e '
  type == "object" and length > 0 and
  all(to_entries[];
    (.key | test("^[a-z0-9]+(-[a-z0-9]+)*$")) and
    (.value | type == "object") and
    (.value | keys - ["digest", "pullPolicy", "repository", "sourceRevision", "tag"] | length == 0) and
    (.value.repository | type == "string" and test("^[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._/-]+$")) and
    (.value.tag | type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")) and
    (.value.pullPolicy == "Always" or .value.pullPolicy == "IfNotPresent")
  )
' <<<"$images_json" >/dev/null || {
  echo "images values must be a non-empty kebab-case map with repository, exact OCI tag, and pullPolicy" >&2
  exit 2
}

inventory="$(jq -r '
  to_entries | sort_by(.key)[] |
  [.key, .value.repository, .value.tag, .value.pullPolicy] | @tsv
' <<<"$images_json")"

while IFS=$'\t' read -r key repository tag _; do
  dockerfile="$images_dir/$key/Dockerfile"
  [ -f "$dockerfile" ] || continue
  "$docker_bin" build --file "$dockerfile" --tag "$repository:$tag" "$root"
done <<<"$inventory"

if $push; then
  while IFS=$'\t' read -r key repository tag _; do
    dockerfile="$images_dir/$key/Dockerfile"
    if [ -f "$dockerfile" ]; then
      "$docker_bin" push "$repository:$tag"
    else
      "$docker_bin" pull "$repository:$tag"
    fi
  done <<<"$inventory"
fi

[ -n "$generated_values" ] || exit 0

umask 077
metadata_json="$(mktemp)"
metadata_yaml="$(mktemp "${generated_values}.tmp.XXXXXX")"
trap 'rm -f "$metadata_json" "$metadata_yaml"' EXIT
jq -n '{images: {}}' >"$metadata_json"

while IFS=$'\t' read -r key repository tag _; do
  reference="$repository:$tag"
  repo_digests="$($docker_bin image inspect "$reference" --format '{{json .RepoDigests}}')"
  digest="$(jq -er --arg prefix "$repository@" '
    .[] | select(startswith($prefix)) | sub("^[^@]+@"; "")
  ' <<<"$repo_digests")" || {
    echo "image has no matching repository digest after sync: $reference" >&2
    exit 1
  }
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "registry returned an invalid manifest digest: $reference" >&2
    exit 1
  }

  next="$(mktemp)"
  jq --arg key "$key" --arg digest "$digest" --arg revision "$revision" \
    '.images[$key] = {digest: $digest, sourceRevision: $revision}' \
    "$metadata_json" >"$next"
  mv "$next" "$metadata_json"
done <<<"$inventory"

"$yq_bin" e -P '.' "$metadata_json" >"$metadata_yaml"
mv "$metadata_yaml" "$generated_values"
trap - EXIT
rm -f "$metadata_json"
echo "wrote generated image values: $generated_values"
