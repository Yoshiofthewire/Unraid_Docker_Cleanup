#!/usr/bin/env bash
# Lists every volume no container references, with its size on disk.
# Output: name<TAB>bytes<TAB>anonymous(yes|no). Size -1 means unreadable.
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

docker_root() {
  local root
  root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
  [[ -n "$root" ]] || root="/var/lib/docker"
  printf '%s' "$root"
}

volume_size() { # docker-root name
  local path="$1/volumes/$2"
  if [[ ! -d "$path" ]]; then
    printf '%s' "-1"
    return 0
  fi
  if [[ ! -r "$path" || ! -x "$path" ]]; then
    printf '%s' "-1"
    return 0
  fi
  local bytes status
  bytes="$(du -sb "$path" 2>/dev/null | awk '{print $1}')"
  status=$?
  if [[ "$status" -eq 0 && "$bytes" =~ ^[0-9]+$ ]]; then
    printf '%s' "$bytes"
  else
    printf '%s' "-1"
  fi
}

is_anonymous() { # name
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

main() {
  if ! docker_available; then
    echo "Docker is not running." >&2
    return 1
  fi

  local root name anon
  root="$(docker_root)"

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if is_anonymous "$name"; then anon="yes"; else anon="no"; fi
    printf '%s\t%s\t%s\n' "$name" "$(volume_size "$root" "$name")" "$anon"
  done < <(docker volume ls -q --filter dangling=true 2>/dev/null | sort)

  return 0
}

main "$@"
