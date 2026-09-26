#!/usr/bin/env bash
# Builds <repo>/dist/darpan_<version>_amd64.deb
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=$PWD
VERSION=$(python3 -c 'import sys; sys.path.insert(0, "."); from darpan import config; print(config.VERSION)')
TSVER=1.102.4
mkdir -p ../dist
OUT=$(cd ../dist && pwd)/darpan_${VERSION}_amd64.deb

echo "== native capture/encoder"
make -s -C native

echo "== Tailscale $TSVER (official static build, checksum-verified)"
TGZ=packaging/cache/tailscale_${TSVER}_amd64.tgz
mkdir -p packaging/cache
[ -f "$TGZ" ] || curl -fsSL -o "$TGZ" "https://pkgs.tailscale.com/stable/tailscale_${TSVER}_amd64.tgz"
SUM=$(curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TSVER}_amd64.tgz.sha256" || true)
if [ -n "$SUM" ]; then echo "$SUM  $TGZ" | sha256sum -c --quiet -; else echo "  (offline: using cached tarball)"; fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
R=$STAGE/root
install -d -m 0755 "$R/DEBIAN" "$R/opt/darpan/darpan" "$R/opt/darpan/native" "$R/opt/darpan/web" \
    "$R/opt/darpan/tailscale" "$R/usr/bin" "$R/usr/lib/systemd/user" "$R/usr/share/applications" \
    "$R/usr/share/icons/hicolor/scalable/apps" "$R/usr/share/doc/darpan"
install -m 0644 darpan/*.py "$R/opt/darpan/darpan/"
install -m 0755 native/darpan-capture "$R/opt/darpan/native/"
install -m 0644 web/index.html web/app.js web/style.css web/favicon.svg web/manifest.webmanifest "$R/opt/darpan/web/"
tar -xzf "$TGZ" -C "$STAGE"
# only the daemon: the host drives it through its LocalAPI, so the 33 MB CLI isn't needed
install -m 0755 "$STAGE/tailscale_${TSVER}_amd64/tailscaled" "$R/opt/darpan/tailscale/"
install -m 0755 packaging/darpan "$R/usr/bin/darpan"
install -m 0755 packaging/darpan-migrate "$R/opt/darpan/migrate"
install -m 0644 packaging/systemd/*.service packaging/systemd/*.socket "$R/usr/lib/systemd/user/"
install -m 0644 packaging/dev.darpan.Darpan.desktop "$R/usr/share/applications/"
install -m 0644 ../logo.svg "$R/usr/share/icons/hicolor/scalable/apps/darpan.svg"
install -m 0644 packaging/debian/copyright "$R/usr/share/doc/darpan/copyright"
install -m 0644 ../PROTOCOL.md "$R/usr/share/doc/darpan/"
[ -f ../README.md ] && install -m 0644 ../README.md "$R/usr/share/doc/darpan/README.md"
install -m 0755 packaging/debian/postinst packaging/debian/prerm packaging/debian/postrm "$R/DEBIAN/"
SIZE=$(du -sk --exclude=DEBIAN "$R" | cut -f1)
sed -e "s/@VERSION@/$VERSION/" -e "s/@SIZE@/$SIZE/" packaging/debian/control.in > "$R/DEBIAN/control"
find "$R/opt/darpan/darpan" -name __pycache__ -prune -exec rm -rf {} +
( cd "$R" && find . -type f ! -path './DEBIAN/*' -printf '%P\0' | xargs -0 md5sum ) > "$R/DEBIAN/md5sums"
chmod 0644 "$R/DEBIAN/control" "$R/DEBIAN/md5sums"

echo "== packaging"
dpkg-deb --root-owner-group -Zxz --build "$R" "$OUT" >/dev/null
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
