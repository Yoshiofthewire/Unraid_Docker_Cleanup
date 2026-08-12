# Docker Cleanup Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an Unraid plugin (`docker.cleanup`) that runs `docker image prune -a -f` on a user-controlled schedule and offers a manual, confirmation-gated removal of unused Docker volumes.

**Architecture:** All decision logic lives in POSIX-ish bash scripts under `plugin/scripts/`, which the test suite drives with a stub `docker` on `PATH`. The PHP layer under `plugin/include/` is deliberately thin — CSRF check, argument marshalling, output formatting — because PHP is the part this repository cannot test deeply. Scheduling goes through Unraid's dynamix convention: write a cron fragment to flash, then call `update_cron`.

**Tech Stack:** Bash 4+, PHP 8 (Unraid webGui), Slackware `.txz` packaging, Unraid `.plg` installer XML. Tests are plain bash. Lint runs in Docker containers so nothing installs on the dev machine.

**Spec:** `docs/superpowers/specs/2026-08-11-docker-cleanup-plugin-design.md`

## Global Constraints

- Plugin slug is `docker.cleanup` everywhere — directory, cfg filename, cron filename, `.plg` ENTITY.
- Target Unraid 6.12 and 7.x. `.plg` declares `min="6.12.0"`.
- Volume deletion is never scheduled, never runs on install, and never runs without a previewed, confirmed list.
- Scheduling only ever writes `/boot/config/plugins/docker.cleanup/docker.cleanup.cron` then calls `/usr/local/emhttp/webGui/scripts/update_cron`. Never edit a crontab directly.
- Every path constant in every shell script must be overridable by environment variable, defaulting to the real location. Tests depend on this.
- Never `source` the config file. Parse it. It lives on a user-writable flash share.
- Every PHP POST handler calls `dc_require_csrf()` as its first statement after the require.
- Shell scripts use `set -uo pipefail` (not `-e`; control flow is explicit) and pass `shellcheck` with no warnings.
- Verbose output goes to `/var/log/docker-cleanup.log` (RAM). Flash gets one line per run, in `lastrun`.
- `lastrun` format is `timestamp|status|message`, status ∈ `ok` | `error` | `skipped`.
- Uninstall keeps `docker.cleanup.cfg` and `lastrun` on flash.
- Two different defaults, both deliberate — do not "fix" either: `default.cfg`
  ships `ENABLED="yes"` (installing the plugin schedules the job, as asked),
  while `lib.sh`'s in-code fallback is `ENABLED="no"` (a missing or unreadable
  config must never schedule anything).
- Commit after every task.

---

### Task 1: Repository scaffolding and test harness

**Files:**
- Create: `.gitignore`
- Create: `test`
- Create: `tests/run.sh`
- Create: `tests/lib/runone.sh`
- Create: `tests/lib/assert.sh`
- Create: `tests/lib/harness.sh`
- Create: `tests/stubs/docker`
- Create: `tests/stubs/notify`
- Create: `tests/stubs/update_cron`
- Create: `tests/test_harness.sh`
- Create: `plugin/scripts/.gitkeep`

**Interfaces:**
- Consumes: nothing
- Produces: `./test` runs lint + the whole suite. Test files are `tests/test_*.sh` defining functions named `test_*`. Each test function runs in its own subshell with a fresh temp directory and these exported variables: `REPO_ROOT`, `TMP`, `PLUGIN_ROOT`, `BOOT_CONFIG`, `CFG_FILE`, `CRON_FILE`, `LASTRUN_FILE`, `LOG_FILE`, `LOCK_FILE`, `UPDATE_CRON`, `NOTIFY_BIN`, `STUB_LOG`. Assertion helpers: `assert_eq`, `assert_contains`, `assert_not_contains`, `assert_file_exists`, `assert_file_missing`, `assert_status`, `fail`. Stub control variables: `STUB_DOCKER_INFO_STATUS`, `STUB_DOCKER_ROOT`, `STUB_IMAGE_PRUNE_STATUS`, `STUB_RECLAIMED`, `STUB_DANGLING`, `STUB_VOLUME_RM_STATUS`, `STUB_UPDATE_CRON_STATUS`.

- [ ] **Step 1: Write `.gitignore`**

```
release/
*.txz
*.txz.md5
.DS_Store
```

- [ ] **Step 2: Write the assertion library**

Create `tests/lib/assert.sh`:

```bash
#!/usr/bin/env bash
# Assertion helpers. Every failure exits non-zero, which the runner records.

fail() {
  printf 'ASSERT FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() { # actual expected [message]
  [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'${3:+ — $3}"
}

assert_contains() { # haystack needle
  [[ "$1" == *"$2"* ]] || fail "expected output to contain '$2', got: $1"
}

assert_not_contains() { # haystack needle
  [[ "$1" != *"$2"* ]] || fail "expected output NOT to contain '$2', got: $1"
}

assert_file_exists() {
  [[ -f "$1" ]] || fail "expected file to exist: $1"
}

assert_file_missing() {
  [[ ! -e "$1" ]] || fail "expected path to be absent: $1"
}

assert_status() { # actual expected
  [[ "$1" == "$2" ]] || fail "expected exit status $2, got $1"
}
```

- [ ] **Step 3: Write the harness**

Create `tests/lib/harness.sh`:

```bash
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
```

- [ ] **Step 4: Write the stubs**

Create `tests/stubs/docker`:

```bash
#!/usr/bin/env bash
# Stub docker. Records its arguments and returns canned output. Behaviour is
# driven entirely by STUB_* environment variables.
printf 'docker %s\n' "$*" >> "${STUB_LOG:-/dev/null}"

case "${1:-}" in
  info)
    if [[ "${STUB_DOCKER_INFO_STATUS:-0}" != "0" ]]; then
      echo "Cannot connect to the Docker daemon" >&2
      exit "${STUB_DOCKER_INFO_STATUS}"
    fi
    if [[ "${2:-}" == "--format" ]]; then
      printf '%s\n' "${STUB_DOCKER_ROOT:-/var/lib/docker}"
    fi
    exit 0
    ;;
  image)
    if [[ "${STUB_IMAGE_PRUNE_STATUS:-0}" != "0" ]]; then
      echo "Error response from daemon: conflict" >&2
      exit "${STUB_IMAGE_PRUNE_STATUS}"
    fi
    printf 'Deleted Images:\nuntagged: example/app:latest\n\nTotal reclaimed space: %s\n' \
      "${STUB_RECLAIMED:-4.509GB}"
    exit 0
    ;;
  volume)
    case "${2:-}" in
      ls)
        printf '%s' "${STUB_DANGLING:-}" | grep -v '^[[:space:]]*$'
        exit 0
        ;;
      rm)
        if [[ "${STUB_VOLUME_RM_STATUS:-0}" != "0" ]]; then
          echo "Error response from daemon: volume is in use" >&2
          exit "${STUB_VOLUME_RM_STATUS}"
        fi
        shift 2
        for arg in "$@"; do
          [[ "$arg" == "--" ]] && continue
          printf '%s\n' "$arg"
        done
        exit 0
        ;;
    esac
    ;;
esac

echo "stub docker: unhandled invocation: $*" >&2
exit 99
```

Create `tests/stubs/notify`:

```bash
#!/usr/bin/env bash
printf 'notify %s\n' "$*" >> "${STUB_LOG:-/dev/null}"
exit 0
```

Create `tests/stubs/update_cron`:

```bash
#!/usr/bin/env bash
printf 'update_cron\n' >> "${STUB_LOG:-/dev/null}"
exit "${STUB_UPDATE_CRON_STATUS:-0}"
```

- [ ] **Step 5: Write the single-test executor**

Create `tests/lib/runone.sh`:

```bash
#!/usr/bin/env bash
# Runs exactly one test function in a clean environment. Invoked by run.sh.
# Usage: runone.sh <test-file> <function-name>
set -uo pipefail

# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/harness.sh"
# shellcheck source=/dev/null
source "$1"

setup_env
trap teardown_env EXIT
"$2"
```

- [ ] **Step 6: Write the runner**

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
# Discovers tests/test_*.sh, runs every test_* function each defines in its own
# subshell, and prints a summary.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

filter="${1:-}"
passed=0
failed=0
failures=()

for file in "$REPO_ROOT"/tests/test_*.sh; do
  [[ -f "$file" ]] || continue
  mapfile -t fns < <(bash -c "source '$file' >/dev/null 2>&1; declare -F" \
    | awk '{print $3}' | grep '^test_' | sort)
  for fn in "${fns[@]:-}"; do
    [[ -n "$fn" ]] || continue
    if [[ -n "$filter" && "$fn" != *"$filter"* ]]; then continue; fi
    output="$(bash "$REPO_ROOT/tests/lib/runone.sh" "$file" "$fn" 2>&1)"
    status=$?
    if (( status == 0 )); then
      printf '  ok   %s\n' "$fn"
      passed=$(( passed + 1 ))
    else
      printf '  FAIL %s\n' "$fn"
      printf '%s\n' "$output" | sed 's/^/         /'
      failures+=("$fn")
      failed=$(( failed + 1 ))
    fi
  done
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
if (( failed > 0 )); then
  printf 'failed: %s\n' "${failures[*]}"
fi
(( failed == 0 ))
```

- [ ] **Step 7: Write the top-level `test` entry point**

Create `test`:

```bash
#!/usr/bin/env bash
# Single entry point: lint, then unit tests.
# Lint runs in Docker so nothing has to be installed on the dev machine.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT" || exit 1
status=0

if [[ "${SKIP_LINT:-0}" != "1" ]]; then
  if command -v docker >/dev/null 2>&1; then
    echo "== shellcheck =="
    mapfile -t sh_files < <(
      find plugin tests build -type f -name '*.sh' 2>/dev/null
      printf '%s\n' test tests/stubs/docker tests/stubs/notify tests/stubs/update_cron
    )
    docker run --rm -v "$REPO_ROOT:/mnt" -w /mnt koalaman/shellcheck:stable \
      --shell=bash --external-sources "${sh_files[@]}" || status=1

    echo "== php -l =="
    while IFS= read -r php_file; do
      docker run --rm -v "$REPO_ROOT:/mnt" -w /mnt php:8-cli php -l "$php_file" || status=1
    done < <(find plugin -type f -name '*.php' 2>/dev/null)
  else
    echo "docker not found — skipping lint" >&2
  fi
