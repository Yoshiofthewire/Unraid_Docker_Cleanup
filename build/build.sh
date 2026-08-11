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

# YYYY.MM.DD, with an optional .N suffix for a second release the same day.
# Enforced up front: an unchecked VERSION flows into both the .txz filename
# and the sed replacement text below, where a stray '|' would silently break
# the substitution.
if [[ ! "$VERSION" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]]; then
  echo "Invalid version '$VERSION' — expected YYYY.MM.DD or YYYY.MM.DD.N" >&2
  exit 1
fi

TARGET="$STAGE/usr/local/emhttp/plugins/$NAME"
mkdir -p "$TARGET" "$DEST"
cp -a "$ROOT/plugin/." "$TARGET/"

# Scripts must be executable inside the package; everything else stays 644.
find "$TARGET" -type f -exec chmod 644 {} +
find "$TARGET/scripts" -type f -name '*.sh' -exec chmod 755 {} +

# Slackware package naming: name-version-arch-build. Its tooling derives the
# package's base name by stripping the last three dash-separated fields, so
# a two-field name doesn't round-trip through upgradepkg/removepkg.
PKGBASE="$NAME-$VERSION-x86_64-1"
TXZ="$DEST/$PKGBASE.txz"
tar -C "$STAGE" --owner=0 --group=0 --numeric-owner -cJf "$TXZ" usr

MD5="$(md5sum "$TXZ" | awk '{print $1}')"
printf '%s\n' "$MD5" > "$TXZ.md5"

PLG="$ROOT/$NAME.plg"
sed -i -E \
  -e "s|(<!ENTITY version   \")[^\"]*(\">)|\1$VERSION\2|" \
  -e "s|(<!ENTITY md5       \")[^\"]*(\">)|\1$MD5\2|" \
  "$PLG"

# sed -i cannot report a no-match; if the .plg's entity formatting ever
# drifts, the substitution above would silently do nothing and this script
# would still print "Stamped" — shipping a release .plg with a stale or
# PLACEHOLDER md5 that every user's Unraid would reject. Verify it landed.
grep -qF "<!ENTITY version   \"$VERSION\">" "$PLG" \
  || { echo "Failed to stamp version into $PLG" >&2; exit 1; }
grep -qF "<!ENTITY md5       \"$MD5\">" "$PLG" \
  || { echo "Failed to stamp md5 into $PLG" >&2; exit 1; }

echo "Built  $TXZ"
echo "MD5    $MD5"
echo "Stamped $PLG"
