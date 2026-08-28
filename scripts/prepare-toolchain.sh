#!/bin/bash
# Source this file before invoking SwiftPM. It selects a complete Xcode
# toolchain and ensures SwiftTerm's Metal shader compiler is installed.

if [[ -n "${DEVELOPER_DIR:-}" && -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    accessterm_developer_dir="$DEVELOPER_DIR"
else
    accessterm_selected_dir="$(xcode-select -p 2>/dev/null || true)"
    if [[ -x "$accessterm_selected_dir/usr/bin/xcodebuild" ]]; then
        accessterm_developer_dir="$accessterm_selected_dir"
    elif [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
        accessterm_developer_dir="/Applications/Xcode.app/Contents/Developer"
    elif [[ -x "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
        accessterm_developer_dir="/Applications/Xcode-beta.app/Contents/Developer"
    else
        cat >&2 <<'EOF'
AccessTerm requires the complete Xcode app because SwiftTerm compiles a Metal
shader. Apple's standalone Command Line Tools do not include xcodebuild or the
downloadable Metal Toolchain.

Install Xcode, then run this command again. You do not need to change the
system-wide xcode-select setting; this script selects Xcode only for this build.
EOF
        return 1
    fi
fi

export DEVELOPER_DIR="$accessterm_developer_dir"

if ! xcrun --find metal >/dev/null 2>&1; then
    accessterm_xcode_app="${DEVELOPER_DIR%/Contents/Developer}"
    echo "Installing the Metal Toolchain component for $(basename "$accessterm_xcode_app")..."
    xcodebuild -downloadComponent metalToolchain
fi

if ! xcrun --find metal >/dev/null 2>&1; then
    echo "The Metal compiler is still unavailable after component installation." >&2
    echo "Open Xcode > Settings > Components and install Metal Toolchain." >&2
    return 1
fi

unset accessterm_developer_dir accessterm_selected_dir accessterm_xcode_app
