#!/bin/bash
# Draws the app icon (make-icon.swift) and packs every size into Packaging/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."
swift Scripts/make-icon.swift Packaging/AppIcon.png
SET=.build/AppIcon.iconset
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size Packaging/AppIcon.png --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Packaging/AppIcon.png --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Packaging/AppIcon.icns
echo "wrote Packaging/AppIcon.icns"
