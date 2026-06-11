#!/bin/bash
# Bundles libocctbridge.dylib and its transitive OpenCascade/Homebrew dylib
# closure into an app bundle's Contents/Frameworks, rewrites absolute
# Homebrew paths to @rpath, and ad-hoc signs everything (innermost-first).
#
# usage: bundle-occt.sh <path-to-app-bundle>
set -euo pipefail

APP="$1"
BRIDGE_DIR="$(cd "$(dirname "$0")" && pwd)"
OCCT_LIB="${OCCT_PREFIX:-/opt/homebrew/opt/opencascade}/lib"
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

cp -f "$BRIDGE_DIR/libocctbridge.dylib" "$FRAMEWORKS/"

# Breadth-first closure over Homebrew-resident dependencies. @rpath deps are
# resolved against the OCCT lib dir (OCCT's inter-deps are @rpath already).
queue=("$FRAMEWORKS/libocctbridge.dylib")
while [ ${#queue[@]} -gt 0 ]; do
    lib="${queue[0]}"; queue=("${queue[@]:1}")
    while read -r dep; do
        name="$(basename "$dep")"
        case "$dep" in
            /opt/homebrew/*) src="$dep" ;;
            @rpath/*) src="$OCCT_LIB/$name" ;;
            *) continue ;;
        esac
        [ -f "$src" ] || continue
        if [ ! -f "$FRAMEWORKS/$name" ]; then
            cp -f "$src" "$FRAMEWORKS/$name"
            chmod u+w "$FRAMEWORKS/$name"
            queue+=("$FRAMEWORKS/$name")
        fi
        if [[ "$dep" == /opt/homebrew/* ]]; then
            install_name_tool -change "$dep" "@rpath/$name" "$lib" 2>/dev/null
        fi
    done < <(otool -L "$lib" | tail -n +2 | awk '{print $1}')
done

# Normalize ids and re-sign every bundled dylib
for lib in "$FRAMEWORKS"/*.dylib; do
    install_name_tool -id "@rpath/$(basename "$lib")" "$lib" 2>/dev/null
    codesign --force --sign - "$lib"
done

# Bundle the registration script so installers (e.g. the Homebrew cask
# postflight) can invoke it from inside the app
cp -f "$BRIDGE_DIR/../scripts/register-quicklook.sh" "$APP/Contents/Resources/"

# Re-sign inner-out: extensions, then the app. QL extensions must keep their
# app-sandbox entitlement or pluginkit refuses to launch them.
for appex in "$APP"/Contents/PlugIns/*.appex; do
    codesign --force --sign - --preserve-metadata=entitlements "$appex"
done
codesign --force --sign - --preserve-metadata=entitlements "$APP"

echo "bundled $(ls "$FRAMEWORKS" | wc -l | tr -d ' ') dylibs into $FRAMEWORKS"
