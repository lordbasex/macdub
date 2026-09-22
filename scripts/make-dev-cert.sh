#!/usr/bin/env bash
# Creates a self-signed code-signing certificate ("MacDub Dev") in the login keychain.
#
# Why: an ad-hoc signature changes on every build, so macOS forgets the Screen Recording
# grant each time you rebuild. Signing with a stable identity keeps the grant.
# macOS may show a password dialog when the certificate is marked as trusted.
#
# Usage: ./scripts/make-dev-cert.sh   then   CODESIGN_IDENTITY="MacDub Dev" make run
set -euo pipefail

NAME="${1:-MacDub Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "✔ Identity \"$NAME\" already exists"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "▶ Generating key and certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -config "$WORK/openssl.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout pass:macdub -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
       -out "$WORK/identity.p12" -passout pass:macdub

echo "▶ Importing into login keychain"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P macdub -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "▶ Trusting it for code signing (macOS may ask for your password)"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

# Let codesign use the key without a per-build keychain prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

security find-identity -v -p codesigning | grep "$NAME" || { echo "✖ Identity not found after import"; exit 1; }
echo
echo "✔ Done. Build with:  CODESIGN_IDENTITY=\"$NAME\" make run"
