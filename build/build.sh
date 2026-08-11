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
