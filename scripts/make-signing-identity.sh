#!/usr/bin/env bash
# Creates a self-signed code-signing identity "Kandong Self-Signed" in your login keychain.
# Builds signed with it keep the same identity, so macOS remembers the Accessibility and Screen
# Recording grants across rebuilds (ad-hoc builds lose them every time). Run once.
#   scripts/make-signing-identity.sh                   create it in the login keychain
#   scripts/make-signing-identity.sh --export id.p12   also write it to id.p12 for the release
#                                                      workflow's secrets (see RELEASING.md)
set -euo pipefail
NAME="Kandong Self-Signed"
EXPORT=""
[[ "${1:-}" == "--export" ]] && EXPORT="${2:?usage: --export FILE.p12}"
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "\"$NAME\" already exists."
  [[ -n "$EXPORT" ]] && echo "Export it from Keychain Access (My Certificates → $NAME → Export) instead."
  exit 0
fi
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
PASSWORD="$(openssl rand -hex 16)"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -days 3650 -config "$tmp/cfg" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout "pass:$PASSWORD" -name "$NAME"
security import "$tmp/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASSWORD" -T /usr/bin/codesign
echo "Created \"$NAME\". scripts/build-app.sh will use it."
if [[ -n "$EXPORT" ]]; then
  cp "$tmp/id.p12" "$EXPORT"
  echo "Wrote $EXPORT. Store it as the release workflow's secrets, then delete the file:"
  echo "  base64 -i $EXPORT | gh secret set SIGNING_P12_BASE64"
  echo "  gh secret set SIGNING_P12_PASSWORD --body '$PASSWORD'"
fi
