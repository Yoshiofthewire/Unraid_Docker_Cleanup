#!/usr/bin/env bash
# Shared helpers for the Docker Cleanup plugin.
# Every path may be overridden by environment variable so the test suite never
# touches a real system path.

PLUGIN="docker.cleanup"
PLUGIN_ROOT="${PLUGIN_ROOT:-/usr/local/emhttp/plugins/$PLUGIN}"
BOOT_CONFIG="${BOOT_CONFIG:-/boot/config/plugins/$PLUGIN}"
CFG_FILE="${CFG_FILE:-$BOOT_CONFIG/$PLUGIN.cfg}"
CRON_FILE="${CRON_FILE:-$BOOT_CONFIG/$PLUGIN.cron}"
LASTRUN_FILE="${LASTRUN_FILE:-$BOOT_CONFIG/lastrun}"
LOG_FILE="${LOG_FILE:-/var/log/docker-cleanup.log}"
LOCK_FILE="${LOCK_FILE:-/var/run/docker-cleanup.lock}"
UPDATE_CRON="${UPDATE_CRON:-/usr/local/emhttp/webGui/scripts/update_cron}"
NOTIFY_BIN="${NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-1048576}"

# Config defaults. load_cfg overwrites these from the config file.
export ENABLED="no"
export SCHEDULE="daily"
export HOUR="3"
export MINUTE="0"
export DAY_OF_WEEK="0"
export DAY_OF_MONTH="1"
export CUSTOM_CRON=""
export NOTIFY="yes"

# Parse the config file. Deliberately NOT `source` — the file lives on a
# user-writable flash share and must never be executed.
load_cfg() {
  local file="${1:-$CFG_FILE}"
  [[ -f "$file" ]] || return 0
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key//[[:space:]]/}"
    value="${value#\"}"
    value="${value%\"}"
    case "$key" in
      ENABLED|SCHEDULE|HOUR|MINUTE|DAY_OF_WEEK|DAY_OF_MONTH|CUSTOM_CRON|NOTIFY)
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done < "$file"
}

trim_log() {
  [[ -f "$LOG_FILE" ]] || return 0
  local size
  size="$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)"
  if (( size > LOG_MAX_BYTES )); then
    tail -c "$(( LOG_MAX_BYTES / 2 ))" "$LOG_FILE" > "$LOG_FILE.tmp" \
      && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
}

log_line() {
  mkdir -p "$(dirname "$LOG_FILE")"
  printf '%s %s\n' "$(date -Iseconds)" "$*" >> "$LOG_FILE"
  trim_log
}

# Append a block of output read from stdin.
log_block() {
  mkdir -p "$(dirname "$LOG_FILE")"
  cat >> "$LOG_FILE"
  trim_log
}

notify_user() { # subject detail [normal|warning]
  [[ "$NOTIFY" == "yes" ]] || return 0
  [[ -x "$NOTIFY_BIN" ]] || return 0
  "$NOTIFY_BIN" -e "Docker Cleanup" -s "$1" -d "$2" -i "${3:-normal}" >/dev/null 2>&1
  return 0
}

write_lastrun() { # status message
  mkdir -p "$(dirname "$LASTRUN_FILE")"
  printf '%s|%s|%s\n' "$(date -Iseconds)" "$1" "$2" > "$LASTRUN_FILE"
}

docker_available() {
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1
}

human_bytes() { # bytes
  local b="${1:-}"
  if [[ ! "$b" =~ ^[0-9]+$ ]]; then
    printf 'unknown'
    return 0
  fi
  local units=(B KB MB GB TB) i=0
  while (( b >= 1024 && i < 4 )); do
    b=$(( b / 1024 ))
    (( i++ ))
  done
  printf '%s%s' "$b" "${units[$i]}"
}
