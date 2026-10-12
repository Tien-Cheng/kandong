#!/usr/bin/env bash
# Creates a self-signed code-signing identity "Kandong Self-Signed" in your login keychain.
# Builds signed with it keep the same identity, so macOS remembers the Accessibility and Screen
# Recording grants across rebuilds (ad-hoc builds lose them every time). Run once.
set -euo pipefail
NAME="Kandong Self-Signed"
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "\"$NAME\" already exists."; exit 0
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
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -days 3650 -config "$tmp/cfg" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout pass:temp -name "$NAME"
security import "$tmp/id.p12" -k ~/Library/Keychains/login.keychain-db -P temp -T /usr/bin/codesign
echo "Created \"$NAME\". scripts/build-app.sh will use it."
