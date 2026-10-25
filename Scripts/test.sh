#!/bin/bash
# Runs Orbit's tests, then checks the rules the code must keep.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .build
LOG=.build/test.log
# Each test target runs on its own, so only swift test's exit status says whether all of them passed.
if ! swift test > "$LOG" 2>&1; then
  sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E "✘|error:|failed" | head -40
  echo "!! tests failed (full log: $LOG)"
  exit 1
fi
sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E "Test run with"

# The app and its extension are built by Xcode, not the package: make sure they still compile.
XLOG=.build/xcodebuild-test.log
if ! xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -derivedDataPath .build/xcode \
     -destination "platform=macOS" -allowProvisioningUpdates build > "$XLOG" 2>&1; then
  grep -E "error:|BUILD FAILED" "$XLOG" | sort -u | head -40
  echo "!! the app didn't build (full log: $XLOG)"
  exit 1
fi
echo "==> App builds"

fail() { echo "!! $1"; exit 1; }
# Nothing may animate forever: a repeating effect redraws every frame, visible or not.
if grep -rnE "repeatForever|\.repeat\(\.continuous\)" Sources | grep -v "live-gated"; then fail "continuous animation found"; fi
# Nothing is ever deleted for good: things go to the Trash.
if grep -rn "removeItem" Sources; then fail "removeItem found: use trashItem"; fi
# Admin rights only through macOS's own password dialog, never sudo.
if grep -rnE "\"sudo\"|sudo " Sources | grep -v "//"; then fail "sudo found"; fi
# Only the platform layer starts processes.
if grep -rln "Process()" Sources | grep -v "Sources/OrbitPlatform/"; then fail "Process() outside OrbitPlatform"; fi
echo "==> Guards passed"
