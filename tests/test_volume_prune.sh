#!/usr/bin/env bash

volume_prune() {
  bash "$REPO_ROOT/plugin/scripts/volume-prune.sh" "$@"
}

make_volume() { # name bytes
  local dir="$TMP/dockerroot/volumes/$1/_data"
  mkdir -p "$dir"
  head -c "$2" /dev/zero > "$dir/blob"
  export STUB_DOCKER_ROOT="$TMP/dockerroot"
}

test_removes_the_requested_volumes() {
  export STUB_DANGLING=$'orphan_one\norphan_two'
  make_volume orphan_one 1024
  make_volume orphan_two 1024
  local out
  out="$(volume_prune orphan_one orphan_two)"
  assert_contains "$out" "REMOVED orphan_one"
  assert_contains "$out" "REMOVED orphan_two"
  assert_contains "$(stub_log)" "volume rm -- orphan_one orphan_two"
}

test_never_calls_docker_volume_prune() {
  export STUB_DANGLING="orphan_one"
  make_volume orphan_one 1024
  volume_prune orphan_one >/dev/null 2>&1
  assert_not_contains "$(stub_log)" "volume prune"
}

test_skips_a_volume_that_became_used_after_preview() {
  # Preview showed both; by confirm time only orphan_one is still dangling.
  export STUB_DANGLING="orphan_one"
  make_volume orphan_one 1024
  local out
  out="$(volume_prune orphan_one now_in_use)"
  assert_contains "$out" "REMOVED orphan_one"
  assert_contains "$out" "SKIPPED now_in_use"
  assert_not_contains "$(stub_log)" "now_in_use"
}

test_rejects_a_name_with_shell_metacharacters() {
  export STUB_DANGLING="orphan_one"
  make_volume orphan_one 1024
  local out
  out="$(volume_prune 'orphan_one; rm -rf /')"
  assert_contains "$out" "REJECTED"
  assert_not_contains "$(stub_log)" "volume rm"
}

test_rejects_a_name_starting_with_a_dash() {
  export STUB_DANGLING="orphan_one"
  local out
  out="$(volume_prune '--force')"
  assert_contains "$out" "REJECTED"
  assert_not_contains "$(stub_log)" "volume rm"
}

test_reports_total_space_reclaimed() {
  export STUB_DANGLING="orphan_one"
  make_volume orphan_one 2097152
  local out
  out="$(volume_prune orphan_one)"
  assert_contains "$out" "TOTAL"
  assert_contains "$out" "MB"
}

test_usage_error_without_arguments() {
  local status
  volume_prune >/dev/null 2>&1
  status=$?
  assert_status "$status" 2
}

test_fails_when_docker_is_down() {
  export STUB_DOCKER_INFO_STATUS=1
  local out status
  out="$(volume_prune orphan_one 2>&1)"
  status=$?
  assert_status "$status" 1
  assert_contains "$out" "not running"
}

test_docker_rm_failure_is_reported() {
  export STUB_DANGLING="orphan_one"
  export STUB_VOLUME_RM_STATUS=1
  make_volume orphan_one 1024
  local status
  volume_prune orphan_one >/dev/null 2>&1
  status=$?
  assert_status "$status" 1
}

test_removal_is_logged() {
  export STUB_DANGLING="orphan_one"
  make_volume orphan_one 1024
  volume_prune orphan_one >/dev/null 2>&1
  assert_contains "$(cat "$LOG_FILE")" "orphan_one"
}
