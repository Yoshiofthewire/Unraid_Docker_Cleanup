#!/usr/bin/env bash

build() {
  ( cd "$TMP/repo" && bash build/build.sh "$@" )
}

# Copy the repo into the temp dir so the build never dirties the real tree.
stage_repo() {
  mkdir -p "$TMP/repo"
  cp -a "$REPO_ROOT/plugin" "$TMP/repo/"
  cp -a "$REPO_ROOT/build" "$TMP/repo/"
  cp "$REPO_ROOT/docker.cleanup.plg" "$TMP/repo/"
}

test_build_produces_a_package_and_checksum() {
  stage_repo
  build 2026.08.11 >/dev/null
  assert_file_exists "$TMP/repo/release/docker.cleanup-2026.08.11.txz"
  assert_file_exists "$TMP/repo/release/docker.cleanup-2026.08.11.txz.md5"
}

test_package_has_the_unraid_path_layout() {
  stage_repo
  build 2026.08.11 >/dev/null
  local listing
  listing="$(tar -tf "$TMP/repo/release/docker.cleanup-2026.08.11.txz")"
  assert_contains "$listing" "usr/local/emhttp/plugins/docker.cleanup/DockerCleanup.page"
  assert_contains "$listing" "usr/local/emhttp/plugins/docker.cleanup/scripts/image-prune.sh"
  assert_contains "$listing" "usr/local/emhttp/plugins/docker.cleanup/include/config.php"
}

test_package_scripts_are_executable() {
  stage_repo
  build 2026.08.11 >/dev/null
  local mode
  mode="$(tar -tvf "$TMP/repo/release/docker.cleanup-2026.08.11.txz" \
    | grep 'scripts/image-prune.sh' | awk '{print $1}')"
  assert_contains "$mode" "x"
}

test_package_is_owned_by_root() {
  stage_repo
  build 2026.08.11 >/dev/null
  local owner
  owner="$(tar -tvf "$TMP/repo/release/docker.cleanup-2026.08.11.txz" \
    | grep 'DockerCleanup.page' | awk '{print $2}')"
  assert_eq "$owner" "0/0"
}

test_plg_is_stamped_with_version_and_md5() {
  stage_repo
  build 2026.08.11 >/dev/null
  local plg md5
  plg="$(cat "$TMP/repo/docker.cleanup.plg")"
  md5="$(cat "$TMP/repo/release/docker.cleanup-2026.08.11.txz.md5")"
  assert_contains "$plg" '"2026.08.11"'
  assert_contains "$plg" "$md5"
  assert_not_contains "$plg" "PLACEHOLDER"
}

test_plg_declares_the_minimum_unraid_version() {
  assert_contains "$(cat "$REPO_ROOT/docker.cleanup.plg")" 'min="6.12.0"'
}

test_plg_remove_keeps_the_config() {
  local plg
  plg="$(cat "$REPO_ROOT/docker.cleanup.plg")"
  assert_contains "$plg" 'Method="remove"'
  assert_not_contains "$plg" 'rm -rf /boot/config/plugins/&name;'
}

test_plg_remove_disables_cron() {
  assert_contains "$(cat "$REPO_ROOT/docker.cleanup.plg")" "cron-apply.sh --disable"
}
