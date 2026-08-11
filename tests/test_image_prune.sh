#!/usr/bin/env bash

prune() {
  bash "$REPO_ROOT/plugin/scripts/image-prune.sh"
}

lastrun_field() { # index (1=time 2=status 3=message)
  awk -F'|' -v i="$1" '{print $i}' "$LASTRUN_FILE"
}

test_runs_exactly_the_specified_command() {
  write_cfg
  prune >/dev/null 2>&1
  assert_contains "$(stub_log)" "docker image prune -a -f"
}

test_never_touches_volumes() {
  write_cfg
  prune >/dev/null 2>&1
  assert_not_contains "$(stub_log)" "volume"
}

test_reports_reclaimed_space() {
  write_cfg
  export STUB_RECLAIMED="7.25GB"
  local out
  out="$(prune 2>&1)"
  assert_contains "$out" "7.25GB"
}

test_writes_lastrun_ok() {
  write_cfg
  export STUB_RECLAIMED="7.25GB"
  prune >/dev/null 2>&1
  assert_file_exists "$LASTRUN_FILE"
  assert_eq "$(lastrun_field 2)" "ok"
  assert_contains "$(lastrun_field 3)" "7.25GB"
}

test_zero_reclaim_still_succeeds() {
  write_cfg
  export STUB_RECLAIMED="0B"
  local status
  prune >/dev/null 2>&1
  status=$?
  assert_status "$status" 0
  assert_eq "$(lastrun_field 2)" "ok"
  assert_contains "$(lastrun_field 3)" "0B"
}

test_notifies_normal_on_success() {
  write_cfg NOTIFY=yes
  prune >/dev/null 2>&1
  local log
  log="$(stub_log)"
  assert_contains "$log" "notify "
  assert_contains "$log" "-i normal"
}

test_does_not_notify_when_disabled() {
  write_cfg NOTIFY=no
  prune >/dev/null 2>&1
  assert_not_contains "$(stub_log)" "notify "
}

test_skips_cleanly_when_docker_is_down() {
  write_cfg
  export STUB_DOCKER_INFO_STATUS=1
  local status out
  out="$(prune 2>&1)"
  status=$?
  assert_status "$status" 0
  assert_contains "$out" "not running"
  assert_eq "$(lastrun_field 2)" "skipped"
  assert_not_contains "$(stub_log)" "image prune"
}

test_no_notification_when_docker_is_down() {
  write_cfg NOTIFY=yes
  export STUB_DOCKER_INFO_STATUS=1
  prune >/dev/null 2>&1
  assert_not_contains "$(stub_log)" "notify "
}

test_docker_failure_is_reported_and_notified_as_warning() {
  write_cfg NOTIFY=yes
  export STUB_IMAGE_PRUNE_STATUS=1
  local status
  prune >/dev/null 2>&1
  status=$?
  [[ "$status" != "0" ]] || fail "expected a non-zero exit when docker fails"
  assert_eq "$(lastrun_field 2)" "error"
  assert_contains "$(stub_log)" "-i warning"
}

test_output_is_logged() {
  write_cfg
  prune >/dev/null 2>&1
  assert_file_exists "$LOG_FILE"
  assert_contains "$(cat "$LOG_FILE")" "Total reclaimed space"
}

test_lock_prevents_a_concurrent_run() {
  write_cfg
  # Hold the lock in a background process, then try to run.
  exec 8>"$LOCK_FILE"
  flock -n 8 || fail "could not take the lock for the test"
  local out status
  out="$(prune 2>&1)"
  status=$?
  exec 8>&-
  assert_status "$status" 0
  assert_contains "$out" "already in progress"
  assert_not_contains "$(stub_log)" "image prune"
}
