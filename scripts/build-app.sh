#!/usr/bin/env bash
# Builds build/Kandong.app (release) from the Swift package.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  also copy to ~/Applications and launch
# Signing: $SIGN_IDENTITY, else "Kandong Self-Signed" (scripts/make-signing-identity.sh),
# else an "Apple Development" identity, else ad-hoc. Ad-hoc builds lose the Accessibility grant on
# every rebuild; a stable identity keeps it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/fetch-data.sh
swift build -c release --product Kandong
BIN="$(swift build -c release --show-bin-path)/Kandong"

APP=build/Kandong.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kandong"
cp Data/cedict_ts.u8 Data/hsk.tsv Data/LXGWWenKaiLite-Regular.ttf assets/AppIcon.icns "$APP/Contents/Resources/"
# Marketing version from $KANDONG_VERSION or the latest v* tag; build number from the commit count.
VERSION="${KANDONG_VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.tiencheng.kandong</string>
  <key>CFBundleName</key><string>Kandong</string>
  <key>CFBundleDisplayName</key><string>Kandong</string>
  <key>CFBundleExecutable</key><string>Kandong</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.tiencheng.kandong</string>
    <key>CFBundleURLSchemes</key><array><string>kandong</string></array>
  </dict></array>
  <key>NSHumanReadableCopyright</key><string>Dictionary: CC-CEDICT (CC BY-SA 4.0). HSK lists: complete-hsk-vocabulary (MIT).</string>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "Kandong Self-Signed"; then
  IDENTITY="Kandong Self-Signed"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
codesign --force --deep --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  pkill -x Kandong 2>/dev/null || true
  rm -rf ~/Applications/Kandong.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/Kandong.app
  echo "Installed to ~/Applications/Kandong.app"
fi
