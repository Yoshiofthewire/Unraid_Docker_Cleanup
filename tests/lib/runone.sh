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
