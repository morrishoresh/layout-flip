#!/bin/bash
# Builds LayoutFlip.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/LayoutFlip.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LayoutFlip "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp shell/layout-flip.zsh "$APP/Contents/Resources/"
# Ad-hoc signatures are identified by their hash, so macOS would drop the Accessibility grant on every rebuild.
# Requiring only the bundle identifier keeps the grant across rebuilds.
codesign --force --sign - --requirements '=designated => identifier "com.morrish.LayoutFlip"' "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x LayoutFlip || true
    rm -rf /Applications/LayoutFlip.app
    cp -R "$APP" /Applications/
    # Register the app and refresh the Services menu so "Convert Keyboard Layout" shows up.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/LayoutFlip.app
    /System/Library/CoreServices/pbs -update
    echo "Installed /Applications/LayoutFlip.app"
fi
