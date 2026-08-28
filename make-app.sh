#!/bin/bash
# Builds AccessTerm in release mode and wraps it in a double-clickable .app bundle.
# Usage: ./make-app.sh        (result: build/AccessTerm.app)
set -euo pipefail
cd "$(dirname "$0")"

source "scripts/prepare-toolchain.sh"
swift build -c release

APP="build/AccessTerm.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/AccessTerm" "$APP/Contents/MacOS/AccessTerm"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run it with: open $APP"
