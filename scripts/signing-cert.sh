#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Pulse Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "$NAME is already in your keychain."
    exit 0
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null
password=$(openssl rand -hex 16)
openssl pkcs12 -export -name "$NAME" -inkey "$dir/key.pem" -in "$dir/cert.pem" -out "$dir/signing.p12" -passout "pass:$password"

security import "$dir/signing.p12" -k "$KEYCHAIN" -P "$password" -T /usr/bin/codesign
echo "macOS asks for your password once, to trust $NAME for code signing."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$dir/cert.pem"

mkdir -p build
cp "$dir/signing.p12" build/pulse-signing.p12
echo "$password" > build/pulse-signing.password
echo "Done. build.sh now signs with $NAME."
echo "For releases, add build/pulse-signing.p12 (base64) and build/pulse-signing.password as the PULSE_SIGNING_P12 and PULSE_SIGNING_PASSWORD secrets, then delete both files."
