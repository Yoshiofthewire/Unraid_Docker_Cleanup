
# Unraid Docker Cleanup

An Unraid plugin (slug `docker.cleanup`) that runs `docker image prune -a -f` on
a user-controlled schedule, and offers a manual, confirmation-gated removal of
unused Docker volumes. Targets Unraid 6.12 and 7.x.

- Design spec: `docs/superpowers/specs/2026-08-11-docker-cleanup-plugin-design.md`
- Published by `Yoshiofthewire`; CA template lives in this repo

## Binding Project Rules

- Volume deletion is never scheduled, never runs on install, and never runs
  without explicit user confirmation of a previewed list
- Scheduling goes through the dynamix convention only: write
  `/boot/config/plugins/docker.cleanup/docker.cleanup.cron`, then call
  `/usr/local/emhttp/webGui/scripts/update_cron`. Never edit the crontab directly
- Uninstall removes the cron fragment and plugin files but keeps the user's
  `.cfg` on flash
- Every webGui POST handler verifies the Unraid CSRF token
- Keep flash writes minimal; verbose output goes to `/var/log/docker-cleanup.log`
- Shell scripts take path overrides from environment variables so tests never
  touch real system paths

# DOX framework

- DOX is highly performant AGENTS.md hierarchy installed here
- Agent must follow DOX instructions across any edits

## Core Contract

- AGENTS.md files are binding work contracts for their subtrees
- Work products, source materials, instructions, records, assets, and durable docs must stay understandable from the nearest applicable AGENTS.md plus every parent AGENTS.md above it

## Read Before Editing

1. Read the root AGENTS.md
2. Identify every file or folder you expect to touch
3. Walk from the repository root to each target path
4. Read every AGENTS.md found along each route
5. If a parent AGENTS.md lists a child AGENTS.md whose scope contains the path, read that child and continue from there
6. Use the nearest AGENTS.md as the local contract and parent docs for repo-wide rules
7. If docs conflict, the closer doc controls local work details, but no child doc may weaken DOX

Do not rely on memory. Re-read the applicable DOX chain in the current session before editing.

## Update After Editing

Every meaningful change requires a DOX pass before the task is done.

Update the closest owning AGENTS.md when a change affects:

- purpose, scope, ownership, or responsibilities
- durable structure, contracts, workflows, or operating rules
- required inputs, outputs, permissions, constraints, side effects, or artifacts
- user preferences about behavior, communication, process, organization, or quality
- AGENTS.md creation, deletion, move, rename, or index contents

Update parent docs when parent-level structure, ownership, workflow, or child index changes. Update child docs when parent changes alter local rules. Remove stale or contradictory text immediately. Small edits that do not change behavior or contracts may leave docs unchanged, but the DOX pass still must happen.

## Hierarchy

- Root AGENTS.md is the DOX rail: project-wide instructions, global preferences, durable workflow rules, and the top-level Child DOX Index
- Child AGENTS.md files own domain-specific instructions and their own Child DOX Index
- Each parent explains what its direct children cover and what stays owned by the parent
- The closer a doc is to the work, the more specific and practical it must be

## Child Doc Shape

- Create a child AGENTS.md when a folder becomes a durable boundary with its own purpose, rules, responsibilities, workflow, materials, or quality standards
- Work Guidance must reflect the current standards of the project or user instructions; if there are no specific standards or instructions yet, leave it empty
- Verification must reflect an existing check; if no verification framework exists yet, leave it empty and update it when one exists

Default section order:
- Purpose
- Ownership
- Local Contracts
- Work Guidance
- Verification
- Child DOX Index

## Style

- Keep docs concise, current, and operational
- Document stable contracts, not diary entries
- Put broad rules in parent docs and concrete details in child docs
- Prefer direct bullets with explicit names
- Do not duplicate rules across many files unless each scope needs a local version
- Delete stale notes instead of explaining history
- Trim obvious statements, repeated rules, misplaced detail, and warnings for risks that no longer exist

## Closeout

1. Re-check changed paths against the DOX chain
2. Update nearest owning docs and any affected parents or children
3. Refresh every affected Child DOX Index
4. Remove stale or contradictory text
5. Run existing verification when relevant
6. Report any docs intentionally left unchanged and why

## User Preferences

When the user requests a durable behavior change, record it here or in the relevant child AGENTS.md

- Verification runs locally with no host installs: lint through Docker
  containers (`koalaman/shellcheck`, `php:8-cli`), unit tests as plain bash

## Child DOX Index

- `plugin/AGENTS.md` — the tree installed to the server: settings page, PHP
  handlers, shell scripts. Owns the script/PHP boundary rules.
- `tests/AGENTS.md` — the bash test suite and its stubs. Owns test conventions.
- `docs/` — design specs and implementation plans. No child AGENTS.md; the
  root contract applies.
- `build/`, `ca/`, `images/` — packaging, Community Applications metadata, and
  the CA listing icon. No child AGENTS.md; the root contract applies.

