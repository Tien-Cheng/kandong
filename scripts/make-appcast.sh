#!/usr/bin/env bash
# Writes Sparkle's appcast.xml (to stdout) for one release, so installed copies can update to it.
#   scripts/make-appcast.sh <Kandong.app> <Kandong-x.y.z.zip> <zip download URL> <release notes URL>
# Signs the zip with Sparkle's sign_update ($SIGN_UPDATE, default: sign_update on PATH), using the
# private key in $SPARKLE_KEY_FILE if set (CI), else the "kandong" account in the login Keychain.
set -euo pipefail
app="$1" zip="$2" url="$3" notes="$4"

plist="$app/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")"

key=(--account kandong)
[[ -n "${SPARKLE_KEY_FILE:-}" ]] && key=(--ed-key-file "$SPARKLE_KEY_FILE")
# Prints: sparkle:edSignature="…" length="…"
signature="$("${SIGN_UPDATE:-sign_update}" "${key[@]}" "$zip")"

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Kandong</title>
    <item>
      <title>Kandong $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$notes</sparkle:releaseNotesLink>
      <enclosure url="$url" type="application/octet-stream" $signature/>
    </item>
  </channel>
</rss>
XML
