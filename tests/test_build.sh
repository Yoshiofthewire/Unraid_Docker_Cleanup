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

# Slackware package naming: name-version-arch-build. Keep the tests' notion
# of the built filename in one place so a version change doesn't need
# hunting through every test.
pkg_txz() { # version
  printf 'docker.cleanup-%s-x86_64-1.txz' "$1"
}

# True if $1 (a tar listing, one member per line) contains a line that is
# exactly equal to $2. assert_contains would also pass for "/usr/..." or
# "./usr/..." since both contain "usr/..." as a substring — precisely the
# defect the "no leading slash, no extra directory level" requirement exists
# to catch — so member checks need exact-line matching instead.
listing_has_exact_member() { # listing member
  local listing="$1" member="$2" line
  while IFS= read -r line; do
    [[ "$line" == "$member" ]] && return 0
  done <<< "$listing"
  return 1
}

test_build_produces_a_package_and_checksum() {
  stage_repo
  build 2026.08.11 >/dev/null
  local txz
  txz="$TMP/repo/release/$(pkg_txz 2026.08.11)"
  assert_file_exists "$txz"
  assert_file_exists "$txz.md5"
}

test_package_has_the_unraid_path_layout() {
  stage_repo
  build 2026.08.11 >/dev/null
  local listing
  listing="$(tar -tf "$TMP/repo/release/$(pkg_txz 2026.08.11)")"

  local member members=(
    "usr/local/emhttp/plugins/docker.cleanup/DockerCleanup.page"
    "usr/local/emhttp/plugins/docker.cleanup/default.cfg"
    "usr/local/emhttp/plugins/docker.cleanup/scripts/image-prune.sh"
    "usr/local/emhttp/plugins/docker.cleanup/scripts/cron-apply.sh"
    "usr/local/emhttp/plugins/docker.cleanup/include/config.php"
  )
  for member in "${members[@]}"; do
    listing_has_exact_member "$listing" "$member" \
      || fail "expected exact member '$member', got: $listing"
  done

  # No member may carry a leading '/' or './' — that would mean the archive
  # isn't rooted the way Unraid's installer expects.
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case "$line" in
      /*|./*) fail "member has a leading path prefix: $line" ;;
    esac
  done <<< "$listing"
}

test_package_scripts_are_executable() {
  stage_repo
  build 2026.08.11 >/dev/null
  local listing
  listing="$(tar -tvf "$TMP/repo/release/$(pkg_txz 2026.08.11)")"

  local script scripts=(cron-apply.sh image-prune.sh lib.sh volume-list.sh volume-prune.sh)
  for script in "${scripts[@]}"; do
    local mode
    mode="$(printf '%s\n' "$listing" | grep "scripts/${script}\$" | awk '{print $1}')"
    [[ -n "$mode" ]] || fail "scripts/$script not found in package listing"
    assert_contains "$mode" "x"
  done
}

test_package_is_owned_by_root() {
  stage_repo
  build 2026.08.11 >/dev/null
  local listing
  listing="$(tar -tvf "$TMP/repo/release/$(pkg_txz 2026.08.11)")"

  local line owner
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    owner="$(awk '{print $2}' <<< "$line")"
    assert_eq "$owner" "0/0" "$line"
  done <<< "$listing"
}

test_plg_is_stamped_with_version_and_md5() {
  stage_repo
  build 2026.08.11 >/dev/null
  local plg md5
  plg="$(cat "$TMP/repo/docker.cleanup.plg")"
  md5="$(cat "$TMP/repo/release/$(pkg_txz 2026.08.11).md5")"
  assert_contains "$plg" '"2026.08.11"'
  assert_contains "$plg" "$md5"
  assert_not_contains "$plg" "PLACEHOLDER"
}

test_build_rejects_a_malformed_version() {
  stage_repo
  local status
  build "not-a-version" >/dev/null 2>&1
  status=$?
  assert_status "$status" 1
  assert_file_missing "$TMP/repo/release"
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

# Malformed XML is the critical failure mode for this file — Unraid's
# installer chokes on it with a useless error — and every other test here
# only inspects it as raw text. A bare '&&' or stray '<' would sail through
# assert_contains/assert_not_contains, so this test actually parses it.
# Checked against the real repo file, not a staged copy, and prefers a local
# parser before falling back to Docker.
test_plg_is_well_formed_xml() {
  local plg="$REPO_ROOT/docker.cleanup.plg"
  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$plg" 2>&1 || fail "docker.cleanup.plg is not well-formed XML (xmllint)"
  elif command -v python3 >/dev/null 2>&1; then
    # Prefer defusedxml (guards against XXE/entity-expansion attacks) and
    # fall back to the stdlib parser only if it isn't installed. This file
    # is our own repo artifact, not attacker-controlled input, but there's
    # no reason not to take the safer parser when it's available.
    python3 -c "
try:
    import defusedxml.ElementTree as ET
except ImportError:
    import xml.etree.ElementTree as ET
import sys
ET.parse(sys.argv[1])
" "$plg" || fail "docker.cleanup.plg is not well-formed XML (python3)"
  elif command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$REPO_ROOT:/mnt" -w /mnt alpine:3 \
      sh -c "apk add --no-cache --quiet libxml2-utils >/dev/null 2>&1 && xmllint --noout docker.cleanup.plg" \
      || fail "docker.cleanup.plg is not well-formed XML (docker xmllint)"
  else
    fail "no XML parser available to validate docker.cleanup.plg (need xmllint, python3, or docker)"
  fi
}