fi

echo "== unit tests =="
bash tests/run.sh "$@" || status=1

exit "$status"
```

- [ ] **Step 8: Write a test that proves the harness works**

Create `tests/test_harness.sh`:

```bash
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
```

- [ ] **Step 9: Make everything executable and run the suite**

```bash
chmod +x test tests/run.sh tests/lib/runone.sh tests/stubs/docker tests/stubs/notify tests/stubs/update_cron
./test
```

Expected: shellcheck and `php -l` produce no findings (there are no PHP files yet, so that loop is a no-op), and all five harness tests pass with `5 passed, 0 failed`.

- [ ] **Step 10: Commit**

```bash
git add .gitignore test tests plugin
git commit -m "test: add bash test harness with stub docker

Plain-bash runner so the suite has no dependencies; lint runs in
Docker containers so nothing installs on the dev machine.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Shared shell library

**Files:**
- Create: `plugin/scripts/lib.sh`
- Create: `plugin/default.cfg`
- Test: `tests/test_lib.sh`

**Interfaces:**
- Consumes: the harness from Task 1.
- Produces: `plugin/scripts/lib.sh`, sourced by every other script. Exports variables `PLUGIN`, `PLUGIN_ROOT`, `BOOT_CONFIG`, `CFG_FILE`, `CRON_FILE`, `LASTRUN_FILE`, `LOG_FILE`, `LOCK_FILE`, `UPDATE_CRON`, `NOTIFY_BIN`, `LOG_MAX_BYTES`, and the config variables `ENABLED SCHEDULE HOUR MINUTE DAY_OF_WEEK DAY_OF_MONTH CUSTOM_CRON NOTIFY`. Functions: `load_cfg [file]`, `log_line <msg>`, `log_block` (reads stdin), `trim_log`, `notify_user <subject> <detail> [normal|warning]`, `write_lastrun <status> <message>`, `docker_available`, `human_bytes <n>`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_lib.sh`:

```bash
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
  printf 'SCHEDULE="$(echo pwned)"\n' > "$CFG_FILE"
  lib
  load_cfg
  assert_eq "$SCHEDULE" '$(echo pwned)'
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `SKIP_LINT=1 ./test test_load_cfg`
Expected: FAIL — `plugin/scripts/lib.sh` does not exist, so `source` errors.

- [ ] **Step 3: Write the library**

Create `plugin/scripts/lib.sh`:

```bash
#!/usr/bin/env bash
# Shared helpers for the Docker Cleanup plugin.
# Every path may be overridden by environment variable so the test suite never
# touches a real system path.

PLUGIN="docker.cleanup"
PLUGIN_ROOT="${PLUGIN_ROOT:-/usr/local/emhttp/plugins/$PLUGIN}"
BOOT_CONFIG="${BOOT_CONFIG:-/boot/config/plugins/$PLUGIN}"
CFG_FILE="${CFG_FILE:-$BOOT_CONFIG/$PLUGIN.cfg}"
CRON_FILE="${CRON_FILE:-$BOOT_CONFIG/$PLUGIN.cron}"
LASTRUN_FILE="${LASTRUN_FILE:-$BOOT_CONFIG/lastrun}"
LOG_FILE="${LOG_FILE:-/var/log/docker-cleanup.log}"
LOCK_FILE="${LOCK_FILE:-/var/run/docker-cleanup.lock}"
UPDATE_CRON="${UPDATE_CRON:-/usr/local/emhttp/webGui/scripts/update_cron}"
NOTIFY_BIN="${NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-1048576}"

# Config defaults. load_cfg overwrites these from the config file.
ENABLED="no"
SCHEDULE="daily"
HOUR="3"
MINUTE="0"
DAY_OF_WEEK="0"
DAY_OF_MONTH="1"
CUSTOM_CRON=""
NOTIFY="yes"

# Parse the config file. Deliberately NOT `source` — the file lives on a
# user-writable flash share and must never be executed.
load_cfg() {
  local file="${1:-$CFG_FILE}"
  [[ -f "$file" ]] || return 0
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key//[[:space:]]/}"
    value="${value#\"}"
    value="${value%\"}"
    case "$key" in
      ENABLED|SCHEDULE|HOUR|MINUTE|DAY_OF_WEEK|DAY_OF_MONTH|CUSTOM_CRON|NOTIFY)
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done < "$file"
}

trim_log() {
  [[ -f "$LOG_FILE" ]] || return 0
  local size
  size="$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)"
  if (( size > LOG_MAX_BYTES )); then
    tail -c "$(( LOG_MAX_BYTES / 2 ))" "$LOG_FILE" > "$LOG_FILE.tmp" \
      && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
}

log_line() {
  mkdir -p "$(dirname "$LOG_FILE")"
  printf '%s %s\n' "$(date -Iseconds)" "$*" >> "$LOG_FILE"
  trim_log
}

# Append a block of output read from stdin.
log_block() {
  mkdir -p "$(dirname "$LOG_FILE")"
  cat >> "$LOG_FILE"
  trim_log
}

notify_user() { # subject detail [normal|warning]
  [[ "$NOTIFY" == "yes" ]] || return 0
  [[ -x "$NOTIFY_BIN" ]] || return 0
  "$NOTIFY_BIN" -e "Docker Cleanup" -s "$1" -d "$2" -i "${3:-normal}" >/dev/null 2>&1
  return 0
}

write_lastrun() { # status message
  mkdir -p "$(dirname "$LASTRUN_FILE")"
  printf '%s|%s|%s\n' "$(date -Iseconds)" "$1" "$2" > "$LASTRUN_FILE"
}

docker_available() {
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1
}

human_bytes() { # bytes
  local b="${1:-}"
  if [[ ! "$b" =~ ^[0-9]+$ ]]; then
    printf 'unknown'
    return 0
  fi
  local units=(B KB MB GB TB) i=0
  while (( b >= 1024 && i < 4 )); do
    b=$(( b / 1024 ))
    (( i++ ))
  done
  printf '%s%s' "$b" "${units[$i]}"
}
```

- [ ] **Step 4: Write the shipped default config**

Create `plugin/default.cfg`:

```
ENABLED="yes"
SCHEDULE="daily"
HOUR="3"
MINUTE="0"
DAY_OF_WEEK="0"
DAY_OF_MONTH="1"
CUSTOM_CRON=""
NOTIFY="yes"
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./test`
Expected: PASS — all Task 1 and Task 2 tests green, shellcheck clean.

- [ ] **Step 6: Commit**

```bash
git add plugin/scripts/lib.sh plugin/default.cfg tests/test_lib.sh
git commit -m "feat: add shared shell library

Config is parsed, never sourced — it lives on a user-writable share.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Cron generation and application

**Files:**
- Create: `plugin/scripts/cron-apply.sh`
- Test: `tests/test_cron.sh`

**Interfaces:**
- Consumes: `lib.sh` (`load_cfg`, path variables).
- Produces: `plugin/scripts/cron-apply.sh`, invoked as:
  - `cron-apply.sh` — validate the live config, write or remove the cron fragment, run `update_cron`. Exit 0 on success, 1 on invalid config or missing `update_cron`.
  - `cron-apply.sh --validate-only --cfg FILE` — validate `FILE` and change nothing. Exit 0 valid, 1 invalid with the reason on stderr.
  - `cron-apply.sh --disable` — remove the fragment and run `update_cron` without reading config. Used by the uninstall script.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_cron.sh`:

