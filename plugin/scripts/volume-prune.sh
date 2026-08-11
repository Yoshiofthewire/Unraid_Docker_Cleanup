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

# A rejected argument is, by definition, unvalidated — it may be arbitrary
# bytes, including a newline crafted to look like a separate line of this
# script's own output (e.g. a forged "REMOVED <name>" line fed to Task 7's
# parser). Strip anything that isn't a legal name character before it is
# ever echoed back.
sanitize_for_display() { # arbitrary string
  local s="$1"
  s="${s//[^A-Za-z0-9_.-]/}"
  printf '%s' "$s"
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
  local unused unused_status
  unused="$(docker volume ls -q --filter dangling=true 2>/dev/null)"
  unused_status=$?
  if (( unused_status != 0 )); then
    echo "Docker is not running." >&2
    return 1
  fi

  local root name total=0
  local -a keep=()
  local -A seen=() vol_bytes=()
  root="$(docker_root)"

  local seen_key
  for name in "$@"; do
    # A caller (the web layer, or anything replaying its request) may repeat
    # a name. Process each distinct name once so it cannot be double-counted
    # in TOTAL or double-passed to `docker volume rm`. Prefixed so an empty
    # argument doesn't produce an empty (invalid) array subscript.
    seen_key="n:$name"
    if [[ -n "${seen[$seen_key]+x}" ]]; then
      continue
    fi
    seen[$seen_key]=1

    if [[ ! "$name" =~ $VALID_NAME ]]; then
      echo "REJECTED $(sanitize_for_display "$name") (invalid name)"
      continue
    fi
    if ! grep -qxF -- "$name" <<<"$unused"; then
      echo "SKIPPED $name (in use)"
      continue
    fi
    keep+=("$name")
    vol_bytes["$name"]="$(volume_bytes "$root" "$name")"
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
    # A batch `docker volume rm` can remove some operands before failing on
    # another — e.g. a container claimed one mid-run. Do not assume the
    # whole batch failed: re-check what is actually still there rather than
    # reporting a single all-or-nothing result.
    local remaining remaining_status
    remaining="$(docker volume ls -q 2>/dev/null)"
    remaining_status=$?
    for name in "${keep[@]}"; do
      if (( remaining_status == 0 )) && ! grep -qxF -- "$name" <<<"$remaining"; then
        echo "REMOVED $name"
        total=$(( total + vol_bytes["$name"] ))
      else
        echo "SKIPPED $name (in use)"
      fi
    done
    echo "TOTAL $(human_bytes "$total")"
    log_line "volume prune failed with exit $status"
    return 1
  fi

  for name in "${keep[@]}"; do
    echo "REMOVED $name"
    total=$(( total + vol_bytes["$name"] ))
  done
  echo "TOTAL $(human_bytes "$total")"
  log_line "volume prune removed ${#keep[@]} volume(s), $(human_bytes "$total"): ${keep[*]}"
  return 0
}

main "$@"
