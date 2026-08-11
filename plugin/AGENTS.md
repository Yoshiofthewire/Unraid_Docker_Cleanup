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
