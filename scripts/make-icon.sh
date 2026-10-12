#!/usr/bin/env bash
# Renders assets/icon.svg into assets/AppIcon.icns (needs rsvg-convert: brew install librsvg).
# Run after editing the SVG and commit both; builds only copy the .icns.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
set="$tmp/AppIcon.iconset"
mkdir "$set"
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" assets/icon.svg -o "$set/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) assets/icon.svg -o "$set/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$set" -o assets/AppIcon.icns
echo "Wrote assets/AppIcon.icns"
