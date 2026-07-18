#!/usr/bin/env bash
set -euo pipefail

if [ -n "${FAKE_DOCKER_LOG:-}" ]; then
  printf '%q ' "$@" >>"$FAKE_DOCKER_LOG"
  printf '\n' >>"$FAKE_DOCKER_LOG"
fi

case "${1:-}" in
  build|push|tag)
    exit 0
    ;;
  image)
    [ "${2:-}" = inspect ] && [ "${4:-}" = --format ] && \
      [ "${5:-}" = '{{json .RepoDigests}}' ] || {
      echo "unexpected docker image command" >&2
      exit 1
    }
    repository="${3%:*}"
    [[ "$repository" == */temp-poc-* ]] || {
      echo "unexpected image reference: $3" >&2
      exit 1
    }
    digest="$(printf '%s' "$repository" | sha256sum | cut -d' ' -f1)"
    printf '["%s@sha256:%s"]\n' "$repository" "$digest"
    ;;
  *)
    echo "unexpected docker command: $*" >&2
    exit 1
    ;;
esac
