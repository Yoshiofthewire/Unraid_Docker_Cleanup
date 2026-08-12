#!/usr/bin/env bash
# Removes every Docker image no container references. Run by cron and by the
# Run Now button, so what you test by hand is what runs on schedule.
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

parse_reclaimed() { # full docker output
  local line
  line="$(printf '%s\n' "$1" | grep -i 'Total reclaimed space:' | tail -n1)"
  if [[ -z "$line" ]]; then
    printf '0B'
  else
    printf '%s' "${line#*: }"
  fi
}

main() {
  load_cfg

  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE" || { echo "Could not open the lock file $LOCK_FILE" >&2; return 1; }
  if ! flock -n 9; then
    echo "Another cleanup run is already in progress; skipping."
    log_line "skipped: another run in progress"
    write_lastrun "skipped" "Another cleanup run already in progress"
    return 0
  fi

  if ! docker_available; then
    echo "Docker is not running; nothing to do."
    log_line "skipped: docker not running"
    write_lastrun "skipped" "Docker not running"
    return 0
  fi

  echo "Running: docker image prune -a -f"
  local output status
  output="$(docker image prune -a -f 2>&1)"
  status=$?
  printf '%s\n' "$output"
  printf '%s\n' "$output" | log_block

  if (( status != 0 )); then
    log_line "image prune failed with exit $status"
    write_lastrun "error" "docker image prune failed (exit $status)"
    notify_user "Image prune failed" \
      "docker image prune exited $status. See $LOG_FILE for details." "warning"
    return "$status"
  fi

  local reclaimed
  reclaimed="$(parse_reclaimed "$output")"
  log_line "image prune ok, reclaimed $reclaimed"
  write_lastrun "ok" "Reclaimed $reclaimed"
  notify_user "Image prune complete" "Reclaimed $reclaimed" "normal"
  echo "Reclaimed $reclaimed"
  return 0
}

main "$@"
