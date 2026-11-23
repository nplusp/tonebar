#!/bin/bash
# Builds build/Tonebar.app (universal: Apple silicon + Intel).
#   scripts/build-app.sh            build and sign
#   scripts/build-app.sh --install  also copy to /Applications and relaunch
# Signs with your "Apple Development" certificate when you have one, otherwise ad hoc.
# macOS ties the System Audio Recording permission to the signature: with a certificate
# it survives rebuilds, ad hoc it is asked again after every build.
# CODESIGN_IDENTITY overrides the choice ("-" forces ad hoc).
set -euo pipefail

cd "$(dirname "$0")/.."
APP=build/Tonebar.app

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Tonebar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tonebar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed: $([[ "$IDENTITY" == "-" ]] && echo "ad hoc" || echo "$IDENTITY"))"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Tonebar || true
    rm -rf /Applications/Tonebar.app
    cp -R "$APP" /Applications/
    open /Applications/Tonebar.app
    echo "Installed /Applications/Tonebar.app"
fi