```bash
#!/usr/bin/env bash

cron_apply() {
  bash "$REPO_ROOT/plugin/scripts/cron-apply.sh" "$@"
}

cron_line() {
  grep -v '^#' "$CRON_FILE" | grep -v '^[[:space:]]*$' | head -n1
}

cron_schedule() {
  cron_line | awk '{print $1, $2, $3, $4, $5}'
}

test_daily_schedule_expression() {
  write_cfg SCHEDULE=daily HOUR=3 MINUTE=0
  cron_apply
  assert_eq "$(cron_schedule)" "0 3 * * *"
}

test_hourly_schedule_expression() {
  write_cfg SCHEDULE=hourly MINUTE=30
  cron_apply
  assert_eq "$(cron_schedule)" "30 * * * *"
}

test_weekly_schedule_expression() {
  write_cfg SCHEDULE=weekly HOUR=4 MINUTE=15 DAY_OF_WEEK=6
  cron_apply
  assert_eq "$(cron_schedule)" "15 4 * * 6"
}

test_monthly_schedule_expression() {
  write_cfg SCHEDULE=monthly HOUR=2 MINUTE=5 DAY_OF_MONTH=28
  cron_apply
  assert_eq "$(cron_schedule)" "5 2 28 * *"
}

test_custom_schedule_expression_passes_through() {
  write_cfg SCHEDULE=custom CUSTOM_CRON="*/15 2-5 * * 1,3"
  cron_apply
  assert_eq "$(cron_schedule)" "*/15 2-5 * * 1,3"
}

test_cron_line_invokes_the_prune_script() {
  write_cfg SCHEDULE=daily
  cron_apply
  assert_contains "$(cron_line)" "/scripts/image-prune.sh"
}

test_cron_file_carries_a_generated_warning() {
  write_cfg
  cron_apply
  assert_contains "$(cat "$CRON_FILE")" "Generated by the Docker Cleanup plugin"
}

test_apply_calls_update_cron() {
  write_cfg
  cron_apply
  assert_contains "$(stub_log)" "update_cron"
}

test_disabled_removes_fragment_and_calls_update_cron() {
  write_cfg ENABLED=yes
  cron_apply
  assert_file_exists "$CRON_FILE"
  write_cfg ENABLED=no
  cron_apply
  assert_file_missing "$CRON_FILE"
  assert_contains "$(stub_log)" "update_cron"
}

test_disable_flag_removes_fragment_without_config() {
  write_cfg ENABLED=yes
  cron_apply
  assert_file_exists "$CRON_FILE"
  rm -f "$CFG_FILE"
  cron_apply --disable
  assert_file_missing "$CRON_FILE"
}

test_missing_update_cron_is_a_loud_failure() {
  write_cfg
  rm -f "$UPDATE_CRON"
  local out status
  out="$(cron_apply 2>&1)"
  status=$?
  assert_status "$status" 1
  assert_contains "$out" "update_cron"
}

test_invalid_custom_cron_is_rejected() {
  write_cfg SCHEDULE=custom CUSTOM_CRON="not a cron line"
  local out status
  out="$(cron_apply 2>&1)"
  status=$?
  assert_status "$status" 1
  assert_contains "$out" "cron"
}

test_custom_cron_with_wrong_field_count_is_rejected() {
  write_cfg SCHEDULE=custom CUSTOM_CRON="0 3 * *"
  local status
  cron_apply >/dev/null 2>&1
  status=$?
  assert_status "$status" 1
}

test_custom_cron_out_of_range_is_rejected() {
  write_cfg SCHEDULE=custom CUSTOM_CRON="0 99 * * *"
  local status
  cron_apply >/dev/null 2>&1
  status=$?
  assert_status "$status" 1
}

test_custom_cron_with_shell_metacharacters_is_rejected() {
  write_cfg SCHEDULE=custom CUSTOM_CRON='0 3 * * * ; rm -rf /'
  local status
  cron_apply >/dev/null 2>&1
  status=$?
  assert_status "$status" 1
}

test_invalid_config_leaves_existing_fragment_intact() {
  write_cfg SCHEDULE=daily HOUR=3 MINUTE=0
  cron_apply
  local before
  before="$(cat "$CRON_FILE")"
  write_cfg SCHEDULE=custom CUSTOM_CRON="garbage"
  cron_apply >/dev/null 2>&1
  assert_file_exists "$CRON_FILE"
  assert_eq "$(cat "$CRON_FILE")" "$before"
}

test_out_of_range_hour_is_rejected() {
  write_cfg SCHEDULE=daily HOUR=24
  local status
  cron_apply >/dev/null 2>&1
  status=$?
  assert_status "$status" 1
}

test_day_of_month_above_28_is_rejected() {
  write_cfg SCHEDULE=monthly DAY_OF_MONTH=31
  local status
  cron_apply >/dev/null 2>&1
  status=$?
  assert_status "$status" 1
}

test_unknown_schedule_is_rejected() {
  write_cfg SCHEDULE=fortnightly
  local status
  cron_apply >/dev/null 2>&1
  status=$?
  assert_status "$status" 1
}

test_validate_only_changes_nothing() {
  write_cfg SCHEDULE=daily
  local status
  cron_apply --validate-only --cfg "$CFG_FILE"
  status=$?
  assert_status "$status" 0
  assert_file_missing "$CRON_FILE"
  assert_not_contains "$(stub_log)" "update_cron"
}

test_validate_only_reports_invalid_config() {
  write_cfg SCHEDULE=daily MINUTE=61
  local status
  cron_apply --validate-only --cfg "$CFG_FILE" >/dev/null 2>&1
  status=$?
  assert_status "$status" 1
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `SKIP_LINT=1 ./test test_daily_schedule`
Expected: FAIL — `cron-apply.sh` does not exist.

- [ ] **Step 3: Write the script**

Create `plugin/scripts/cron-apply.sh`:

```bash
#!/usr/bin/env bash
# Validates the plugin config and applies it to cron the Unraid way: write a
# fragment to flash, then let update_cron rebuild the system crontab.
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

valid_number() { # value min max
  local value="$1" min="$2" max="$3" n
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  n=$(( 10#$value ))   # 10# so a leading zero is not read as octal
  (( n >= min && n <= max ))
}

# One cron field: *, integer, range, step, or a comma-list of those.
valid_cron_field() { # field min max
  local field="$1" min="$2" max="$3"
  [[ -n "$field" ]] || return 1
  local -a parts
  IFS=',' read -ra parts <<< "$field"
  local part range step lo hi lonum hinum
  for part in "${parts[@]}"; do
    range="${part%%/*}"
    if [[ "$part" == */* ]]; then
      step="${part#*/}"
      valid_number "$step" 1 "$max" || return 1
    fi
    case "$range" in
      '*') continue ;;
      *-*)
        lo="${range%%-*}"
        hi="${range##*-}"
        valid_number "$lo" "$min" "$max" || return 1
        valid_number "$hi" "$min" "$max" || return 1
        lonum=$(( 10#$lo ))
        hinum=$(( 10#$hi ))
        (( lonum <= hinum )) || return 1
        ;;
      *)
        valid_number "$range" "$min" "$max" || return 1
        ;;
    esac
  done
  return 0
}

valid_cron_expression() {
  local expr="$1"
  [[ "$expr" != *$'\n'* ]] || return 1
  [[ "$expr" != *%* ]] || return 1
  local -a f
  read -ra f <<< "$expr"
  (( ${#f[@]} == 5 )) || return 1
  valid_cron_field "${f[0]}" 0 59 || return 1
  valid_cron_field "${f[1]}" 0 23 || return 1
  valid_cron_field "${f[2]}" 1 31 || return 1
  valid_cron_field "${f[3]}" 1 12 || return 1
  valid_cron_field "${f[4]}" 0 7  || return 1
  return 0
}

cron_expression() {
  case "$SCHEDULE" in
    hourly)  printf '%s * * * *'    "$MINUTE" ;;
    daily)   printf '%s %s * * *'   "$MINUTE" "$HOUR" ;;
    weekly)  printf '%s %s * * %s'  "$MINUTE" "$HOUR" "$DAY_OF_WEEK" ;;
    monthly) printf '%s %s %s * *'  "$MINUTE" "$HOUR" "$DAY_OF_MONTH" ;;
    custom)  printf '%s'            "$CUSTOM_CRON" ;;
    *) return 1 ;;
  esac
}

validate_cfg() {
  case "$ENABLED" in yes|no) ;; *) echo "ENABLED must be yes or no" >&2; return 1 ;; esac
  case "$NOTIFY"  in yes|no) ;; *) echo "NOTIFY must be yes or no" >&2; return 1 ;; esac
  case "$SCHEDULE" in
    hourly|daily|weekly|monthly|custom) ;;
    *) echo "Unknown schedule: $SCHEDULE" >&2; return 1 ;;
  esac
  valid_number "$MINUTE"       0 59 || { echo "Minute must be 0-59" >&2; return 1; }
  valid_number "$HOUR"         0 23 || { echo "Hour must be 0-23" >&2; return 1; }
  valid_number "$DAY_OF_WEEK"  0 6  || { echo "Day of week must be 0-6" >&2; return 1; }
  valid_number "$DAY_OF_MONTH" 1 28 || { echo "Day of month must be 1-28" >&2; return 1; }
  local expr
  expr="$(cron_expression)" || { echo "Unknown schedule: $SCHEDULE" >&2; return 1; }
  valid_cron_expression "$expr" \
    || { echo "Invalid cron expression: $expr" >&2; return 1; }
  return 0
}

apply_cron() {
  if [[ ! -x "$UPDATE_CRON" ]]; then
    echo "Cannot apply the schedule: update_cron not found at $UPDATE_CRON" >&2
    return 1
  fi
  "$UPDATE_CRON" >/dev/null 2>&1
}

write_fragment() {
  mkdir -p "$(dirname "$CRON_FILE")"
  {
    echo "# Generated by the Docker Cleanup plugin — edits are overwritten"
    printf '%s %s/scripts/image-prune.sh &>/dev/null\n' \
      "$(cron_expression)" "$PLUGIN_ROOT"
  } > "$CRON_FILE"
}

main() {
  local validate_only=0 cfg="$CFG_FILE"
  while (( $# )); do
    case "$1" in
      --validate-only) validate_only=1 ;;
      --disable)
        rm -f "$CRON_FILE"
        apply_cron
        return $?
        ;;
      --cfg)
        shift
        cfg="${1:-}"
        [[ -n "$cfg" ]] || { echo "--cfg needs a path" >&2; return 2; }
        ;;
      *) echo "Unknown option: $1" >&2; return 2 ;;
    esac
    shift
  done

  load_cfg "$cfg"
  validate_cfg || return 1
  (( validate_only )) && return 0

  if [[ "$ENABLED" == "yes" ]]; then
    write_fragment
  else
    rm -f "$CRON_FILE"
  fi
  apply_cron
}

main "$@"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test`
Expected: PASS — every cron test green, shellcheck clean.

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/cron-apply.sh tests/test_cron.sh
git commit -m "feat: generate and apply the cron fragment

Validation runs before anything is written, so a malformed custom
expression can never reach the crontab.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Scheduled image prune

**Files:**
- Create: `plugin/scripts/image-prune.sh`
- Test: `tests/test_image_prune.sh`

**Interfaces:**
- Consumes: `lib.sh` (`load_cfg`, `log_line`, `log_block`, `notify_user`, `write_lastrun`, `docker_available`).
- Produces: `plugin/scripts/image-prune.sh`, no arguments. Prints progress to stdout, writes `lastrun`, and exits 0 on success or on a clean skip, non-zero when Docker itself fails. This is the exact path in the cron fragment from Task 3 and the command `include/run.php` streams in Task 7.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_image_prune.sh`:

```bash
#!/usr/bin/env bash

prune() {
  bash "$REPO_ROOT/plugin/scripts/image-prune.sh" "$@"
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `SKIP_LINT=1 ./test test_runs_exactly`
Expected: FAIL — `image-prune.sh` does not exist.

- [ ] **Step 3: Write the script**

Create `plugin/scripts/image-prune.sh`:

```bash
#!/usr/bin/env bash
# Removes every Docker image no container references. Run by cron and by the
# Run Now button, so what you test by hand is what runs on schedule.
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

parse_reclaimed() { # full docker output
  local line
  line="$(printf '%s\n' "$1" | grep -i 'Total reclaimed space:' | tail -n1)"
  if [[ -z "$line" ]]; then
    printf '0B'
  else
    printf '%s' "${line#*: }"
  fi
}

