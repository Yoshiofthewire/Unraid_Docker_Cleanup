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
  # A good name travels alongside the bad one so the assertion actually
  # exercises `docker volume rm` instead of trivially passing because
  # `keep` was empty.
  export STUB_DANGLING="orphan_one"
  make_volume orphan_one 1024
  local out
  out="$(volume_prune orphan_one 'orphan_one; rm -rf /')"
  assert_contains "$out" "REJECTED"
  assert_contains "$out" "REMOVED orphan_one"
  assert_contains "$(stub_log)" "volume rm -- orphan_one"
  assert_not_contains "$(stub_log)" "rm -rf"
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
  # STUB_VOLUME_RM_STATUS makes the whole batch fail before Docker touches
  # any operand, so nothing was actually removed. The recheck must report
  # that honestly rather than claiming REMOVED for a volume still present.
  export STUB_DANGLING="orphan_one"
  export STUB_VOLUME_RM_STATUS=1
  make_volume orphan_one 1024
  local out status
  out="$(volume_prune orphan_one 2>&1)"
  status=$?
  assert_status "$status" 1
  assert_contains "$out" "SKIPPED orphan_one (in use)"
  assert_not_contains "$out" "REMOVED orphan_one"
}

test_partial_rm_failure_reports_what_was_actually_removed() {
  # docker volume rm can remove some operands before failing on another
  # (e.g. a container claimed one mid-run). orphan_one succeeds, orphan_two
  # fails; STUB_ALL_VOLUMES models the post-attempt state Docker would
  # actually report: orphan_one gone, orphan_two still there.
  export STUB_DANGLING=$'orphan_one\norphan_two'
  export STUB_VOLUME_RM_FAIL="orphan_two"
  export STUB_ALL_VOLUMES="orphan_two"
  make_volume orphan_one 1024
  make_volume orphan_two 1024
  local out status
  out="$(volume_prune orphan_one orphan_two 2>&1)"
  status=$?
  assert_status "$status" 1
  assert_contains "$out" "REMOVED orphan_one"
  assert_contains "$out" "SKIPPED orphan_two (in use)"
  assert_contains "$out" "TOTAL 1KB"
}

test_removal_is_logged() {
  # Assert on the audit line specifically, not just any occurrence of the
  # name — the stub's `volume rm` also echoes operand names into the same
  # log via log_block, so a weaker assertion would pass even if log_line
  # were deleted from the success path entirely.
  export STUB_DANGLING="orphan_one"
  make_volume orphan_one 1024
  volume_prune orphan_one >/dev/null 2>&1
  assert_contains "$(cat "$LOG_FILE")" "volume prune removed 1 volume(s), 1KB: orphan_one"
}

test_duplicate_arguments_are_deduplicated() {
  export STUB_DANGLING="orphan_one"
  make_volume orphan_one 1024
  local out removed_count
  out="$(volume_prune orphan_one orphan_one)"
  removed_count="$(printf '%s\n' "$out" | grep -c '^REMOVED orphan_one$')"
  assert_eq "$removed_count" "1"
  assert_contains "$out" "TOTAL 1KB"
  assert_contains "$(stub_log)" "volume rm -- orphan_one"
  assert_not_contains "$(stub_log)" "orphan_one orphan_one"
}

test_rejected_name_with_embedded_newline_cannot_forge_a_removed_line() {
  export STUB_DANGLING="orphan_one"
  make_volume orphan_one 1024
  local out
  out="$(volume_prune $'x\nREMOVED important_db')"
  assert_contains "$out" "REJECTED"
  assert_not_contains "$out" "REMOVED important_db"
}

test_rejects_an_empty_string_argument() {
  export STUB_DANGLING="orphan_one"
  local out
  out="$(volume_prune '')"
  assert_contains "$out" "REJECTED"
  assert_not_contains "$(stub_log)" "volume rm"
}

test_rejects_a_name_with_a_glob_character() {
  export STUB_DANGLING="orphan_one"
  local out
  out="$(volume_prune 'orphan_*')"
  assert_contains "$out" "REJECTED"
  assert_not_contains "$(stub_log)" "volume rm"
}

test_reports_zero_for_a_volume_with_no_directory_on_disk() {
  export STUB_DANGLING="ghost_volume"
  export STUB_DOCKER_ROOT="$TMP/dockerroot"
  mkdir -p "$TMP/dockerroot/volumes"
  local out
  out="$(volume_prune ghost_volume)"
  assert_contains "$out" "REMOVED ghost_volume"
  assert_contains "$out" "TOTAL 0B"
}

test_skips_when_dangling_list_is_entirely_empty() {
  export STUB_DANGLING=""
  local out
  out="$(volume_prune orphan_one)"
  assert_contains "$out" "SKIPPED orphan_one (in use)"
  assert_not_contains "$(stub_log)" "volume rm"
}
