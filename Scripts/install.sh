#!/bin/bash
# Builds Orbit, replaces /Applications/Orbit.app and starts it again in the menu bar (no window; pass
# --open to show it, --no-open to leave it stopped). Settings, backups and the undo history live in
# ~/Library/Application Support/Orbit, so they carry over.
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/build.sh
DEST="/Applications/Orbit.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

echo "==> Installing to $DEST"
osascript -e 'tell application id "com.himanshudixit.orbit" to quit' >/dev/null 2>&1 || true
# Quitting waits for a change Orbit is in the middle of (ten seconds at most).
for _ in $(seq 1 24); do
  pgrep -f "^$DEST/Contents/MacOS/Orbit" >/dev/null || break
  sleep 0.5
done
# The quit request can be blocked by macOS's Automation permission, so stop any copy still running
# (but never the "Orbit Dev" practice build).
for pid in $(pgrep -x Orbit); do
  /bin/ps -p "$pid" -o command= | grep -q "Orbit Dev.app" || kill "$pid"
done
sleep 1
if [ -d "$DEST" ]; then
  mv "$DEST" "$HOME/.Trash/Orbit (previous build $(date +%H%M%S)).app"
fi
mv .build/Orbit.app "$DEST"
"$LSREGISTER" -f "$DEST"

case "${1:-}" in
  --no-open) ;;
  --open) open "$DEST" ;;
  *) open -g -a "$DEST" --args --background ;;
esac
echo "==> Done"
