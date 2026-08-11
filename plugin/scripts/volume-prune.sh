#!/usr/bin/env bash
# Removes an explicit list of volumes, after re-checking each one is still
# unreferenced. Never calls `docker volume prune`, whose meaning changed in
# Docker 23 and therefore differs between Unraid 6.12 and 7.x.
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VALID_NAME='^[A-Za-z0-9][A-Za-z0-9_.-]*$'

docker_root() {
  local root
  root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
  [[ -n "$root" ]] || root="/var/lib/docker"
  printf '%s' "$root"
}

volume_bytes() { # docker-root name
  local path="$1/volumes/$2"
  [[ -d "$path" ]] || { printf '0'; return 0; }
  local bytes
  bytes="$(du -sb "$path" 2>/dev/null | awk '{print $1}')"
  [[ "$bytes" =~ ^[0-9]+$ ]] && printf '%s' "$bytes" || printf '0'
}

main() {
  load_cfg

  if (( $# == 0 )); then
    echo "Usage: volume-prune.sh NAME [NAME...]" >&2
    return 2
  fi

  if ! docker_available; then
    echo "Docker is not running." >&2
    return 1
  fi

  # Re-taken at confirm time, not reused from the preview. A container that
  # started while the dialog was open must not lose its volume.
  local unused
  unused="$(docker volume ls -q --filter dangling=true 2>/dev/null)"

  local root name total=0
  local -a keep=()
  root="$(docker_root)"

  for name in "$@"; do
    if [[ ! "$name" =~ $VALID_NAME ]]; then
      echo "REJECTED $name (invalid name)"
      continue
    fi
    if ! printf '%s\n' "$unused" | grep -qxF -- "$name"; then
      echo "SKIPPED $name (in use)"
      continue
    fi
    keep+=("$name")
    total=$(( total + $(volume_bytes "$root" "$name") ))
  done

  if (( ${#keep[@]} == 0 )); then
    echo "TOTAL 0B"
    echo "Nothing was removed."
    log_line "volume prune: nothing removed"
    return 1
  fi

  local output status
  output="$(docker volume rm -- "${keep[@]}" 2>&1)"
  status=$?
  printf '%s\n' "$output" | log_block

  if (( status != 0 )); then
    printf '%s\n' "$output"
    echo "TOTAL 0B"
    log_line "volume prune failed with exit $status"
    return 1
  fi

  for name in "${keep[@]}"; do
    echo "REMOVED $name"
  done
  echo "TOTAL $(human_bytes "$total")"
  log_line "volume prune removed ${#keep[@]} volume(s), $(human_bytes "$total"): ${keep[*]}"
  return 0
}

main "$@"
