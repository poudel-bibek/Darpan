#!/bin/bash
# Creates the self-signed "Darpan" code-signing identity in the login keychain, once per build
# Mac. build.sh signs with it, so every release has the same designated requirement: the
# Keychain's "Always Allow" survives updates, and the updater only installs apps signed by it.
#
#   bash mac/make-signing-identity.sh
#
# Back up the identity (Keychain Access → My Certificates → Darpan → Export, with a passphrase):
# without it, installed copies won't accept updates signed with a new one and need one manual
# install.
set -euo pipefail
if security find-identity -p codesigning | grep -qF '"Darpan"'; then echo "a Darpan identity exists already"; exit 0; fi
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
openssl req -x509 -newkey rsa:2048 -keyout "$D/k.pem" -out "$D/c.pem" -days 3650 -nodes -subj "/CN=Darpan" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
P=$(openssl rand -hex 16)
openssl pkcs12 -export -legacy -inkey "$D/k.pem" -in "$D/c.pem" -name Darpan -out "$D/d.p12" -passout "pass:$P" 2>/dev/null
security import "$D/d.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$P" -T /usr/bin/codesign >/dev/null
security find-identity -p codesigning | grep -F '"Darpan"'
