#!/bin/bash
# Registers (or repairs) the Quick Look extensions for the installed app.
#
# macOS routinely holds on to stale extension registrations and cached
# thumbnails — after an install, an upgrade, or an identifier change this
# script puts the world back in order. Safe to run any time.
#
# usage: register-quicklook.sh [path-to-app]   (default /Applications)
set -uo pipefail

APP="${1:-/Applications/QuickLookStep.app}"
PREVIEW="com.hagmonk.QLStep.StepPreview"
THUMBNAIL="com.hagmonk.QLStep.StepThumbnail"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run 'make install' first" >&2
    exit 1
fi

echo "Registering extensions from $APP"
# Launching through LaunchServices is the most reliable registration path;
# pluginkit -a alone sometimes doesn't take after an election was dropped
open -g "$APP"
sleep 2
pluginkit -a "$APP"

echo "Flushing Quick Look caches"
qlmanage -r >/dev/null 2>&1
qlmanage -r cache >/dev/null 2>&1

echo "Enabling extensions"
pluginkit -e use -i "$THUMBNAIL"
pluginkit -e use -i "$PREVIEW"

echo "Restarting Quick Look services and Finder"
killall QuickLookUIService quicklookd 2>/dev/null
killall Finder 2>/dev/null

sleep 1
echo
echo "Current registrations:"
pluginkit -m -v -i "$THUMBNAIL" 2>/dev/null
pluginkit -m -v -i "$PREVIEW" 2>/dev/null
echo
echo "Done. Press Space on a .step/.stp file in Finder to verify."
