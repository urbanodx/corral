#!/bin/sh
# Creates a self-signed code-signing identity in the login keychain so every
# rebuild of Corral keeps the same signature, and macOS keeps its Accessibility
# grant. Without it the build is ad-hoc signed and the grant resets on rebuild.
set -eu
NAME="Corral Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "$NAME already in the keychain"; exit 0
fi
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
cat > "$dir/cert.cnf" <<CNF
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
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/key.pem" -out "$dir/cert.pem" -days 3650 -config "$dir/cert.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$dir/key.pem" -in "$dir/cert.pem" -out "$dir/id.p12" -passout pass:corral 2>/dev/null \
  || openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" -out "$dir/id.p12" -passout pass:corral
security import "$dir/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P corral -T /usr/bin/codesign
echo "created $NAME"
