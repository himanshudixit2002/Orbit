#!/bin/bash
# Builds Orbit.app (release) at .build/Orbit.app with Xcode (Orbit.xcodeproj), signed with your Apple
# Development identity so the permissions macOS grants Orbit survive rebuilds.
#   --dev    builds "Orbit Dev" (com.himanshudixit.orbit.dev), which always runs in practice mode
#   --adhoc  signs without a certificate (macOS then asks for permissions again after each build)
#
# Builds live under .build, which Spotlight skips, and are unregistered from Launch Services, so the
# only Orbit macOS knows about is the one in /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=Release
NAME=Orbit
ADHOC=0
for arg in "$@"; do
  case $arg in
    --dev) CONFIG=Debug; NAME="Orbit Dev" ;;
    --adhoc) ADHOC=1 ;;
  esac
done
DERIVED=.build/xcode
OUT=".build/$NAME.app"
LOG=.build/xcodebuild.log
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p .build
touch .build/.metadata_never_index

ARGS=(-project Orbit.xcodeproj -scheme Orbit -configuration "$CONFIG" -derivedDataPath "$DERIVED"
      -destination "platform=macOS" -allowProvisioningUpdates
      MARKETING_VERSION="$(cat VERSION)" CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M%S)")
[ $ADHOC = 1 ] && ARGS+=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)

echo "==> Building $NAME"
if ! xcodebuild "${ARGS[@]}" build > "$LOG" 2>&1; then
  grep -E "error:|BUILD FAILED" "$LOG" | sort -u | head -40
  echo "!! build failed (full log: $LOG)"
  exit 1
fi
grep -E "warning:" "$LOG" | grep -v -E "Metadata extraction skipped" | sort -u | head -20 || true

BUILT="$DERIVED/Build/Products/$CONFIG/Orbit.app"
rm -rf "$OUT"
cp -R "$BUILT" "$OUT"
# Xcode registers what it builds; keep macOS from treating the build copies (and their widgets) as
# more Orbits.
for copy in "$DERIVED"/Build/Products/*/Orbit.app "$PWD/$OUT"; do
  [ -e "$copy" ] || continue
  "$LSREGISTER" -u "$copy" 2>/dev/null || true
  pluginkit -r "$copy/Contents/PlugIns/OrbitWidgets.appex" 2>/dev/null || true
done

codesign --verify --deep --strict "$OUT" && echo "   signature ok ($(codesign -dvv "$OUT" 2>&1 | sed -n 's/^Authority=\(Apple Development.*\)/\1/p' | head -1))"
echo "==> Done: $PWD/$OUT ($(du -sh "$OUT" | cut -f1))"
