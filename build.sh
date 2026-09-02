#!/bin/bash
# Builds Poe.app — a self-contained, double-clickable Mac app.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
APP="$ROOT/build/Poe.app"

RELAUNCH=0
for arg in "$@"; do
    case "$arg" in
        --run|--relaunch|-r)
            RELAUNCH=1
            ;;
    esac
done

echo "→ Compiling (release)…"
swift build -c release

echo "→ Drawing app icon…"
rm -rf "$ROOT/build/icon"
mkdir -p "$ROOT/build/icon"
swift tools/make_icon.swift "$ROOT/build/icon" >/dev/null
iconutil -c icns "$ROOT/build/icon/Poe.iconset" -o "$ROOT/build/icon/AppIcon.icns"

echo "→ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Poe" "$APP/Contents/MacOS/Poe"
cp "$ROOT/build/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "→ Signing (ad-hoc)…"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "✓ Built $APP"

if [ "$RELAUNCH" -eq 1 ]; then
    echo "→ Launching $APP..."
    pkill -x Poe 2>/dev/null || true
    open "$APP"
else
    echo "  open \"$APP\"        # run it"
    echo "  cp -R \"$APP\" /Applications/   # install it"
fi
