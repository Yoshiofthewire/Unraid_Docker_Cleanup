#!/usr/bin/env bash

handlers() {
  find "$REPO_ROOT/plugin/include" -name '*.php' ! -name 'config.php' -printf '%f\n' | sort
}

test_every_handler_requires_csrf() {
  local file content
  while IFS= read -r file; do
    content="$(cat "$REPO_ROOT/plugin/include/$file")"
    assert_contains "$content" "dc_require_csrf();"
  done < <(handlers)
}

test_csrf_check_precedes_any_exec_or_popen() {
  local file guard_line first_call
  while IFS= read -r file; do
    guard_line="$(grep -n 'dc_require_csrf();' "$REPO_ROOT/plugin/include/$file" | head -n1 | cut -d: -f1)"
    first_call="$(grep -nE '\b(exec|popen|shell_exec|system|passthru)\(' \
      "$REPO_ROOT/plugin/include/$file" | head -n1 | cut -d: -f1)"
    [[ -n "$guard_line" ]] || fail "$file has no CSRF guard"
    if [[ -n "$first_call" ]] && (( first_call < guard_line )); then
      fail "$file runs a command on line $first_call, before the CSRF guard on line $guard_line"
    fi
  done < <(handlers)
}

test_no_handler_interpolates_post_data_into_a_command() {
  local file hits
  while IFS= read -r file; do
    # shellcheck disable=SC2016 # intentional: literal $_ in a regex, not a shell expansion
    hits="$(grep -nE '\b(exec|popen|shell_exec|system|passthru)\([^)]*\$_(POST|GET|REQUEST)' \
      "$REPO_ROOT/plugin/include/$file" || true)"
    [[ -z "$hits" ]] || fail "$file passes request data straight to a shell: $hits"
  done < <(handlers)
}

test_handlers_never_call_docker_directly() {
  local file content
  while IFS= read -r file; do
    content="$(cat "$REPO_ROOT/plugin/include/$file")"
    assert_not_contains "$content" "docker "
  done < <(handlers)
}

page() {
  cat "$REPO_ROOT/plugin/DockerCleanup.page"
}

# Unraid's markdown renderer merged the two forms on a real 7.3 server, so
# FormData(form) picked up a duplicate csrf_token — and would just as easily
# have dropped one. Bodies are built from named fields instead.
test_page_never_scrapes_a_form_for_a_request_body() {
  assert_not_contains "$(page)" "new FormData("
}

test_page_renders_no_csrf_inputs_into_the_markup() {
  local hits
  hits="$(grep -nE '<input[^>]*csrf_token' "$REPO_ROOT/plugin/DockerCleanup.page" || true)"
  [[ -z "$hits" ]] || fail "csrf inputs must be appended by script, not rendered: $hits"
}

# A proxy's 504 page and the webGui login page are both HTML, and both landed
# verbatim in the status line before this check existed.
test_page_does_not_print_a_raw_response_body_as_status() {
  assert_not_contains "$(page)" "textContent = text.trim()"
  assert_contains "$(page)" "dcReadReply"
}

# Reading $var directly renders a blank token whenever the webGui has not
# populated that global, which silently breaks every button on the page.
test_page_reads_the_token_through_the_shared_helper() {
  assert_not_contains "$(page)" 'csrf_token'"'"']'
  assert_contains "$(page)" 'dc_csrf_token()'
}
