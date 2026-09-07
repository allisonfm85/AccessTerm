#!/bin/bash
# Cuts a release of AccessTerm: sets the version, builds a universal (Apple Silicon + Intel)
# .app, signs it with your Developer ID, notarizes it with Apple, then tags the commit and
# publishes a GitHub release with the zip attached.
#
# Usage: ./release.sh <version> [notes.md]
#   ./release.sh 0.2.0              release notes are generated from the commits since the last tag
#   ./release.sh 0.2.0 notes.md     use this file as the release notes
#
# One-time setup for notarization (skipped, with a warning, when it is missing):
#   xcrun notarytool store-credentials AccessTerm --apple-id <your Apple ID> --team-id <team ID>
# It asks for an app-specific password, which you make at https://account.apple.com under
# Sign-In and Security > App-Specific Passwords. The team ID is the code in parentheses in the
# name of your "Developer ID Application" certificate (see `security find-identity -v -p codesigning`).
#
# Needs: Xcode (for notarytool), the gh command logged in, a clean checkout on main.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
NOTES="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: ./release.sh <major.minor.patch> [notes.md]" >&2; exit 1; }
[[ -z "$NOTES" || -f "$NOTES" ]] || { echo "Notes file not found: $NOTES" >&2; exit 1; }
TAG="v$VERSION"
PROFILE="AccessTerm"    # notarytool keychain profile name, see the setup note above
APP="build/AccessTerm.app"
ZIP="build/AccessTerm-$VERSION.zip"

# --- preflight ------------------------------------------------------------------------------
[[ "$(git branch --show-current)" == "main" ]] || { echo "Switch to main first." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first; the tree must be clean." >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "Tag $TAG already exists." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first." >&2; exit 1; }

IDENTITY="$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | awk '{print $2}')"
if [[ -z "$IDENTITY" ]]; then
    echo "WARNING: no 'Developer ID Application' certificate in the keychain; signing ad hoc." >&2
    echo "         Users will have to allow the app under System Settings > Privacy & Security." >&2
fi
NOTARIZE=1
if [[ -z "$IDENTITY" ]] || ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    NOTARIZE=0
    [[ -n "$IDENTITY" ]] && echo "WARNING: no notarytool profile named '$PROFILE'; skipping notarization (see the top of this script)." >&2
fi

# --- version --------------------------------------------------------------------------------
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
BUILD_NUMBER=$(( $(git rev-list --count HEAD) + 1 ))    # the release commit itself, added below
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" Resources/Info.plist
sed -i '' "s|env\[\"TERM_PROGRAM_VERSION\"\] = \"[^\"]*\"|env[\"TERM_PROGRAM_VERSION\"] = \"$VERSION\"|" Sources/AccessTerm/TerminalSession.swift

# --- build ----------------------------------------------------------------------------------
# --build-system native: see make-app.sh for why. One build per architecture, merged with lipo;
# SwiftPM's own multi-arch build does not work with the SwiftTerm package.
echo "Building arm64..."
swift build -c release --build-system native --triple arm64-apple-macosx
echo "Building x86_64..."
swift build -c release --build-system native --triple x86_64-apple-macosx

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/arm64-apple-macosx/release/AccessTerm .build/x86_64-apple-macosx/release/AccessTerm \
     -output "$APP/Contents/MacOS/AccessTerm"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# --- sign -----------------------------------------------------------------------------------
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

# --- notarize -------------------------------------------------------------------------------
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
if [[ "$NOTARIZE" == 1 ]]; then
    echo "Submitting to Apple for notarization (usually a few minutes)..."
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"    # re-zip so the download carries the staple
    spctl --assess --type execute --verbose=2 "$APP"
fi

# --- commit, tag, publish -------------------------------------------------------------------
git add Resources/Info.plist Sources/AccessTerm/TerminalSession.swift
git commit -q -m "Release $VERSION"
git tag -a "$TAG" -m "AccessTerm $VERSION"
git push -q origin main "$TAG"

if [[ -n "$NOTES" ]]; then
    gh release create "$TAG" "$ZIP" --title "AccessTerm $VERSION" --notes-file "$NOTES"
else
    gh release create "$TAG" "$ZIP" --title "AccessTerm $VERSION" --generate-notes
fi
echo "Released $TAG"
