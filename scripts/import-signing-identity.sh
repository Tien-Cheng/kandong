#!/usr/bin/env bash
# CI only: imports the "Kandong Self-Signed" identity from $SIGNING_P12_BASE64 / $SIGNING_P12_PASSWORD
# into a throwaway keychain that codesign can use without prompting. Releases signed with the same
# identity keep users' Accessibility and Screen Recording grants across updates.
set -euo pipefail
: "${SIGNING_P12_BASE64:?missing secret SIGNING_P12_BASE64 (see RELEASING.md)}"
: "${SIGNING_P12_PASSWORD:?missing secret SIGNING_P12_PASSWORD (see RELEASING.md)}"
dir="${RUNNER_TEMP:-$(mktemp -d)}"
keychain="$dir/kandong-signing.keychain-db"
keychain_password="$(openssl rand -hex 16)"

echo "$SIGNING_P12_BASE64" | base64 --decode > "$dir/id.p12"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$dir/id.p12" -k "$keychain" -P "$SIGNING_P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
# shellcheck disable=SC2046 # keychain paths contain no spaces on the runner
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
rm "$dir/id.p12"
security find-identity -p codesigning "$keychain"
