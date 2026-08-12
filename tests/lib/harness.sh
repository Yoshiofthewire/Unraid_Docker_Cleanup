#!/usr/bin/env bash
# Per-test environment. Every path points inside a throwaway temp directory so
# a test can never touch a real system path.

setup_env() {
  TMP="$(mktemp -d)"
  export TMP
  export PLUGIN_ROOT="$REPO_ROOT/plugin"
  export BOOT_CONFIG="$TMP/boot/config/plugins/docker.cleanup"
  export CFG_FILE="$BOOT_CONFIG/docker.cleanup.cfg"
  export CRON_FILE="$BOOT_CONFIG/docker.cleanup.cron"
  export LASTRUN_FILE="$BOOT_CONFIG/lastrun"
  export LOG_FILE="$TMP/log/docker-cleanup.log"
  export LOCK_FILE="$TMP/docker-cleanup.lock"
  export UPDATE_CRON="$TMP/bin/update_cron"
  export NOTIFY_BIN="$TMP/bin/notify"
  export STUB_LOG="$TMP/stub.log"

  mkdir -p "$BOOT_CONFIG" "$TMP/bin" "$TMP/log"
  : > "$STUB_LOG"

  cp "$REPO_ROOT/tests/stubs/docker"      "$TMP/bin/docker"
  cp "$REPO_ROOT/tests/stubs/notify"      "$TMP/bin/notify"
  cp "$REPO_ROOT/tests/stubs/update_cron" "$TMP/bin/update_cron"
  chmod +x "$TMP/bin/docker" "$TMP/bin/notify" "$TMP/bin/update_cron"

  export PATH="$TMP/bin:$PATH"
}

teardown_env() {
  [[ -n "${TMP:-}" && "$TMP" == /tmp/* ]] && rm -rf "$TMP"
  return 0
}

# Write a config file with the given KEY=value overrides on top of the defaults.
write_cfg() { # KEY=value ...
  local -A cfg=(
    [ENABLED]=yes [SCHEDULE]=daily [HOUR]=3 [MINUTE]=0
    [DAY_OF_WEEK]=0 [DAY_OF_MONTH]=1 [CUSTOM_CRON]="" [NOTIFY]=yes
  )
  local pair key
  for pair in "$@"; do
    key="${pair%%=*}"
    cfg["$key"]="${pair#*=}"
  done
  mkdir -p "$(dirname "$CFG_FILE")"
  : > "$CFG_FILE"
  for key in ENABLED SCHEDULE HOUR MINUTE DAY_OF_WEEK DAY_OF_MONTH CUSTOM_CRON NOTIFY; do
    printf '%s="%s"\n' "$key" "${cfg[$key]}" >> "$CFG_FILE"
  done
}

# Everything the stubs recorded this test.
stub_log() {
  cat "$STUB_LOG" 2>/dev/null || true
}
