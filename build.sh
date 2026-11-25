#!/bin/bash
# Build, sign and install threefingerfn. This is the only supported build path.
# Signing with a stable certificate keeps the Accessibility grant valid across rebuilds.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
IDENTITY="threefingerfn-dev"
BUNDLE_ID="com.rock.threefingerfn"
DEST="$HOME/bin/threefingerfn"
LABEL="com.rock.threefingerfn"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -O "$SRC_DIR/main.swift" -o "$TMP/threefingerfn"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$TMP/threefingerfn"

mkdir -p "$(dirname "$DEST")"
# Copying over the old file keeps its inode, and macOS then kills the new code with
# OS_REASON_CODESIGNING (stale signature cache). Install a new file and rename it into place.
cp "$TMP/threefingerfn" "$DEST.new"
mv -f "$DEST.new" "$DEST"

codesign -d -r- "$DEST" 2>&1 | grep designated
echo "Installed $DEST"
if launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null; then
    echo "Restarted $LABEL"
else
    echo "Launch agent $LABEL is not loaded; start $DEST yourself or load the agent (see README)."
fi
