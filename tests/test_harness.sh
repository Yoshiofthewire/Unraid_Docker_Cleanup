#!/usr/bin/env bash

test_harness_isolates_paths() {
  assert_contains "$BOOT_CONFIG" "$TMP"
  assert_contains "$CFG_FILE" "docker.cleanup.cfg"
  [[ -d "$BOOT_CONFIG" ]] || fail "BOOT_CONFIG was not created"
}

test_harness_puts_stub_docker_on_path() {
  local resolved
  resolved="$(command -v docker)"
  assert_eq "$resolved" "$TMP/bin/docker"
}

test_stub_docker_records_arguments() {
  docker info >/dev/null 2>&1
  assert_contains "$(stub_log)" "docker info"
}

test_stub_docker_info_can_fail() {
  local status
  STUB_DOCKER_INFO_STATUS=1 docker info >/dev/null 2>&1
  status=$?
  assert_status "$status" 1
}

test_write_cfg_writes_all_keys() {
  write_cfg SCHEDULE=weekly HOUR=5
  local content
  content="$(cat "$CFG_FILE")"
  assert_contains "$content" 'SCHEDULE="weekly"'
  assert_contains "$content" 'HOUR="5"'
  assert_contains "$content" 'ENABLED="yes"'
  assert_contains "$content" 'NOTIFY="yes"'
}