main() {
  load_cfg

  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE" || { echo "Could not open the lock file $LOCK_FILE" >&2; return 1; }
  if ! flock -n 9; then
    echo "Another cleanup run is already in progress; skipping."
    log_line "skipped: another run in progress"
    return 0
  fi

  if ! docker_available; then
    echo "Docker is not running; nothing to do."
    log_line "skipped: docker not running"
    write_lastrun "skipped" "Docker not running"
    return 0
  fi

  echo "Running: docker image prune -a -f"
  local output status
  output="$(docker image prune -a -f 2>&1)"
  status=$?
  printf '%s\n' "$output"
  printf '%s\n' "$output" | log_block

  if (( status != 0 )); then
    log_line "image prune failed with exit $status"
    write_lastrun "error" "docker image prune failed (exit $status)"
    notify_user "Image prune failed" \
      "docker image prune exited $status. See $LOG_FILE for details." "warning"
    return "$status"
  fi

  local reclaimed
  reclaimed="$(parse_reclaimed "$output")"
  log_line "image prune ok, reclaimed $reclaimed"
  write_lastrun "ok" "Reclaimed $reclaimed"
  notify_user "Image prune complete" "Reclaimed $reclaimed" "normal"
  echo "Reclaimed $reclaimed"
  return 0
}

main "$@"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test`
Expected: PASS — every image-prune test green.

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/image-prune.sh tests/test_image_prune.sh
git commit -m "feat: add the scheduled image prune

Locks against concurrent runs, treats a stopped Docker as a logged
skip rather than a failure.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Unused volume listing

**Files:**
- Create: `plugin/scripts/volume-list.sh`
- Test: `tests/test_volume_list.sh`

**Interfaces:**
- Consumes: `lib.sh` (`docker_available`).
- Produces: `plugin/scripts/volume-list.sh`, no arguments. Emits one TSV line per unused volume: `name<TAB>bytes<TAB>anonymous` where `anonymous` is `yes` or `no` and `bytes` is `-1` when the volume directory cannot be read. Exit 0 on success, 1 when Docker is unavailable, with the reason on stderr. Consumed by `include/volumes.php` in Task 7 and by `volume-prune.sh` in Task 6 for sizing.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_volume_list.sh`:

```bash
#!/usr/bin/env bash

volume_list() {
  bash "$REPO_ROOT/plugin/scripts/volume-list.sh" "$@"
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

test_unreadable_volume_reports_minus_one() {
  export STUB_DANGLING="ghost_volume"
  export STUB_DOCKER_ROOT="$TMP/dockerroot"
  mkdir -p "$TMP/dockerroot/volumes"
  assert_eq "$(volume_list | awk -F'\t' '{print $2}')" "-1"
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `SKIP_LINT=1 ./test test_lists_only_dangling`
Expected: FAIL — `volume-list.sh` does not exist.

- [ ] **Step 3: Write the script**

Create `plugin/scripts/volume-list.sh`:

```bash
#!/usr/bin/env bash
# Lists every volume no container references, with its size on disk.
# Output: name<TAB>bytes<TAB>anonymous(yes|no). Size -1 means unreadable.
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

docker_root() {
  local root
  root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
  [[ -n "$root" ]] || root="/var/lib/docker"
  printf '%s' "$root"
}

volume_size() { # docker-root name
  local path="$1/volumes/$2"
  if [[ ! -d "$path" ]]; then
    printf '%s' "-1"
    return 0
  fi
  local bytes
  bytes="$(du -sb "$path" 2>/dev/null | awk '{print $1}')"
  if [[ "$bytes" =~ ^[0-9]+$ ]]; then
    printf '%s' "$bytes"
  else
    printf '%s' "-1"
  fi
}

