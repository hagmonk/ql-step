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
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run 'make install' first" >&2
    exit 1
fi

registered() {
    pluginkit -m -i "$THUMBNAIL" 2>/dev/null | grep -q . &&
        pluginkit -m -i "$PREVIEW" 2>/dev/null | grep -q .
}

cleanup_stale_launch_services_records() {
    local canonical_app
    canonical_app="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"

    echo "Removing stale Launch Services registrations"
    "$LSREGISTER" -dump 2>/dev/null |
        awk -F':                       ' '/path:.*QuickLookStep\.app/ { sub(/ \([^)]*\)$/, "", $2); print $2 }' |
        while IFS= read -r registered_path; do
            if [ "$registered_path" != "$canonical_app" ]; then
                "$LSREGISTER" -u "$registered_path" >/dev/null 2>&1
            fi
        done

    "$LSREGISTER" -gc >/dev/null 2>&1
}

attempt_registration() {
    # Launching through LaunchServices is the most reliable registration
    # path; pluginkit -a alone sometimes doesn't take after an election
    # was dropped
    open -g "$APP"
    sleep 2
    pluginkit -a "$APP"
    sleep 1
}

echo "Registering extensions from $APP"
cleanup_stale_launch_services_records
attempt_registration
if ! registered; then
    # pkd (the plugin daemon) caches elections and can wedge after
    # repeated installs/upgrades; restart it and try once more
    echo "Registration didn't take; restarting the plugin daemon and retrying"
    pkill -9 pkd 2>/dev/null
    sleep 3
    attempt_registration
fi

echo "Flushing Quick Look caches"
qlmanage -r >/dev/null 2>&1
qlmanage -r cache >/dev/null 2>&1

echo "Enabling extensions"
pluginkit -e use -i "$THUMBNAIL"
pluginkit -e use -i "$PREVIEW"

echo "Restarting Quick Look services and Finder"
for process in QuickLookStep StepPreview StepThumbnail QuickLookUIService quicklookd; do
    killall "$process" 2>/dev/null
    pkill -9 -x "$process" 2>/dev/null
done
killall Finder 2>/dev/null

sleep 1
echo
echo "Current registrations:"
pluginkit -m -v -i "$THUMBNAIL" 2>/dev/null
pluginkit -m -v -i "$PREVIEW" 2>/dev/null
echo
echo "Done. Press Space on a .step/.stp file in Finder to verify."
