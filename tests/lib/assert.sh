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