is_anonymous() { # name
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

main() {
  if ! docker_available; then
    echo "Docker is not running." >&2
    return 1
  fi

  local root name anon
  root="$(docker_root)"

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if is_anonymous "$name"; then anon="yes"; else anon="no"; fi
    printf '%s\t%s\t%s\n' "$name" "$(volume_size "$root" "$name")" "$anon"
  done < <(docker volume ls -q --filter dangling=true 2>/dev/null | sort)

  return 0
}

main "$@"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/volume-list.sh tests/test_volume_list.sh
git commit -m "feat: list unused volumes with sizes

Uses the dangling filter and du rather than parsing docker system df
JSON — stable across every Docker version Unraid ships, and Unraid
has no jq.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Volume removal

**Files:**
- Create: `plugin/scripts/volume-prune.sh`
- Test: `tests/test_volume_prune.sh`

**Interfaces:**
- Consumes: `lib.sh`, and `volume-list.sh` conventions (same `dangling` filter, same docker root logic).
- Produces: `plugin/scripts/volume-prune.sh`, called as `volume-prune.sh NAME [NAME...]`. Removes only names that pass the character check AND still appear in a freshly taken dangling listing. Prints `REMOVED <name>`, `SKIPPED <name> (in use)`, `REJECTED <name> (invalid name)`, and a final `TOTAL <human size>` line. Exit 0 when everything requested was removed, 1 when Docker failed or nothing could be removed, 2 on a usage error.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_volume_prune.sh`:

```bash
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `SKIP_LINT=1 ./test test_removes_the_requested`
Expected: FAIL — `volume-prune.sh` does not exist.

- [ ] **Step 3: Write the script**

Create `plugin/scripts/volume-prune.sh`:

```bash
#!/usr/bin/env bash
# Removes an explicit list of volumes, after re-checking each one is still
# unreferenced. Never calls `docker volume prune`, whose meaning changed in
# Docker 23 and therefore differs between Unraid 6.12 and 7.x.
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VALID_NAME='^[A-Za-z0-9][A-Za-z0-9_.-]*$'

docker_root() {
  local root
  root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
  [[ -n "$root" ]] || root="/var/lib/docker"
  printf '%s' "$root"
}

volume_bytes() { # docker-root name
  local path="$1/volumes/$2"
  [[ -d "$path" ]] || { printf '0'; return 0; }
  local bytes
  bytes="$(du -sb "$path" 2>/dev/null | awk '{print $1}')"
  [[ "$bytes" =~ ^[0-9]+$ ]] && printf '%s' "$bytes" || printf '0'
}

main() {
  load_cfg

  if (( $# == 0 )); then
    echo "Usage: volume-prune.sh NAME [NAME...]" >&2
    return 2
  fi

  if ! docker_available; then
    echo "Docker is not running." >&2
    return 1
  fi

  # Re-taken at confirm time, not reused from the preview. A container that
  # started while the dialog was open must not lose its volume.
  local unused
  unused="$(docker volume ls -q --filter dangling=true 2>/dev/null)"

  local root name total=0
  local -a keep=()
  root="$(docker_root)"

  for name in "$@"; do
    if [[ ! "$name" =~ $VALID_NAME ]]; then
      echo "REJECTED $name (invalid name)"
      continue
    fi
    if ! printf '%s\n' "$unused" | grep -qxF -- "$name"; then
      echo "SKIPPED $name (in use)"
      continue
    fi
    keep+=("$name")
    total=$(( total + $(volume_bytes "$root" "$name") ))
  done

  if (( ${#keep[@]} == 0 )); then
    echo "TOTAL 0B"
    echo "Nothing was removed."
    log_line "volume prune: nothing removed"
    return 1
  fi

  local output status
  output="$(docker volume rm -- "${keep[@]}" 2>&1)"
  status=$?
  printf '%s\n' "$output" | log_block

  if (( status != 0 )); then
    printf '%s\n' "$output"
    echo "TOTAL 0B"
    log_line "volume prune failed with exit $status"
    return 1
  fi

  for name in "${keep[@]}"; do
    echo "REMOVED $name"
  done
  echo "TOTAL $(human_bytes "$total")"
  log_line "volume prune removed ${#keep[@]} volume(s), $(human_bytes "$total"): ${keep[*]}"
  return 0
}

main "$@"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/volume-prune.sh tests/test_volume_prune.sh
git commit -m "feat: remove an explicit list of unused volumes

Re-checks the dangling list at confirm time so a container started
mid-dialog cannot lose its volume.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: PHP layer

**Files:**
- Create: `plugin/include/config.php`
- Create: `plugin/include/save.php`
- Create: `plugin/include/run.php`
- Create: `plugin/include/volumes.php`
- Create: `tests/php/test_config.php`
- Create: `tests/test_php_handlers.sh`
- Modify: `test` (add the PHP unit-test invocation)

**Interfaces:**
- Consumes: the scripts from Tasks 3–6, by absolute path under `$pluginRoot/scripts/`.
- Produces:
  - `config.php` — globals `$plugin`, `$pluginRoot`, `$bootConfig`, `$cfgFile`, `$lastrunFile`; functions `dc_defaults(): array`, `dc_read_cfg(): array`, `dc_write_cfg(array $cfg, string $path): bool`, `dc_csrf_ok(): bool`, `dc_require_csrf(): void`, `dc_lastrun(): ?array` returning `['time'=>string,'status'=>string,'message'=>string]`, `dc_human_bytes(int $b): string`.
  - `save.php` — POST, `text/plain`, 400 on invalid config with the reason, 200 with `Settings saved.`
  - `run.php` — POST, streams `text/plain`, targeted by an iframe.
  - `volumes.php` — POST with `action=list` or `action=remove`, returns JSON. `list` → `{"volumes":[{"name":…,"bytes":…,"anonymous":bool}]}` or `{"error":…}`. `remove` → `{"exit":int,"output":[…]}` or `{"error":…}`.

- [ ] **Step 1: Write the failing PHP test**

Create `tests/php/test_config.php`:

```php
<?php
// Plain-assert PHP tests. Run under php:8-cli in Docker; no framework.
declare(strict_types=1);

$failures = 0;
function check(string $label, bool $ok): void {
    global $failures;
    if ($ok) {
        echo "  ok   $label\n";
    } else {
        echo "  FAIL $label\n";
        $failures++;
    }
}

$tmp = sys_get_temp_dir() . '/dc-php-' . getmypid();
@mkdir($tmp, 0777, true);

require_once __DIR__ . '/../../plugin/include/config.php';

// Point the globals at the temp directory.
$cfgFile     = "$tmp/docker.cleanup.cfg";
$lastrunFile = "$tmp/lastrun";

check('defaults contain every key', count(dc_defaults()) === 8);
check('default schedule is daily', dc_defaults()['SCHEDULE'] === 'daily');

$written = dc_write_cfg(
    ['ENABLED' => 'yes', 'SCHEDULE' => 'weekly', 'HOUR' => '5', 'MINUTE' => '30',
     'DAY_OF_WEEK' => '2', 'DAY_OF_MONTH' => '1', 'CUSTOM_CRON' => '', 'NOTIFY' => 'no'],
    $cfgFile
);
check('write_cfg succeeds', $written === true);

$raw = (string)file_get_contents($cfgFile);
check('write_cfg quotes values', str_contains($raw, 'SCHEDULE="weekly"'));
check('write_cfg writes every key', substr_count($raw, "\n") === 8);

$roundTripped = dc_read_cfg();
check('read_cfg round-trips schedule', $roundTripped['SCHEDULE'] === 'weekly');
check('read_cfg round-trips notify', $roundTripped['NOTIFY'] === 'no');

// A value containing a quote must not be able to break out of the assignment.
dc_write_cfg(['ENABLED' => 'yes', 'SCHEDULE' => 'daily', 'HOUR' => '3', 'MINUTE' => '0',
              'DAY_OF_WEEK' => '0', 'DAY_OF_MONTH' => '1',
              'CUSTOM_CRON' => 'a"b$(id)', 'NOTIFY' => 'yes'], $cfgFile);
$raw = (string)file_get_contents($cfgFile);
check('quotes are stripped from values', !str_contains($raw, 'a"b'));
check('one line per key after sanitising', substr_count($raw, "\n") === 8);

check('lastrun is null when absent', dc_lastrun() === null);
file_put_contents($lastrunFile, "2026-08-11T03:00:04-05:00|ok|Reclaimed 4.509GB\n");
$lr = dc_lastrun();
check('lastrun parses status', is_array($lr) && $lr['status'] === 'ok');
check('lastrun parses message', is_array($lr) && $lr['message'] === 'Reclaimed 4.509GB');
// A message containing a pipe must survive, because explode is limited to 3.
file_put_contents($lastrunFile, "2026-08-11T03:00:04-05:00|error|failed | badly\n");
$lr = dc_lastrun();
check('lastrun keeps pipes in the message', is_array($lr) && $lr['message'] === 'failed | badly');

check('human bytes formats MB', dc_human_bytes(2097152) === '2MB');
check('human bytes handles zero', dc_human_bytes(0) === '0B');
check('human bytes handles unknown', dc_human_bytes(-1) === 'unknown');

// CSRF must fail closed when no token is available.
$_POST = [];
check('csrf fails with no token', dc_csrf_ok() === false);
$_POST['csrf_token'] = 'wrong';
check('csrf fails with a wrong token', dc_csrf_ok() === false);

array_map('unlink', glob("$tmp/*") ?: []);
@rmdir($tmp);

echo $failures === 0 ? "\nPHP tests passed\n" : "\n$failures PHP test(s) failed\n";
exit($failures === 0 ? 0 : 1);
```

- [ ] **Step 2: Run it to verify it fails**

Run: `docker run --rm -v "$PWD:/mnt" -w /mnt php:8-cli php tests/php/test_config.php`
Expected: FAIL — `plugin/include/config.php` does not exist, fatal require error.

- [ ] **Step 3: Write `config.php`**

Create `plugin/include/config.php`:

```php
<?php
// Shared helpers for the Docker Cleanup settings page.
// All decision logic lives in scripts/; this layer marshals arguments.
declare(strict_types=1);

$plugin      = 'docker.cleanup';
$pluginRoot  = "/usr/local/emhttp/plugins/$plugin";
$bootConfig  = "/boot/config/plugins/$plugin";
$cfgFile     = "$bootConfig/$plugin.cfg";
$lastrunFile = "$bootConfig/lastrun";

function dc_defaults(): array {
    return [
        'ENABLED'      => 'no',
        'SCHEDULE'     => 'daily',
        'HOUR'         => '3',
        'MINUTE'       => '0',
        'DAY_OF_WEEK'  => '0',
        'DAY_OF_MONTH' => '1',
        'CUSTOM_CRON'  => '',
        'NOTIFY'       => 'yes',
    ];
}

function dc_read_cfg(): array {
    global $cfgFile;
    $cfg = dc_defaults();
    if (is_file($cfgFile)) {
        $parsed = @parse_ini_file($cfgFile) ?: [];
        foreach (array_keys($cfg) as $key) {
            if (isset($parsed[$key])) {
                $cfg[$key] = (string)$parsed[$key];
            }
        }
    }
    return $cfg;
}

function dc_write_cfg(array $cfg, string $path): bool {
    $out = '';
    foreach (array_keys(dc_defaults()) as $key) {
        // Strip quotes and newlines so a value can never break the file format.
        $value = str_replace(['"', "\r", "\n"], '', (string)($cfg[$key] ?? ''));
        $out .= sprintf("%s=\"%s\"\n", $key, $value);
    }
    return file_put_contents($path, $out) !== false;
}

function dc_csrf_ok(): bool {
    global $var;
    if (!isset($var['csrf_token']) && is_file('/var/local/emhttp/var.ini')) {
        $var = @parse_ini_file('/var/local/emhttp/var.ini') ?: [];
    }
    if (empty($var['csrf_token'])) {
        return false;   // fail closed
    }
    $token = (string)($_POST['csrf_token'] ?? $_GET['csrf_token'] ?? '');
    return hash_equals((string)$var['csrf_token'], $token);
}

function dc_require_csrf(): void {
    if (!dc_csrf_ok()) {
        http_response_code(403);
        header('Content-Type: text/plain');
        exit("Forbidden: missing or invalid CSRF token\n");
    }
}

function dc_lastrun(): ?array {
    global $lastrunFile;
    if (!is_file($lastrunFile)) {
        return null;
    }
    $parts = explode('|', trim((string)file_get_contents($lastrunFile)), 3);
    if (count($parts) < 3) {
        return null;
    }
    return ['time' => $parts[0], 'status' => $parts[1], 'message' => $parts[2]];
}

function dc_human_bytes(int $b): string {
    if ($b < 0) {
        return 'unknown';
    }
    $units = ['B', 'KB', 'MB', 'GB', 'TB'];
    $i = 0;
    while ($b >= 1024 && $i < 4) {
        $b = intdiv($b, 1024);
        $i++;
    }
    return $b . $units[$i];
}
```

- [ ] **Step 4: Run the PHP test to verify it passes**

Run: `docker run --rm -v "$PWD:/mnt" -w /mnt php:8-cli php tests/php/test_config.php`
Expected: PASS — `PHP tests passed`.

- [ ] **Step 5: Write `save.php`**

Create `plugin/include/save.php`:

```php
<?php
// Saves settings, then applies the schedule. The candidate config is validated
// by cron-apply.sh before it replaces the live one, so a rejected value never
// lands on flash and never reaches the crontab.
declare(strict_types=1);
require_once __DIR__ . '/config.php';
dc_require_csrf();

header('Content-Type: text/plain; charset=utf-8');

$cfg = dc_read_cfg();
foreach (array_keys(dc_defaults()) as $key) {
    if (isset($_POST[$key])) {
        $cfg[$key] = (string)$_POST[$key];
    }
}

$tmp = "$cfgFile.tmp";
if (!dc_write_cfg($cfg, $tmp)) {
    http_response_code(500);
    exit("Could not write the configuration file.\n");
}

$script = escapeshellarg("$pluginRoot/scripts/cron-apply.sh");
$out = [];
$rc = 0;
exec("$script --validate-only --cfg " . escapeshellarg($tmp) . " 2>&1", $out, $rc);
if ($rc !== 0) {
    @unlink($tmp);
    http_response_code(400);
    exit(implode("\n", $out) . "\n");
}

if (!rename($tmp, $cfgFile)) {
    @unlink($tmp);
    http_response_code(500);
    exit("Could not save the configuration file.\n");
}

$out = [];
exec("$script 2>&1", $out, $rc);
if ($rc !== 0) {
    http_response_code(500);
    exit("Settings saved, but the schedule could not be applied:\n" . implode("\n", $out) . "\n");
}

echo "Settings saved.\n";
```

- [ ] **Step 6: Write `run.php`**

Create `plugin/include/run.php`:

```php
<?php
// Streams a manual image prune. The page targets an iframe at this endpoint,
// so the browser renders the text/plain response as it arrives — no JS needed
// and nothing is interpreted as markup.
declare(strict_types=1);
require_once __DIR__ . '/config.php';
dc_require_csrf();

header('Content-Type: text/plain; charset=utf-8');
header('X-Accel-Buffering: no');
header('Cache-Control: no-store');

while (ob_get_level() > 0) {
    ob_end_flush();
}
ob_implicit_flush(true);

$handle = popen(escapeshellarg("$pluginRoot/scripts/image-prune.sh") . ' 2>&1', 'r');
if ($handle === false) {
    http_response_code(500);
    exit("Could not start the prune script.\n");
}

while (($line = fgets($handle)) !== false) {
    echo $line;
    flush();
}

$rc = pclose($handle);
echo $rc === 0 ? "\nDone.\n" : "\nFailed with exit code $rc.\n";
```

- [ ] **Step 7: Write `volumes.php`**

Create `plugin/include/volumes.php`:

```php
<?php
// Lists unused volumes, and removes an explicitly named set.
// Volume names are validated here AND re-validated in volume-prune.sh.
declare(strict_types=1);
require_once __DIR__ . '/config.php';
dc_require_csrf();

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

$action = (string)($_POST['action'] ?? '');

if ($action === 'list') {
    $out = [];
    $rc = 0;
    exec(escapeshellarg("$pluginRoot/scripts/volume-list.sh") . ' 2>&1', $out, $rc);
    if ($rc !== 0) {
        echo json_encode(['error' => trim(implode(' ', $out))]);
        exit;
    }
    $volumes = [];
    foreach ($out as $line) {
        $parts = explode("\t", $line);
        if (count($parts) < 3) {
            continue;
        }
        $volumes[] = [
            'name'      => $parts[0],
            'bytes'     => (int)$parts[1],
            'size'      => dc_human_bytes((int)$parts[1]),
            'anonymous' => $parts[2] === 'yes',
        ];
    }
    echo json_encode(['volumes' => $volumes]);
    exit;
}

if ($action === 'remove') {
    $names = $_POST['names'] ?? [];
    if (!is_array($names) || count($names) === 0) {
        echo json_encode(['error' => 'No volumes were selected.']);
        exit;
    }
    $args = '';
    foreach ($names as $name) {
        if (!is_string($name) || !preg_match('/^[A-Za-z0-9][A-Za-z0-9_.-]*$/', $name)) {
            echo json_encode(['error' => 'Refused: invalid volume name.']);
            exit;
        }
        $args .= ' ' . escapeshellarg($name);
    }
    $out = [];
    $rc = 0;
    exec(escapeshellarg("$pluginRoot/scripts/volume-prune.sh") . $args . ' 2>&1', $out, $rc);
    echo json_encode(['exit' => $rc, 'output' => $out]);
    exit;
}

http_response_code(400);
echo json_encode(['error' => 'Unknown action.']);
```

- [ ] **Step 8: Guard the CSRF check with a static test**

The PHP unit test proves `dc_csrf_ok()` fails closed, but nothing yet proves
each handler actually calls it. This catches the regression that matters: a new
handler added later without the guard.

Create `tests/test_php_handlers.sh`:

```bash
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
```

Run: `SKIP_LINT=1 ./test test_every_handler`
Expected: PASS against the handlers written in Steps 5–7.

- [ ] **Step 9: Wire the PHP tests into `test`**

In `test`, immediately before the `echo "== unit tests =="` line, insert:

```bash
  echo "== php tests =="
  docker run --rm -v "$REPO_ROOT:/mnt" -w /mnt php:8-cli \
    php tests/php/test_config.php || status=1
```

Note this sits inside the `if command -v docker` branch, since it needs Docker.

- [ ] **Step 10: Run everything**

Run: `./test`
Expected: PASS — shellcheck clean, `php -l` clean on all four PHP files, PHP tests pass, all bash tests pass.

- [ ] **Step 11: Commit**

```bash
git add plugin/include tests/php tests/test_php_handlers.sh test
git commit -m "feat: add the PHP handler layer

Thin by design: CSRF check, argument marshalling, formatting. All
decision logic stays in the tested shell scripts.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Settings page

**Files:**
- Create: `plugin/DockerCleanup.page`
- Test: manual, plus `php -l` via `./test`

**Interfaces:**
- Consumes: `include/config.php` (`dc_read_cfg`, `dc_lastrun`), and posts to `include/save.php`, `include/run.php`, `include/volumes.php`.
- Produces: the page at Settings ▸ User Utilities ▸ Docker Cleanup.

- [ ] **Step 1: Write the page**

Create `plugin/DockerCleanup.page`:

```php
Menu="Utilities"
Type="xmenu"
Title="Docker Cleanup"
Icon="fa-recycle"
---
<?php
require_once "/usr/local/emhttp/plugins/docker.cleanup/include/config.php";
$cfg  = dc_read_cfg();
$last = dc_lastrun();
$csrf = $var['csrf_token'] ?? '';
?>
<style>
  .dc-hidden { display: none; }
  #dc_output { width: 100%; height: 14em; border: 1px solid #ccc; background: #fff; }
  .dc-vol-list { max-height: 18em; overflow-y: auto; text-align: left; }
  .dc-vol-list label { display: block; padding: 2px 0; }
  .dc-vol-list label.dc-disabled { opacity: 0.5; }
</style>

<form id="dc_settings" markdown="1">
<input type="hidden" name="csrf_token" value="<?= htmlspecialchars($csrf) ?>">

Enable scheduled cleanup:
: <select name="ENABLED" id="dc_enabled">
    <option value="yes" <?= $cfg['ENABLED'] === 'yes' ? 'selected' : '' ?>>Yes</option>
    <option value="no"  <?= $cfg['ENABLED'] !== 'yes' ? 'selected' : '' ?>>No</option>
  </select>

> Runs `docker image prune -a -f`, which removes every image no container
> references. Containers and volumes are never touched.

Schedule:
: <select name="SCHEDULE" id="dc_schedule">
  <?php foreach (['hourly' => 'Hourly', 'daily' => 'Daily', 'weekly' => 'Weekly',
                  'monthly' => 'Monthly', 'custom' => 'Custom cron'] as $k => $label): ?>
    <option value="<?= $k ?>" <?= $cfg['SCHEDULE'] === $k ? 'selected' : '' ?>><?= $label ?></option>
  <?php endforeach ?>
  </select>

<span class="dc-row" id="dc_row_minute">Minute:
: <select name="MINUTE">
  <?php for ($m = 0; $m < 60; $m += 5): ?>
    <option value="<?= $m ?>" <?= (int)$cfg['MINUTE'] === $m ? 'selected' : '' ?>><?= sprintf('%02d', $m) ?></option>
  <?php endfor ?>
  </select>
</span>

<span class="dc-row" id="dc_row_hour">Hour:
: <select name="HOUR">
  <?php for ($h = 0; $h < 24; $h++): ?>
    <option value="<?= $h ?>" <?= (int)$cfg['HOUR'] === $h ? 'selected' : '' ?>><?= sprintf('%02d', $h) ?></option>
  <?php endfor ?>
  </select>
</span>

<span class="dc-row" id="dc_row_dow">Day of week:
: <select name="DAY_OF_WEEK">
  <?php foreach (['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'] as $i => $d): ?>
    <option value="<?= $i ?>" <?= (int)$cfg['DAY_OF_WEEK'] === $i ? 'selected' : '' ?>><?= $d ?></option>
  <?php endforeach ?>
  </select>
</span>

<span class="dc-row" id="dc_row_dom">Day of month:
: <select name="DAY_OF_MONTH">
  <?php for ($d = 1; $d <= 28; $d++): ?>
    <option value="<?= $d ?>" <?= (int)$cfg['DAY_OF_MONTH'] === $d ? 'selected' : '' ?>><?= $d ?></option>
  <?php endfor ?>
  </select>
</span>

<span class="dc-row" id="dc_row_custom">Custom cron expression:
: <input type="text" name="CUSTOM_CRON" size="24"
         value="<?= htmlspecialchars($cfg['CUSTOM_CRON']) ?>" placeholder="0 3 * * *">
</span>

> Five fields: minute, hour, day of month, month, day of week.
> Day of month is limited to 1–28 in the preset schedules so a monthly run
> never skips February.

Send a notification when it runs:
: <select name="NOTIFY">
    <option value="yes" <?= $cfg['NOTIFY'] === 'yes' ? 'selected' : '' ?>>Yes</option>
    <option value="no"  <?= $cfg['NOTIFY'] !== 'yes' ? 'selected' : '' ?>>No</option>
  </select>

Last run:
: <span id="dc_lastrun"><?= $last
    ? htmlspecialchars("{$last['time']} — {$last['status']} — {$last['message']}")
    : 'never' ?></span>

&nbsp;
: <button type="button" id="dc_save">Apply</button>
  <button type="button" id="dc_run">Run image prune now</button>
  <span id="dc_status"></span>
</form>

<form id="dc_runform" method="POST"
      action="/plugins/docker.cleanup/include/run.php" target="dc_output_frame">
  <input type="hidden" name="csrf_token" value="<?= htmlspecialchars($csrf) ?>">
</form>
<iframe id="dc_output" name="dc_output_frame" class="dc-hidden" title="Prune output"></iframe>

<hr>

### Unused volumes

> Deleting a volume destroys the data inside it. This never runs on a schedule
> and never runs without your confirmation.

&nbsp;
: <button type="button" id="dc_volumes">Prune unused volumes</button>

<script>
const DC_CSRF = <?= json_encode((string)$csrf) ?>;

function dcShowScheduleRows() {
  const schedule = document.getElementById('dc_schedule').value;
  const shown = {
    hourly:  ['dc_row_minute'],
    daily:   ['dc_row_minute', 'dc_row_hour'],
    weekly:  ['dc_row_minute', 'dc_row_hour', 'dc_row_dow'],
    monthly: ['dc_row_minute', 'dc_row_hour', 'dc_row_dom'],
    custom:  ['dc_row_custom'],
  }[schedule] || [];
  for (const id of ['dc_row_minute','dc_row_hour','dc_row_dow','dc_row_dom','dc_row_custom']) {
    document.getElementById(id).classList.toggle('dc-hidden', !shown.includes(id));
  }
}

document.getElementById('dc_schedule').addEventListener('change', dcShowScheduleRows);
dcShowScheduleRows();

document.getElementById('dc_save').addEventListener('click', async () => {
  const status = document.getElementById('dc_status');
  status.textContent = 'Saving…';
  const body = new FormData(document.getElementById('dc_settings'));
  const res = await fetch('/plugins/docker.cleanup/include/save.php', { method: 'POST', body });
  const text = await res.text();
  status.textContent = text.trim();
});

document.getElementById('dc_run').addEventListener('click', () => {
  document.getElementById('dc_output').classList.remove('dc-hidden');
  document.getElementById('dc_runform').submit();
});

function dcEscapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

function dcVolumeRow(v) {
  const disabled = v.anonymous ? '' : ' disabled';
  const cls = v.anonymous ? '' : ' class="dc-disabled"';
  const name = dcEscapeHtml(v.name);
  return `<label${cls}>
    <input type="checkbox" class="dc-vol" value="${name}"
           data-anonymous="${v.anonymous ? 1 : 0}"${disabled}${v.anonymous ? ' checked' : ''}>
    ${name} — ${v.size}${v.anonymous ? '' : ' (named)'}
  </label>`;
}

document.getElementById('dc_volumes').addEventListener('click', async () => {
  const body = new FormData();
  body.append('csrf_token', DC_CSRF);
  body.append('action', 'list');

  let data;
  try {
    const res = await fetch('/plugins/docker.cleanup/include/volumes.php', { method: 'POST', body });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    data = await res.json();
  } catch (e) {
    swal({ title: 'Could not list volumes', text: String(e && e.message ? e.message : e), type: 'error' });
    return;
  }

  if (data.error) { swal({ title: 'Could not list volumes', text: data.error, type: 'error' }); return; }
  if (!data.volumes.length) { swal({ title: 'Nothing to remove', text: 'No unused volumes were found.', type: 'info' }); return; }

  const html = `
    <div class="dc-vol-list">${data.volumes.map(dcVolumeRow).join('')}</div>
    <p><label><input type="checkbox" id="dc_include_named"> Include named volumes</label></p>
    <p><small>Anonymous is a heuristic: a 64-character lowercase hex name, which is what Docker generates — a user-named volume matching that pattern would show as anonymous too.</small></p>
    <p><b>Deleting a volume permanently destroys the data inside it.</b></p>`;

  swal({
    title: 'These volumes will be permanently deleted',
    html: true, text: html,
    showCancelButton: true, confirmButtonText: 'Delete them',
    confirmButtonColor: '#c0392b', closeOnConfirm: false,
  }, async (isConfirm) => {
    // SweetAlert 1.x invokes this callback on cancel too — true on confirm,
    // false on cancel/escape/overlay-click. Without this guard, cancelling
    // the dialog deletes the pre-checked anonymous volumes anyway. The check
    // is `if (!isConfirm) return;` rather than `if (isConfirm === false)
    // return;` so it also fails safe if this ever runs under SweetAlert 2,
    // where the callback form isn't supported and the argument comes through
    // as `undefined` — a strict `=== false` check would let that fall through
    // into a deletion.
    if (!isConfirm) return;

    // :not(:disabled) matters: a disabled checkbox can still carry `checked`
    // in the DOM (the named-volume toggle relies on exactly that to remember
    // state while greyed out), so selecting on :checked alone would submit
    // names the user never had a live, enabled control over.
    const selected = [...document.querySelectorAll('.dc-vol:checked:not(:disabled)')].map(el => el.value);
    if (!selected.length) { swal({ title: 'Nothing selected', type: 'info' }); return; }

    const confirmBtn = document.querySelector('.sweet-alert button.confirm');
    if (confirmBtn) confirmBtn.disabled = true;

    const rm = new FormData();
    rm.append('csrf_token', DC_CSRF);
    rm.append('action', 'remove');
    for (const name of selected) rm.append('names[]', name);

    let out;
    try {
      const r = await fetch('/plugins/docker.cleanup/include/volumes.php', { method: 'POST', body: rm });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      out = await r.json();
    } catch (e) {
      if (confirmBtn) confirmBtn.disabled = false;
      swal({ title: 'Removal request failed', text: String(e && e.message ? e.message : e), type: 'error' });
      return;
    }

    // volume-prune.sh can partially succeed: some names removed, others
    // SKIPPED (gained a reference) or REJECTED (failed re-validation) while
    // the overall exit code is still 0. Surface that as a distinct "warnings"
    // state rather than reporting a clean success.
    const outputLines = out.output || [];
    const hasIssues = outputLines.some((line) => /^(SKIPPED|REJECTED)\b/.test(line));
    const title = out.exit !== 0 ? 'Finished with errors'
                : hasIssues ? 'Finished with warnings'
                : 'Volumes removed';
    swal({
      title,
      text: (outputLines.length ? outputLines : [out.error]).join('\n'),
      type: out.exit === 0 && !hasIssues ? 'success' : 'warning',
    });
  });

  // Wire the named-volume toggle once swal has rendered the dialog.
  setTimeout(() => {
    const toggle = document.getElementById('dc_include_named');
    if (!toggle) return;
    toggle.addEventListener('change', () => {
      for (const el of document.querySelectorAll('.dc-vol')) {
        if (el.dataset.anonymous === '1') continue;
        // Ticking the box makes named volumes selectable, not selected — it
        // must never check a box the user hasn't looked at. (This is the
        // fix for the shipped Critical: the box previously also set
        // `checked`, which could delete every named volume on the server if
        // the user ticked it and confirmed without scrolling the list.)
        // Unticking clears any selection made while enabled, so a value that
        // scrolled out of view can't survive back into a disabled state.
        el.disabled = !toggle.checked;
        if (!toggle.checked) el.checked = false;
        el.closest('label').classList.toggle('dc-disabled', !toggle.checked);
      }
    });
  }, 0);
});
</script>
```

The page uses `Icon="fa-recycle"`, a Font Awesome icon the Unraid webGui already
ships. No image file has to be packaged, and the menu entry can never render as
a broken image. The PNG for the Community Applications listing is a separate
asset, created in Task 10 — CA needs a URL, the page does not.

- [ ] **Step 2: Verify the page parses**

Run: `docker run --rm -v "$PWD:/mnt" -w /mnt php:8-cli sh -c "sed -n '/^---$/,\$p' plugin/DockerCleanup.page | tail -n +2 > /tmp/page.php && php -l /tmp/page.php"`
Expected: `No syntax errors detected`. The four header lines above `---` are Unraid page metadata, not PHP, so they are stripped before linting.

- [ ] **Step 3: Run the full suite**

Run: `./test`
Expected: PASS, unchanged from Task 7.

- [ ] **Step 4: Commit**

```bash
git add plugin/DockerCleanup.page
git commit -m "feat: add the settings page

