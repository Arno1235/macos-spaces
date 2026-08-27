#!/bin/bash
set -euo pipefail

NAME="Spaces Local Signer"
if security find-identity -v -p codesigning | grep -F -q "$NAME"; then
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
  -subj "/CN=${NAME}/O=Spaces" \
  -keyout "$TMP/key.pem" \
  -out "$TMP/cert.pem" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "keyUsage=digitalSignature"

# User-domain trust; do not use -d (that requires an admin prompt).
security add-trusted-cert -r trustRoot -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  "$TMP/cert.pem"

# OpenSSL 3 PKCS#12 is not accepted by Security.framework without -legacy.
openssl pkcs12 -export -legacy \
  -inkey "$TMP/key.pem" \
  -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" \
  -passout pass:spaces

security import "$TMP/cert.p12" \
  -P spaces \
  -A \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null

security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" \
  "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
