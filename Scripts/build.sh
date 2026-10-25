#!/bin/bash
# Builds Orbit.app (release) at .build/Orbit.app, signed with your Apple Development identity so the
# permissions macOS grants Orbit survive rebuilds.
#   --dev    builds "Orbit Dev" (com.himanshudixit.orbit.dev), which always runs in practice mode
#   --adhoc  signs without a certificate (macOS then asks for permissions again after each build)
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=0
ADHOC=0
for arg in "$@"; do
  case $arg in
    --dev) DEV=1 ;;
    --adhoc) ADHOC=1 ;;
  esac
done
NAME=Orbit
ID=com.himanshudixit.orbit
SCHEME=orbit
if [ $DEV = 1 ]; then
  NAME="Orbit Dev"
  ID=com.himanshudixit.orbit.dev
  SCHEME=orbitdev
fi
OUT=".build/$NAME.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p .build
touch .build/.metadata_never_index

echo "==> Building $NAME"
LOG=.build/build.log
if ! swift build -c release --product Orbit > "$LOG" 2>&1; then
  grep -E "error" "$LOG" | sed 's/\x1b\[[0-9;]*m//g' | sort -u | head -30
  echo "!! build failed (full log: $LOG)"
  exit 1
fi
BIN="$(swift build -c release --product Orbit --show-bin-path)/Orbit"

echo "==> Assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/Orbit"
[ -f Packaging/AppIcon.icns ] || Scripts/make-icon.sh
cp Packaging/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
sed -e "s/__NAME__/$NAME/g" -e "s/__ID__/$ID/g" -e "s/__SCHEME__/$SCHEME/g" \
    -e "s/__VERSION__/$(cat VERSION)/g" -e "s/__BUILD__/$(date +%Y%m%d%H%M%S)/g" \
    Packaging/Info.plist > "$OUT/Contents/Info.plist"
plutil -lint -s "$OUT/Contents/Info.plist"
printf 'APPL????' > "$OUT/Contents/PkgInfo"
xattr -cr "$OUT"

IDENTITY=""
[ $ADHOC = 0 ] && IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
if [ -n "$IDENTITY" ]; then
  echo "==> Signing with your Apple Development identity"
  codesign --force --sign "$IDENTITY" --identifier "$ID" --timestamp=none "$OUT"
else
  echo "==> Signing ad hoc"
  codesign --force --sign - --identifier "$ID" "$OUT"
fi
codesign --verify --strict "$OUT" && echo "   signature ok ($(codesign -dvv "$OUT" 2>&1 | sed -n 's/^Authority=\(Apple Development.*\)/\1/p' | head -1))"
# Keep macOS from treating the build copy as another Orbit.
"$LSREGISTER" -u "$PWD/$OUT" 2>/dev/null || true
echo "==> Done: $PWD/$OUT ($(du -sh "$OUT" | cut -f1))"
