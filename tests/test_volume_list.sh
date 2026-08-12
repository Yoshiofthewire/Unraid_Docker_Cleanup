#!/usr/bin/env bash

volume_list() {
  bash "$REPO_ROOT/plugin/scripts/volume-list.sh"
}

# Build a fake docker root with volume directories of known size.
make_volume() { # name bytes
  local dir="$TMP/dockerroot/volumes/$1/_data"
  mkdir -p "$dir"
  head -c "$2" /dev/zero > "$dir/blob"
  export STUB_DOCKER_ROOT="$TMP/dockerroot"
}

test_lists_only_dangling_volumes() {
  export STUB_DANGLING=$'orphan_one\norphan_two'
  make_volume orphan_one 1024
  make_volume orphan_two 2048
  local out
  out="$(volume_list)"
  assert_contains "$out" "orphan_one"
  assert_contains "$out" "orphan_two"
  assert_contains "$(stub_log)" "volume ls -q --filter dangling=true"
}

test_emits_three_tab_separated_fields() {
  export STUB_DANGLING="orphan_one"
  make_volume orphan_one 1024
  local fields
  fields="$(volume_list | head -n1 | awk -F'\t' '{print NF}')"
  assert_eq "$fields" "3"
}

test_reports_a_plausible_size() {
  export STUB_DANGLING="orphan_one"
  make_volume orphan_one 4096
  local bytes
  bytes="$(volume_list | awk -F'\t' '{print $2}')"
  [[ "$bytes" =~ ^[0-9]+$ ]] || fail "expected a byte count, got '$bytes'"
  (( bytes >= 4096 )) || fail "expected at least 4096 bytes, got $bytes"
}

test_flags_anonymous_volumes() {
  local anon="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  export STUB_DANGLING="$anon"
  make_volume "$anon" 512
  assert_eq "$(volume_list | awk -F'\t' '{print $3}')" "yes"
}

test_flags_named_volumes() {
  export STUB_DANGLING="portainer_data"
  make_volume portainer_data 512
  assert_eq "$(volume_list | awk -F'\t' '{print $3}')" "no"
}

test_missing_volume_directory_reports_minus_one() {
  export STUB_DANGLING="ghost_volume"
  export STUB_DOCKER_ROOT="$TMP/dockerroot"
  mkdir -p "$TMP/dockerroot/volumes"
  assert_eq "$(volume_list | awk -F'\t' '{print $2}')" "-1"
}

test_permission_denied_volume_reports_minus_one() {
  if [[ "$(id -u)" -eq 0 ]]; then
    echo "SKIP: running as root, directory permission bits are not enforced" >&2
    return 0
  fi
  export STUB_DANGLING="locked_volume"
  make_volume locked_volume 4096
  local dir="$TMP/dockerroot/volumes/locked_volume"
  chmod 000 "$dir"
  local bytes
  bytes="$(volume_list | awk -F'\t' '{print $2}')"
  chmod 755 "$dir"
  assert_eq "$bytes" "-1"
}

test_empty_when_nothing_is_dangling() {
  export STUB_DANGLING=""
  export STUB_DOCKER_ROOT="$TMP/dockerroot"
  mkdir -p "$TMP/dockerroot/volumes"
  local out status
  out="$(volume_list)"
  status=$?
  assert_status "$status" 0
  assert_eq "$out" ""
}

test_fails_clearly_when_docker_is_down() {
  export STUB_DOCKER_INFO_STATUS=1
  local out status
  out="$(volume_list 2>&1)"
  status=$?
  assert_status "$status" 1
  assert_contains "$out" "not running"
}
