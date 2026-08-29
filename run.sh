#!/bin/bash
# Builds AccessTerm and launches it. Usage: ./run.sh
#
# --build-system native keeps SwiftPM's own build engine. It copies SwiftTerm's Metal shader
# into the resource bundle; the newer Swift Build engine compiles it instead, which needs the
# `metal` compiler -- an optional part of the full Xcode app that the Command Line Tools do
# not carry. AccessTerm never uses SwiftTerm's GPU view, so there is nothing to compile for.
set -euo pipefail
cd "$(dirname "$0")"

swift run --build-system native AccessTerm "$@"
