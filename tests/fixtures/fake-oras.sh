#!/usr/bin/env bash
set -euo pipefail

state="${FAKE_ORAS_STATE:?FAKE_ORAS_STATE is required}"
fault="${FAKE_ORAS_FAULT:-}"
mkdir -p "$state/tags" "$state/manifests" "$state/payloads"
printf '%q ' "$@" >>"$state/commands.log"
printf '\n' >>"$state/commands.log"

if [ "${1:-}" != fixture ]; then
  [ -z "${HARBOR_USERNAME:-}" ]
  [ -z "${HARBOR_PASSWORD:-}" ]
fi

key() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
tag_file() { printf '%s/tags/%s' "$state" "$(key "$1")"; }

resolve() {
  if [[ "$1" == *@sha256:* ]]; then
    printf '%s\n' "${1##*@}"
  elif [ -f "$(tag_file "$1")" ]; then
    cat "$(tag_file "$1")"
  else
    echo "not found: $1" >&2
    return 1
  fi
}

write_artifact() {
  local reference="$1" payload="$2" export_path="${3:-}"
  local payload_digest payload_size manifest digest
  payload_digest="sha256:$(sha256sum "$payload" | cut -d' ' -f1)"
  payload_size="$(wc -c <"$payload" | tr -d ' ')"
  manifest="$(jq -cn \
    --arg payloadDigest "$payload_digest" \
    --argjson payloadSize "$payload_size" '{
      schemaVersion: 2,
      mediaType: "application/vnd.oci.image.manifest.v1+json",
      artifactType: "application/vnd.scalex.release-promotion.v1+json",
      layers: [{
        mediaType: "application/vnd.scalex.release-promotion.payload.v1+json",
        digest: $payloadDigest,
        size: $payloadSize,
        annotations: {"org.opencontainers.image.title": "promotion.json"}
      }]
    }')"
  [ "$fault" != bad_layer ] || manifest="$(jq -c '.layers[0].mediaType = "application/example"' <<<"$manifest")"
  digest="sha256:$(printf '%s' "$manifest" | sha256sum | cut -d' ' -f1)"
  printf '%s' "$manifest" >"$state/manifests/${digest#sha256:}.json"
  cp "$payload" "$state/payloads/${digest#sha256:}"
  printf '%s\n' "$digest" >"$(tag_file "$reference")"
  [ -z "$export_path" ] || printf '%s' "$manifest" >"$export_path"
  printf '%s\n' "$digest"
}

check_config() {
  local path="$1"
  [ -f "$path" ]
  [ "$(stat -c '%a' "$path")" = 600 ]
  [ "$(stat -c '%a' "$(dirname "$path")")" = 700 ]
  printf '%s\n' "$path" >>"$state/config-paths.log"
}

case "${1:-}" in
  version)
    echo 'Version: 1.3.3'
    ;;
  fixture)
    case "$2" in
      seed) write_artifact "$3" "$4" >/dev/null ;;
      resolve) resolve "$3" ;;
      *) exit 2 ;;
    esac
    ;;
  login)
    shift
    config= username=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --registry-config) config="$2"; shift 2 ;;
        --username) username="$2"; shift 2 ;;
        --password-stdin) shift ;;
        *) shift ;;
      esac
    done
    check_config "$config"
    IFS= read -r password
    [ "$username" = robot ]
    [ "$password" = "${FAKE_ORAS_PASSWORD:-test-password}" ]
    [ "$fault" != login ] || exit 1
    ;;
  push)
    shift
    config= export_path= reference= layer=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --registry-config) config="$2"; shift 2 ;;
        --artifact-type) [ "$2" = 'application/vnd.scalex.release-promotion.v1+json' ]; shift 2 ;;
        --export-manifest) export_path="$2"; shift 2 ;;
        --no-tty) shift ;;
        *) if [ -z "$reference" ]; then reference="$1"; else layer="$1"; fi; shift ;;
      esac
    done
    check_config "$config"
    [ "${layer##*:}" = 'application/vnd.scalex.release-promotion.payload.v1+json' ]
    [ "$fault" != push ] || exit 1
    write_artifact "$reference" "${layer%:*}" "$export_path"
    ;;
  manifest)
    [ "$2" = fetch ]
    shift 2
    config= descriptor=false output= reference=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --registry-config) config="$2"; shift 2 ;;
        --descriptor) descriptor=true; shift ;;
        --output) output="$2"; shift 2 ;;
        *) reference="$1"; shift ;;
      esac
    done
    check_config "$config"
    digest="$(resolve "$reference")"
    manifest="$state/manifests/${digest#sha256:}.json"
    [ -f "$manifest" ]
    if [ "$descriptor" = true ]; then
      if [ "$fault" = post_resolve ] && [ -f "$state/tagged" ] && [[ "$reference" == *:latest-verified ]]; then
        jq -cn '{mediaType:"application/vnd.oci.image.manifest.v1+json",digest:("sha256:"+("f"*64)),size:1}'
      else
        size="$(wc -c <"$manifest" | tr -d ' ')"
        jq -cn --arg digest "$digest" --argjson size "$size" '{mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$digest,size:$size}'
      fi
    else
      [ "$fault" != fetch ] || exit 1
      if [ -n "$output" ]; then cp "$manifest" "$output"; else cat "$manifest"; fi
    fi
    ;;
  pull)
    shift
    config= output= reference=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --registry-config) config="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        --no-tty) shift ;;
        *) reference="$1"; shift ;;
      esac
    done
    check_config "$config"
    [ "$fault" != pull ] || exit 1
    digest="$(resolve "$reference")"
    mkdir -p "$output"
    cp "$state/payloads/${digest#sha256:}" "$output/promotion.json"
    [ "$fault" != bad_bytes ] || printf '\ncorrupt\n' >>"$output/promotion.json"
    ;;
  tag)
    shift
    config= reference= new_tag=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --registry-config) config="$2"; shift 2 ;;
        *) if [ -z "$reference" ]; then reference="$1"; else new_tag="$1"; fi; shift ;;
      esac
    done
    check_config "$config"
    [ "$fault" != tag ] || exit 1
    digest="$(resolve "$reference")"
    printf '%s\n' "$digest" >"$(tag_file "${reference%@*}:$new_tag")"
    : >"$state/tagged"
    ;;
  *) exit 2 ;;
esac
