#!/usr/bin/env bash
# Builds build/Kandong.app (release) from the Swift package.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  also copy to ~/Applications and launch
# Signing: $SIGN_IDENTITY, else "Kandong Self-Signed" (scripts/make-signing-identity.sh),
# else an "Apple Development" identity, else ad-hoc. Ad-hoc builds lose the Accessibility grant on
# every rebuild; a stable identity keeps it.
# Updates: Sparkle reads $KANDONG_FEED_URL if set (for testing), else the latest GitHub Release's appcast.xml.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/fetch-data.sh
swift build -c release --product Kandong
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/Kandong"

APP=build/Kandong.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Kandong"
# Sparkle (self-update). Its XPC services are only for sandboxed apps; Kandong isn't sandboxed.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Kandong"
cp Data/cedict_ts.u8 Data/hsk.tsv Data/LXGWWenKaiLite-Regular.ttf assets/AppIcon.icns "$APP/Contents/Resources/"
# Liquid Glass icon: Xcode 27's actool compiles assets/AppIcon.icon into Assets.car, which
# CFBundleIconName points at (xcode-select can stay on the Command Line Tools). Without it, the
# committed AppIcon.icns (CFBundleIconFile) is the icon. scripts/make-icon.sh regenerates the .icns.
ICON_NAME=""
DEV="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ -d "$DEV" ]]; then
  icon_tmp="$(mktemp -d)"; trap 'rm -rf "$icon_tmp"' EXIT
  if DEVELOPER_DIR="$DEV" xcrun actool assets/AppIcon.icon --compile "$icon_tmp" \
      --platform macosx --target-device mac --minimum-deployment-target 27.0 --app-icon AppIcon \
      --output-partial-info-plist "$icon_tmp/partial.plist" >/dev/null 2>&1 \
      && [[ -s "$icon_tmp/Assets.car" ]]; then
    cp "$icon_tmp/Assets.car" "$APP/Contents/Resources/"
    ICON_NAME="<key>CFBundleIconName</key><string>AppIcon</string>"
  else
    echo "actool in $DEV couldn't compile assets/AppIcon.icon; using AppIcon.icns only"
  fi
fi
# Marketing version from $KANDONG_VERSION or the latest v* tag; build number ($KANDONG_BUILD, for
# testing updates) from the commit count. Sparkle compares build numbers.
VERSION="${KANDONG_VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"
BUILD="${KANDONG_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

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
  ${ICON_NAME}
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
  <key>SUFeedURL</key><string>${KANDONG_FEED_URL:-https://github.com/Tien-Cheng/kandong/releases/latest/download/appcast.xml}</string>
  <key>SUPublicEDKey</key><string>3p92on09ZfPZh1un67oshTUqT3X16Hkrt+XPV7o9MFc=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
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
# Inside out, as Sparkle asks (no --deep): its helpers, the framework, then the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for part in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
  codesign --force --options runtime --sign "${IDENTITY:--}" "$part"
done
codesign --force --options runtime --entitlements scripts/Kandong.entitlements --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  pkill -x Kandong 2>/dev/null || true
  rm -rf ~/Applications/Kandong.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/Kandong.app
  echo "Installed to ~/Applications/Kandong.app"
fi
