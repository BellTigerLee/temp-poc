#!/usr/bin/env bash
set -euo pipefail

harbor_username="${HARBOR_USERNAME:-}"
harbor_password="${HARBOR_PASSWORD:-}"
unset HARBOR_USERNAME HARBOR_PASSWORD

artifact_type='application/vnd.scalex.release-promotion.v1+json'
layer_type='application/vnd.scalex.release-promotion.payload.v1+json'
manifest_type='application/vnd.oci.image.manifest.v1+json'
oras_bin="${ORAS_BIN:-oras}"
plain_http="${HARBOR_PLAIN_HTTP:-false}"

fail() {
  echo "$*" >&2
  exit 1
}

[ "$#" -eq 2 ] || fail 'Usage: ./scripts/publish-promotion-artifact.sh PAYLOAD SOURCE_SHA'
payload="$1"
source_sha="$2"

[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || fail 'source SHA must be a 40-character lowercase Git SHA'
[ "$source_sha" != 0000000000000000000000000000000000000000 ] || fail 'source SHA cannot be the all-zero placeholder'
[ -f "$payload" ] && [ ! -L "$payload" ] || fail 'payload must be a regular file'

for name in PROMOTION_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT; do
  [ -n "${!name:-}" ] || fail "required environment variable is empty: $name"
done
[ -n "$harbor_username" ] || fail 'required environment variable is empty: HARBOR_USERNAME'
[ -n "$harbor_password" ] || fail 'required environment variable is empty: HARBOR_PASSWORD'
repository="${PROMOTION_REPOSITORY%/}"
[[ "$repository" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._/-]+$ ]] || fail 'invalid promotion repository'
[[ "$repository" == */temp-poc-promotions ]] || fail 'promotion repository must end with /temp-poc-promotions'
namespace_prefix="${repository%/temp-poc-promotions}"
[ -n "$namespace_prefix" ] || fail 'promotion repository namespace is invalid'
case "$plain_http" in
  true) oras_remote_args=(--plain-http) ;;
  false) oras_remote_args=() ;;
  *) fail 'HARBOR_PLAIN_HTTP must be true or false' ;;
