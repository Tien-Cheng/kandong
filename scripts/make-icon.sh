#!/usr/bin/env bash
# Renders assets/AppIcon.icon (the layered Liquid Glass icon) into the flat fallbacks:
#   assets/AppIcon.icns  used when a build can't compile the .icon (Command Line Tools only)
#   assets/icon.png      256px, for the README
# Needs Xcode 27 (for Icon Composer's ictool); xcode-select can stay on the Command Line Tools.
# Run after editing the .icon and commit the results; builds only copy the .icns.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ictool=""
for c in "$DEV/../Applications/Icon Composer.app/Contents/Executables/ictool" \
         "/Applications/Icon Composer.app/Contents/Executables/ictool"; do
  [[ -x "$c" ]] && { ictool="$c"; break; }
done
if [[ -z "$ictool" ]]; then
  echo "Icon Composer's ictool not found: install Xcode 27 (or set DEVELOPER_DIR)." >&2
  exit 1
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
set="$tmp/AppIcon.iconset"
mkdir "$set"
# ictool draws the icon shape edge to edge; a macOS icon sits in the middle 824 of 1024, so render
# the shape at that size (kept even so it centres exactly) and pad it to the slot.
render() { # render <pixels> <file>
  local body=$(( 2 * (($1 * 412 + 512) / 1024) ))
  "$ictool" assets/AppIcon.icon --export-image --output-file "$2" --platform macOS \
    --rendition Default --width "$body" --height "$body" --scale 1 >/dev/null
  sips --padToHeightWidth "$1" "$1" "$2" >/dev/null
}
for size in 16 32 128 256 512; do
  render "$size" "$set/icon_${size}x${size}.png"
  render $((size * 2)) "$set/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$set" -o assets/AppIcon.icns
cp "$set/icon_256x256.png" assets/icon.png
echo "Wrote assets/AppIcon.icns and assets/icon.png"
