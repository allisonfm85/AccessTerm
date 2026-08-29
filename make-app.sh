#!/bin/bash
# Builds AccessTerm in release mode and wraps it in a double-clickable .app bundle.
# Usage: ./make-app.sh        (result: build/AccessTerm.app)
#
# --build-system native keeps SwiftPM's own build engine. It copies SwiftTerm's Metal shader
# into the resource bundle; the newer Swift Build engine compiles it instead, which needs the
# `metal` compiler -- an optional part of the full Xcode app that the Command Line Tools do
# not carry. AccessTerm never uses SwiftTerm's GPU view, so there is nothing to compile for.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --build-system native

APP="build/AccessTerm.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/AccessTerm" "$APP/Contents/MacOS/AccessTerm"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run it with: open $APP"
