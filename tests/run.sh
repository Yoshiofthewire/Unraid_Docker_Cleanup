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