Schedule fields show and hide by preset; volume removal previews the
exact list, with named volumes excluded until explicitly included.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Packaging and installer

**Files:**
- Create: `build/build.sh`
- Create: `docker.cleanup.plg`
- Test: `tests/test_build.sh`

**Interfaces:**
- Consumes: everything under `plugin/`.
- Produces: `build/build.sh [VERSION]` writing `release/docker.cleanup-VERSION.txz` and `.md5`, and stamping version and md5 into `docker.cleanup.plg`. Default version is `$(date +%Y.%m.%d)`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_build.sh`:

```bash
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `SKIP_LINT=1 ./test test_build_produces`
Expected: FAIL — `build/build.sh` does not exist.

- [ ] **Step 3: Write the installer**

Create `docker.cleanup.plg`:

```xml
<?xml version='1.0' standalone='yes'?>
<!DOCTYPE PLUGIN [
<!ENTITY name      "docker.cleanup">
<!ENTITY author    "Yoshiofthewire">
<!ENTITY version   "2026.08.11">
<!ENTITY md5       "PLACEHOLDER">
<!ENTITY launch    "Settings/DockerCleanup">
<!ENTITY repo      "https://github.com/Yoshiofthewire/Unraid_Docker_Cleanup">
<!ENTITY gitURL    "&repo;/releases/download/&version;">
<!ENTITY pluginURL "https://raw.githubusercontent.com/Yoshiofthewire/Unraid_Docker_Cleanup/main/&name;.plg">
<!ENTITY pkgName   "&name;-&version;.txz">
<!ENTITY plgPATH   "/boot/config/plugins/&name;">
<!ENTITY emhttp    "/usr/local/emhttp/plugins/&name;">
]>

<PLUGIN name="&name;" author="&author;" version="&version;" launch="&launch;"
        pluginURL="&pluginURL;" support="&repo;/issues" min="6.12.0">

<CHANGES>
###&version;
- Initial release: scheduled `docker image prune -a -f`, plus a manual,
  confirmation-gated removal of unused volumes.
</CHANGES>

<FILE Name="&plgPATH;/&pkgName;">
<URL>&gitURL;/&pkgName;</URL>
<MD5>&md5;</MD5>
</FILE>

<FILE Run="/bin/bash">
<INLINE>
# Remove any older package so only one version is ever on flash.
for pkg in &plgPATH;/&name;-*.txz; do
  [ "$pkg" = "&plgPATH;/&pkgName;" ] && continue
  [ -f "$pkg" ] &amp;&amp; rm -f "$pkg"
done

upgradepkg --install-new --reinstall &plgPATH;/&pkgName;

# Seed the config on first install only; an upgrade keeps the user's settings.
mkdir -p &plgPATH;
if [ ! -f &plgPATH;/&name;.cfg ]; then
  cp &emhttp;/default.cfg &plgPATH;/&name;.cfg
fi

# Apply whatever the config says. Never touches volumes.
&emhttp;/scripts/cron-apply.sh || echo "Warning: the schedule could not be applied."

echo ""
echo "----------------------------------------------------"
echo " Docker Cleanup &version; installed"
echo " Settings -> User Utilities -> Docker Cleanup"
echo "----------------------------------------------------"
echo ""
</INLINE>
</FILE>

<FILE Run="/bin/bash" Method="remove">
<INLINE>
# Stop the scheduled job first, before the script that does it disappears.
if [ -x &emhttp;/scripts/cron-apply.sh ]; then
  &emhttp;/scripts/cron-apply.sh --disable
else
  rm -f &plgPATH;/&name;.cron
  [ -x /usr/local/emhttp/webGui/scripts/update_cron ] &amp;&amp; /usr/local/emhttp/webGui/scripts/update_cron
fi

removepkg &name; 2>/dev/null
rm -rf &emhttp;
rm -f /var/log/docker-cleanup.log
rm -f &plgPATH;/&name;-*.txz
rm -f &plgPATH;/&name;.plg

# The user's settings stay on flash so a reinstall restores the schedule.
echo ""
echo "Docker Cleanup removed. Your settings were kept at &plgPATH;/&name;.cfg"
echo ""
</INLINE>
</FILE>

</PLUGIN>
```

