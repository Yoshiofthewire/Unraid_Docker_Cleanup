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
