#!/bin/bash
# Creates a stable self-signed code-signing identity in the login keychain.
#
# Why this exists: ad-hoc signing (`codesign --sign -`) produces a designated
# requirement of a bare `cdhash H"..."`, so every rebuild invalidates any TCC
# permission the app holds — the Accessibility row keeps displaying as enabled
# while silently doing nothing. Signing with a fixed certificate instead yields
#
#   identifier "local.voicebridge" and certificate root = H"<cert hash>"
#
# which is stable across rebuilds, so the grant survives.
#
# The certificate does NOT need to be trusted. codesign accepts an untrusted
# self-signed identity, which is what keeps this free of password prompts.
set -euo pipefail

CN="VoiceBridge Local Signing"

if security find-identity -p codesigning 2>/dev/null | grep -q "$CN"; then
  echo "Identity already present:"
  security find-identity -p codesigning | grep "$CN"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/vb.key" -out "$TMP/vb.crt" \
  -subj "/CN=$CN/O=Local Development" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# Legacy PBE on purpose: OpenSSL 3 defaults to AES-256-CBC/SHA-256 for PKCS12,
# which Apple's importer rejects with "MAC verification failed".
openssl pkcs12 -export -out "$TMP/vb.p12" -inkey "$TMP/vb.key" -in "$TMP/vb.crt" \
  -name "$CN" -passout pass:vb \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

# -T /usr/bin/codesign pre-authorises codesign against the key, so signing does
# not raise a keychain prompt.
security import "$TMP/vb.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P vb -T /usr/bin/codesign -T /usr/bin/security

echo "Created:"
security find-identity -p codesigning | grep "$CN"
echo
echo "CSSMERR_TP_NOT_TRUSTED next to it is expected and harmless — codesign uses it regardless."