- [ ] **Step 4: Write the build script**

Create `build/build.sh`:

```bash
#!/usr/bin/env bash
# Builds the Slackware package and stamps its version and checksum into the
# .plg. Run from anywhere: build/build.sh [VERSION]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="docker.cleanup"
VERSION="${1:-$(date +%Y.%m.%d)}"
DEST="$ROOT/release"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

TARGET="$STAGE/usr/local/emhttp/plugins/$NAME"
mkdir -p "$TARGET" "$DEST"
cp -a "$ROOT/plugin/." "$TARGET/"

# Scripts must be executable inside the package; everything else stays 644.
find "$TARGET" -type f -exec chmod 644 {} +
find "$TARGET/scripts" -type f -name '*.sh' -exec chmod 755 {} +

TXZ="$DEST/$NAME-$VERSION.txz"
tar -C "$STAGE" --owner=0 --group=0 --numeric-owner -cJf "$TXZ" usr

MD5="$(md5sum "$TXZ" | awk '{print $1}')"
printf '%s\n' "$MD5" > "$TXZ.md5"

PLG="$ROOT/$NAME.plg"
sed -i -E \
  -e "s|(<!ENTITY version   \")[^\"]*(\">)|\1$VERSION\2|" \
  -e "s|(<!ENTITY md5       \")[^\"]*(\">)|\1$MD5\2|" \
  "$PLG"

echo "Built  $TXZ"
echo "MD5    $MD5"
echo "Stamped $PLG"
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./test`
Expected: PASS. Note the build tests stage a copy of the repo into `$TMP`, so the real `docker.cleanup.plg` keeps its `PLACEHOLDER` until you run a real build.

- [ ] **Step 6: Commit**