esac
[[ "$GITHUB_RUN_ID" =~ ^[1-9][0-9]*$ ]] || fail 'GITHUB_RUN_ID must be a positive integer'
[[ "$GITHUB_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]] || fail 'GITHUB_RUN_ATTEMPT must be a positive integer'

for tool in jq sha256sum cmp wc grep mktemp "$oras_bin"; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command not found: $tool"
done

jq -e --arg revision "$source_sha" --arg namespace "$namespace_prefix/" '
  type == "object" and
  (keys | sort) == ["apiVersion", "images", "kind", "release", "source"] and
  .apiVersion == "scalex.io/v1alpha1" and
  .kind == "ReleasePromotion" and
  .release == "temp-poc" and
  .source == {
    repoURL: "https://github.com/BellTigerLee/temp-poc.git",
    path: "chart",
    revision: $revision
  } and
  (.images | type == "object" and length > 0) and
  all(.images | to_entries[];
    (.key | test("^[a-z0-9]+(-[a-z0-9]+)*$")) and
    (.value | type == "object") and
    (.value | keys | sort) == ["digest", "repository", "sourceRevision", "tag"] and
    (.value.repository | type == "string" and startswith($namespace)) and
    (.value.tag | type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")) and
    .value.sourceRevision == $revision and
    (.value.digest | type == "string" and test("^sha256:[0-9a-f]{64}$"))
  )
' "$payload" >/dev/null || fail 'invalid ReleasePromotion payload contract'

run_oras() {
  env -u HARBOR_USERNAME -u HARBOR_PASSWORD "$oras_bin" "$@"
}

umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
chmod 0700 "$tmp"
registry_config="$tmp/registry-config.json"
printf '{}\n' >"$registry_config"
chmod 0600 "$registry_config"
candidate_payload="$tmp/promotion.json"
cp "$payload" "$candidate_payload"
cmp --silent "$payload" "$candidate_payload" || fail 'failed to preserve payload bytes'

run_oras version >"$tmp/version.out" 2>"$tmp/version.err" || fail 'failed to query ORAS version'
grep -Eq '(^|[^0-9])1\.3\.3([^0-9]|$)' "$tmp/version.out" || fail 'ORAS CLI version must be 1.3.3'
printf '%s\n' "$harbor_password" | run_oras login \
  "${oras_remote_args[@]}" \
  --registry-config "$registry_config" \
  --username "$harbor_username" \
  --password-stdin "${repository%%/*}" \
  >"$tmp/login.out" 2>"$tmp/login.err" || fail 'ORAS registry login failed'

VERIFIED_DIGEST=''
verify_artifact() {
  local reference="$1" expected_manifest="$2" work="$tmp/verify"
  local descriptor="$work/descriptor.json" manifest="$work/manifest.json" pull_dir="$work/pull"
  local digest size pulled layer_digest layer_size
  rm -rf "$work"
  mkdir -m 0700 "$work" "$pull_dir"

  run_oras manifest fetch "${oras_remote_args[@]}" --registry-config "$registry_config" --descriptor "$reference" \
    >"$descriptor" 2>"$work/descriptor.err" || fail 'failed to fetch manifest descriptor'
  jq -e --arg mediaType "$manifest_type" '
    .mediaType == $mediaType and
    (.digest | test("^sha256:[0-9a-f]{64}$")) and
    (.size | type == "number" and . >= 0 and floor == .)
  ' "$descriptor" >/dev/null || fail 'invalid manifest descriptor'
  digest="$(jq -r '.digest' "$descriptor")"
  size="$(jq -r '.size' "$descriptor")"

  run_oras manifest fetch "${oras_remote_args[@]}" --registry-config "$registry_config" --output "$manifest" "$repository@$digest" \
    >"$work/fetch.out" 2>"$work/fetch.err" || fail 'failed to fetch manifest content'
  [ "sha256:$(sha256sum "$manifest" | cut -d' ' -f1)" = "$digest" ] || fail 'manifest digest mismatch'
  [ "$(wc -c <"$manifest" | tr -d ' ')" = "$size" ] || fail 'manifest size mismatch'
  [ -z "$expected_manifest" ] || cmp --silent "$expected_manifest" "$manifest" || fail 'exported manifest differs from registry'
  jq -e --arg artifactType "$artifact_type" --arg layerType "$layer_type" '
    .schemaVersion == 2 and
    .mediaType == "application/vnd.oci.image.manifest.v1+json" and
    .artifactType == $artifactType and
    (.layers | length) == 1 and
    .layers[0].mediaType == $layerType and
    (.layers[0].digest | test("^sha256:[0-9a-f]{64}$")) and
    (.layers[0].size | type == "number" and . >= 0 and floor == .)
  ' "$manifest" >/dev/null || fail 'invalid promotion artifact manifest'
  layer_digest="$(jq -r '.layers[0].digest' "$manifest")"
  layer_size="$(jq -r '.layers[0].size' "$manifest")"

  run_oras pull "${oras_remote_args[@]}" --registry-config "$registry_config" --no-tty --output "$pull_dir" "$repository@$digest" \
    >"$work/pull.out" 2>"$work/pull.err" || fail 'failed to pull promotion artifact'
  shopt -s nullglob dotglob
  pulled=("$pull_dir"/*)
  shopt -u nullglob dotglob
  [ "${#pulled[@]}" -eq 1 ] && [ -f "${pulled[0]}" ] && [ ! -L "${pulled[0]}" ] || fail 'promotion artifact must contain one payload file'
  [ "$layer_digest" = "sha256:$(sha256sum "${pulled[0]}" | cut -d' ' -f1)" ] || fail 'promotion layer digest mismatch'
  [ "$layer_size" = "$(wc -c <"${pulled[0]}" | tr -d ' ')" ] || fail 'promotion layer size mismatch'
  cmp --silent "$candidate_payload" "${pulled[0]}" || fail 'promotion payload bytes differ'
  VERIFIED_DIGEST="$digest"
}

immutable_ref="$repository:sha-$source_sha-run-$GITHUB_RUN_ID-attempt-$GITHUB_RUN_ATTEMPT"
if run_oras manifest fetch "${oras_remote_args[@]}" --registry-config "$registry_config" --descriptor "$immutable_ref" \
    >"$tmp/existing.json" 2>"$tmp/existing.err"; then
  verify_artifact "$immutable_ref" ''
else
  grep -Eqi 'not[ -]?found|404|manifest unknown|name unknown' "$tmp/existing.err" || fail 'failed to resolve immutable artifact'
  exported_manifest="$tmp/exported-manifest.json"
  run_oras push "${oras_remote_args[@]}" --registry-config "$registry_config" --no-tty \
    --artifact-type "$artifact_type" --export-manifest "$exported_manifest" \
    "$immutable_ref" "$candidate_payload:$layer_type" \
    >"$tmp/push.out" 2>"$tmp/push.err" || fail 'failed to push immutable promotion artifact'
  verify_artifact "$immutable_ref" "$exported_manifest"
  [ "$VERIFIED_DIGEST" = "sha256:$(sha256sum "$exported_manifest" | cut -d' ' -f1)" ] || fail 'exported manifest digest mismatch'
fi
candidate_digest="$VERIFIED_DIGEST"
printf '%s\n' "$candidate_digest"
