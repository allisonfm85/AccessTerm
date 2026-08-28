#!/bin/bash
# Builds and runs AccessTerm with a complete, internally consistent Xcode
# toolchain. This avoids partially updated standalone Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

source "scripts/prepare-toolchain.sh"
swift run