```bash
git add build docker.cleanup.plg tests/test_build.sh
git commit -m "build: add the .txz builder and .plg installer

Remove stops the cron job before deleting the script that stops it,
and keeps the user's config on flash.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 10: Documentation, CA template, and DOX closeout

**Files:**
- Create: `README.md`
- Create: `LICENSE`
- Create: `images/docker-cleanup.png`
- Create: `ca/docker.cleanup.xml`
- Create: `plugin/AGENTS.md`
- Create: `tests/AGENTS.md`
- Modify: `AGENTS.md` (Child DOX Index)

**Interfaces:**
- Consumes: the finished plugin.
- Produces: publishable repository.

- [ ] **Step 1: Write the README**

Create `README.md`:

````markdown
# Docker Cleanup

An Unraid plugin that reclaims disk space by pruning unused Docker images on a
schedule, and lets you remove leftover Docker volumes by hand.

## What it does

- Runs `docker image prune -a -f` on a schedule you choose. Default: daily at 03:00.
- Sends an Unraid notification with the space reclaimed.
- Offers a manual "prune unused volumes" button that shows you exactly what will
  be deleted before anything is removed.

Containers are never stopped or removed. Volumes are never deleted on a
schedule — only when you ask, and only after you confirm a specific list.

## Install

Plugins ▸ Install Plugin, and paste:

```
https://raw.githubusercontent.com/Yoshiofthewire/Unraid_Docker_Cleanup/main/docker.cleanup.plg
```

Settings appear at **Settings ▸ User Utilities ▸ Docker Cleanup**.

Requires Unraid 6.12 or newer.

## About `docker image prune -a`

The `-a` flag removes every image that no container references — running or
stopped. If you keep images around that no container uses, they will be deleted
and re-pulled next time you need them. That is the point of the plugin, but it
is worth knowing before you enable it.

## About volumes

`docker volume prune` changed meaning in Docker 23: it stopped removing named
volumes by default. Unraid 6.12 and 7.x ship different Docker versions, so that
command does different things on different servers. This plugin therefore does
not call it. It lists the volumes no container references, shows you the list
with sizes, and removes exactly the ones you confirm.

Named volumes are excluded until you tick "include named volumes". A volume
that gains a container reference while the dialog is open is skipped.

## Uninstall

Removing the plugin deletes the scheduled job immediately. Your settings stay at
`/boot/config/plugins/docker.cleanup/docker.cleanup.cfg`, so reinstalling
restores your schedule.

## Development

```bash
./test              # lint + unit tests
./test test_cron    # run a subset by name
SKIP_LINT=1 ./test  # skip the Docker-based linters
build/build.sh      # build release/docker.cleanup-YYYY.MM.DD.txz and stamp the .plg
```

Lint runs `shellcheck` and `php -l` inside Docker containers, so neither has to
be installed locally. The test suite is plain bash and drives the scripts with a
stub `docker` on `PATH`.

Design and implementation notes live in `docs/superpowers/`.
````

- [ ] **Step 2: Write the licence**

Create `LICENSE` with the MIT licence text, copyright `2026 Yoshiofthewire`.

- [ ] **Step 3: Create the Community Applications icon**

CA lists an icon by URL, so this PNG lives at the repository root and is never
packaged into the `.txz`. Generate a 128×128 placeholder:

```bash
mkdir -p images
docker run --rm -v "$PWD:/w" -w /w alpine:3 sh -c \
  'apk add --no-cache imagemagick >/dev/null 2>&1;
   { magick 2>/dev/null || command -v convert >/dev/null; } ;
   IM=$(command -v magick || command -v convert);
   "$IM" -size 128x128 xc:"#1d63ed" -fill white -gravity center \
     -pointsize 56 -annotate 0 "DC" images/docker-cleanup.png'
```

Verify it is a real PNG before committing:

```bash
file images/docker-cleanup.png
```

Expected: `PNG image data, 128 x 128`. Replace it with real artwork whenever you
have some — nothing in the code references it except the CA template.

- [ ] **Step 4: Write the CA template**

Create `ca/docker.cleanup.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<PluginEntry>
  <Name>Docker Cleanup</Name>
  <Author>Yoshiofthewire</Author>
  <Category>Tools:Utilities System:Utilities</Category>
  <PluginURL>https://raw.githubusercontent.com/Yoshiofthewire/Unraid_Docker_Cleanup/main/docker.cleanup.plg</PluginURL>
  <Support>https://github.com/Yoshiofthewire/Unraid_Docker_Cleanup/issues</Support>
  <Project>https://github.com/Yoshiofthewire/Unraid_Docker_Cleanup</Project>
  <Icon>https://raw.githubusercontent.com/Yoshiofthewire/Unraid_Docker_Cleanup/main/images/docker-cleanup.png</Icon>
  <TemplateURL>https://raw.githubusercontent.com/Yoshiofthewire/unraid_docker_apps/main/docker.cleanup.xml</TemplateURL>
  <Overview>
    Reclaims disk space by pruning unused Docker images on a schedule you
    choose, with an Unraid notification reporting the space reclaimed.
    Also offers a manual, confirmation-gated removal of leftover Docker
    volumes that shows exactly what will be deleted first. Volumes are never
    deleted on a schedule.
  </Overview>
  <MinVer>6.12.0</MinVer>
</PluginEntry>
```

Add a `## Publishing to Community Applications` section to `README.md`:

````markdown
## Publishing to Community Applications

CA requires a plugin to have a support thread on the Unraid forums before it
will be listed. The steps:

1. Tag a release and run `build/build.sh <version>`; upload the `.txz` and
   `.txz.md5` to the GitHub release matching that version.
2. Commit the stamped `docker.cleanup.plg` to `main`.
3. Verify the raw `.plg` URL installs cleanly on a real server.
4. Create the Unraid forum support thread and put its URL in the `<Support>`
   field of `ca/docker.cleanup.xml` and the `support` attribute of the `.plg`.
5. Copy `ca/docker.cleanup.xml` into the `unraid_docker_apps` repository
   alongside the other CA templates, matching its `TemplateURL`.

Confirm the current CA requirements before submitting; they change.
````

- [ ] **Step 5: Write the child DOX docs**

Create `plugin/AGENTS.md`:

```markdown
# Plugin Source

## Purpose

The tree installed to `/usr/local/emhttp/plugins/docker.cleanup/`. Everything
here ships to users.

## Ownership

Owns the settings page, the PHP handlers, and the shell scripts that do the work.

## Local Contracts

- `scripts/` holds all decision logic. `include/` stays thin: CSRF check,
  argument marshalling, output formatting. If a behaviour needs a test, it
  belongs in a script.
- Every script sources `scripts/lib.sh` and takes every path from a variable
  that an environment variable can override.
- Scripts use `set -uo pipefail`, never `set -e`; control flow is explicit.
- Never `source` the config file. `load_cfg` parses it.
- PHP files call `dc_require_csrf()` as the first statement after the require.
- Shell arguments from the web layer pass through `escapeshellarg`, and the
  receiving script re-validates them.
- `default.cfg` is the shipped default, copied to flash on first install only.

## Work Guidance

- Match the existing scripts: a `main` function at the bottom invoked as
  `main "$@"`, helpers above it, comments only where the reason is not obvious.

## Verification

`./test` from the repository root. Every script change needs a test in
`tests/`.
```

Create `tests/AGENTS.md`:

```markdown
# Tests

## Purpose

Plain-bash test suite driving the plugin scripts with a stub `docker`.

## Ownership

Owns the runner, the harness, the stubs, and every test file.

## Local Contracts

- A test file is `tests/test_*.sh` defining functions named `test_*`. The runner
  discovers both.
- Each test function runs in its own subshell with a fresh temp directory. Never
  write outside `$TMP`.
- Stub behaviour is controlled by `STUB_*` environment variables only. Do not
  edit a stub to make one test pass; add a variable.
- `tests/php/` holds PHP tests, run under `php:8-cli` in Docker.

## Work Guidance

- Assert on what the user gets: the command that ran, the file that changed, the
  exit status. Do not assert on internal function names.

## Verification

`./test`, or `./test <substring>` to run a subset.
```

- [ ] **Step 6: Update the root Child DOX Index**

In `AGENTS.md`, replace the `## Child DOX Index` body with:

```markdown
- `plugin/AGENTS.md` — the tree installed to the server: settings page, PHP
  handlers, shell scripts. Owns the script/PHP boundary rules.
- `tests/AGENTS.md` — the bash test suite and its stubs. Owns test conventions.
- `docs/` — design specs and implementation plans. No child AGENTS.md; the root
  contract applies.
- `build/`, `ca/`, `images/` — packaging, Community Applications metadata, and
  the CA listing icon. No child AGENTS.md; the root contract applies.
```

- [ ] **Step 7: Run the full suite one last time**

Run: `./test`
Expected: PASS — every bash test, the PHP tests, shellcheck, and `php -l` all clean.

- [ ] **Step 8: Commit**

```bash
git add README.md LICENSE images ca plugin/AGENTS.md tests/AGENTS.md AGENTS.md
git commit -m "docs: add README, licence, CA template, and DOX child docs

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Manual verification on a real Unraid server

The test suite cannot exercise the webGui, `update_cron`, or a real Docker
daemon. After installing the built `.plg` on a server:

1. Settings ▸ User Utilities ▸ Docker Cleanup opens without a PHP error.
2. Apply with Daily 03:00, then `cat /boot/config/plugins/docker.cleanup/docker.cleanup.cron`
   shows `0 3 * * *`, and `crontab -l | grep docker.cleanup` shows the same line.
3. Set the schedule to disabled, Apply, and confirm the fragment and the crontab
   line both disappear.
4. Enter `garbage` as a custom cron, Apply, and confirm the page reports an
   error and `crontab -l` is unchanged.
5. Run image prune now — output streams into the page, a notification arrives,
   and Last run updates.
6. Prune unused volumes — the dialog lists volumes with sizes, named volumes are
   greyed out, cancelling deletes nothing, confirming deletes exactly the listed
   set.
7. Reboot, and confirm the schedule is still in `crontab -l`.
8. Uninstall, and confirm the crontab line is gone, `/usr/local/emhttp/plugins/docker.cleanup`
   is gone, and `docker.cleanup.cfg` still exists on flash.
