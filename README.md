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

The settings page itself uses a Font Awesome icon (`fa-recycle`) that the
Unraid webGui already ships, so no image is packaged with the plugin. The PNG
in `images/` exists only for the Community Applications listing — see
[Publishing to Community Applications](#publishing-to-community-applications).

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

A volume whose size shows as `unknown` means its directory could not be read —
not that it is empty.

The anonymous/named split is a heuristic: a volume is treated as anonymous
when its name is exactly 64 lowercase hex characters, which is what Docker
generates for an anonymous volume. A user-named volume that happens to match
that pattern would be misclassified as anonymous.

## About the custom cron schedule

The custom cron field takes five numeric fields (minute, hour, day of month,
month, day of week) — the same fields a crontab line uses. Names and
nicknames such as `MON`, `JAN`, `@daily`, or `@reboot` are rejected, even
though some cron implementations accept them. The plugin writes this field
into a fragment that gets stitched into the whole server's crontab; a
malformed fragment there can break cron for every other job on the box, not
just this one, so the validator is deliberately strict.

## Uninstall

Removing the plugin deletes the scheduled job immediately. Your settings stay at
`/boot/config/plugins/docker.cleanup/docker.cleanup.cfg`, so reinstalling
restores your schedule.

## Development

```bash
./test              # lint + unit tests
./test test_cron    # run a subset by name
SKIP_LINT=1 ./test  # skip the Docker-based linters
build/build.sh      # build release/docker.cleanup-YYYY.MM.DD-x86_64-1.txz and stamp the .plg
```

Lint runs `shellcheck` and `php -l` inside Docker containers, so neither has to
be installed locally. Without Docker and without `SKIP_LINT=1`, `./test` fails
rather than silently skipping lint. `SKIP_LINT=1 ./test` still runs the PHP
unit tests, just not `php -l`. The shell test suite is plain bash and drives
the scripts with a stub `docker` on `PATH`.

Design and implementation notes live in `docs/superpowers/`.

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
