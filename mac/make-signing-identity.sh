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
# A config file rather than -addext, so macOS's own LibreSSL works as well as OpenSSL 3.
cat > "$D/cfg" <<'CFG'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = Darpan
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CFG
openssl req -x509 -newkey rsa:2048 -keyout "$D/k.pem" -out "$D/c.pem" -days 3650 -nodes -config "$D/cfg" -extensions v3 2>/dev/null
P=$(openssl rand -hex 16)
# OpenSSL 3 needs -legacy for a PKCS#12 the Keychain can import; LibreSSL has no such option.
LEGACY=$(openssl pkcs12 -help 2>&1 | grep -q -- -legacy && echo -legacy || true)
openssl pkcs12 -export $LEGACY -inkey "$D/k.pem" -in "$D/c.pem" -name Darpan -out "$D/d.p12" -passout "pass:$P" 2>/dev/null
security import "$D/d.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$P" -T /usr/bin/codesign >/dev/null
security find-identity -p codesigning | grep -F '"Darpan"'
