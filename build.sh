#!/bin/bash
# Builds LayoutFlip.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/LayoutFlip.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O Tools/IconRenderer/main.swift -o build/icon-renderer
build/icon-renderer appicon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/LayoutFlip "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp shell/layout-flip.zsh "$APP/Contents/Resources/"
# The Claude Code mod, without its tests and the files Claude Code generates in it.
rsync -a --exclude '*.test.ts' --exclude tsconfig.json --exclude types claude-code/ "$APP/Contents/Resources/claude-code/"
# Ad-hoc signatures are identified by their hash, so macOS would drop the Accessibility grant on every rebuild.
# Requiring only the bundle identifier keeps the grant across rebuilds.
codesign --force --sign - --requirements '=designated => identifier "com.morrishoresh.LayoutFlip"' "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x LayoutFlip || true
    rm -rf /Applications/LayoutFlip.app
    cp -R "$APP" /Applications/
    # Register the app and refresh the Services menu so "Convert Keyboard Layout" shows up.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/LayoutFlip.app
    /System/Library/CoreServices/pbs -update
    echo "Installed /Applications/LayoutFlip.app"

    if command -v claude >/dev/null; then
        # Claude Code writes into the plugin folders it loads, so the mod runs from a copy outside the signed bundle.
        MOD="$HOME/Library/Application Support/LayoutFlip/claude-code"
        rm -rf "$MOD"
        mkdir -p "$(dirname "$MOD")"
        cp -R /Applications/LayoutFlip.app/Contents/Resources/claude-code "$MOD"
        python3 Tools/register-claude-mod.py "$MOD"
        echo "Installed the Claude Code mod to $MOD"
    fi
fi
