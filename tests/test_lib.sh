#!/usr/bin/env bash

lib() {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/plugin/scripts/lib.sh"
}

test_load_cfg_reads_quoted_values() {
  write_cfg SCHEDULE=weekly HOUR=7 DAY_OF_WEEK=3
  lib
  load_cfg
  assert_eq "$SCHEDULE" "weekly"
  assert_eq "$HOUR" "7"
  assert_eq "$DAY_OF_WEEK" "3"
}

test_load_cfg_keeps_defaults_when_file_absent() {
  lib
  load_cfg
  assert_eq "$SCHEDULE" "daily"
  assert_eq "$HOUR" "3"
  assert_eq "$MINUTE" "0"
  assert_eq "$ENABLED" "no"
}

test_load_cfg_ignores_unknown_and_malformed_keys() {
  mkdir -p "$(dirname "$CFG_FILE")"
  cat > "$CFG_FILE" <<'EOF'
ENABLED="yes"
EVIL="$(touch /tmp/dc-pwned)"
lower="nope"
# a comment
HOUR="9"
EOF
  lib
  load_cfg
  assert_eq "$ENABLED" "yes"
  assert_eq "$HOUR" "9"
  assert_file_missing "/tmp/dc-pwned"
}

test_load_cfg_does_not_execute_command_substitution() {
  mkdir -p "$(dirname "$CFG_FILE")"
  printf "SCHEDULE=\"\$(echo pwned)\"\n" > "$CFG_FILE"
  lib
  load_cfg
  assert_eq "$SCHEDULE" "\$(echo pwned)"
}

test_log_line_creates_and_appends() {
  lib
  log_line "first message"
  log_line "second message"
  assert_file_exists "$LOG_FILE"
  local content
  content="$(cat "$LOG_FILE")"
  assert_contains "$content" "first message"
  assert_contains "$content" "second message"
}

test_trim_log_caps_the_file() {
  lib
  LOG_MAX_BYTES=2048
  : "${LOG_MAX_BYTES}"  # used by trim_log
  mkdir -p "$(dirname "$LOG_FILE")"
  head -c 8192 /dev/zero | tr '\0' 'x' > "$LOG_FILE"
  trim_log
  local size
  size="$(stat -c %s "$LOG_FILE")"
  (( size <= 2048 )) || fail "expected log trimmed to <= 2048 bytes, got $size"
}

test_write_lastrun_uses_three_pipe_fields() {
  lib
  write_lastrun "ok" "Reclaimed 4.509GB"
  assert_file_exists "$LASTRUN_FILE"
  local line
  line="$(cat "$LASTRUN_FILE")"
  assert_contains "$line" "|ok|Reclaimed 4.509GB"
  local fields
  fields="$(awk -F'|' '{print NF}' "$LASTRUN_FILE")"
  assert_eq "$fields" "3"
}

test_notify_user_calls_notify_binary() {
  lib
  NOTIFY="yes"
  notify_user "Subject here" "Detail here" "normal"
  local log
  log="$(stub_log)"
  assert_contains "$log" "notify "
  assert_contains "$log" "Docker Cleanup"
  assert_contains "$log" "Subject here"
  assert_contains "$log" "Detail here"
}

test_notify_user_silent_when_disabled() {
  lib
  NOTIFY="no"
  : "${NOTIFY}"  # used by notify_user
  notify_user "Subject here" "Detail here" "normal"
  assert_not_contains "$(stub_log)" "notify "
}

test_docker_available_true_when_info_succeeds() {
  lib
  if docker_available; then :; else fail "expected docker_available to succeed"; fi
}

test_docker_available_false_when_info_fails() {
  lib
  export STUB_DOCKER_INFO_STATUS=1
  if docker_available; then fail "expected docker_available to fail"; fi
}

test_human_bytes_scales_units() {
  lib
  assert_eq "$(human_bytes 0)" "0B"
  assert_eq "$(human_bytes 1023)" "1023B"
  assert_eq "$(human_bytes 2048)" "2KB"
  assert_eq "$(human_bytes 2097152)" "2MB"
  assert_eq "$(human_bytes 3221225472)" "3GB"
}

test_human_bytes_reports_unknown_for_garbage() {
  lib
  assert_eq "$(human_bytes -1)" "unknown"
  assert_eq "$(human_bytes '')" "unknown"
}
