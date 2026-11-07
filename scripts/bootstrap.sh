#!/bin/bash
# Generates Dal.xcodeproj from project.yml and opens it.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }
xcodegen generate
open Dal.xcodeproj
