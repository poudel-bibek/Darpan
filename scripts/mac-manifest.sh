#!/usr/bin/env bash
# The Mac app's update manifest for a release: darpan-mac.json, and darpan-mac.json.sig with an Ed25519
# signature over its exact bytes (base64). The app verifies it with its built-in public key before it
# parses anything. Upload both next to Darpan.dmg.
# Usage: scripts/mac-manifest.sh <Darpan.dmg> <version> <build> <out-dir>
set -euo pipefail
dmg=$1 version=$2 build=$3 out=$4
key=${DARPAN_MANIFEST_KEY:-$HOME/.config/darpan-release/mac-manifest-ed25519.pem}
repo=${DARPAN_REPO:-$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')}
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "can't tell the GitHub repository (set DARPAN_REPO=owner/name)"; exit 1; }
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $build =~ ^[0-9]+$ ]] || { echo "version like 1.3.0, build a number"; exit 1; }
sha=$(sha256sum "$dmg" | cut -d' ' -f1)
mkdir -p "$out"
printf '{"version":"%s","build":"%s","url":"https://github.com/%s/releases/download/v%s/Darpan.dmg","sha256":"%s","min_macos":"14.0"}\n' \
    "$version" "$build" "$repo" "$version" "$sha" > "$out/darpan-mac.json"
openssl pkeyutl -sign -inkey "$key" -rawin -in "$out/darpan-mac.json" | base64 -w0 > "$out/darpan-mac.json.sig"
openssl pkeyutl -verify -pubin -inkey <(openssl pkey -in "$key" -pubout) -rawin -in "$out/darpan-mac.json" \
    -sigfile <(base64 -d "$out/darpan-mac.json.sig") >/dev/null
echo "wrote $out/darpan-mac.json and darpan-mac.json.sig"
