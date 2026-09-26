#!/bin/bash
# Builds dist/Darpan.app and dist/Darpan.dmg (universal: arm64 + x86_64) with the Command Line
# Tools and Go: libtailscale, self-tests, per-architecture release builds joined with lipo, the
# app bundle and its icon, signing, the disk image. Go comes from PATH or ~/.local/go.
#
#   bash mac/build.sh
#
# Signing: with the "Darpan" identity from make-signing-identity.sh (hardened runtime), or
# DARPAN_SIGN_ID="Developer ID Application: …"; otherwise ad hoc.
set -euo pipefail

MAC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$MAC")"
DIST="$ROOT/dist"
NAME=Darpan
VERSION=$(sed -n 's/.*static let string = "\(.*\)"/\1/p' "$MAC/Sources/DarpanCore/Auth.swift")   # DarpanVersion
BUILD=6
APP="$DIST/$NAME.app"
# The GitHub repository ("owner/name") whose releases the app updates from.
REPO=${DARPAN_REPO:-$(git -C "$ROOT" remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')}
[[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "can't tell the GitHub repository (set DARPAN_REPO=owner/name)"; exit 1; }

cd "$MAC"

echo "==> libtailscale"
bash "$MAC/tailscale/build-libtailscale.sh"

echo "==> self-tests"
swift run -c release SelfTest

echo "==> release builds"
# No build machine paths in the binary: #file strings and debug info name paths relative to the
# repository, and the symbol table (with its object file paths) is stripped.
MAP=(-Xswiftc -file-prefix-map -Xswiftc "$ROOT/=" -Xcc "-ffile-prefix-map=$ROOT/=")
BINS=()
for arch in arm64 x86_64; do
    swift build -c release --arch "$arch" --product "$NAME" "${MAP[@]}"
    BINS+=("$(swift build -c release --arch "$arch" --show-bin-path "${MAP[@]}")/$NAME")
done

echo "==> $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/$NAME"
lipo -info "$APP/Contents/MacOS/$NAME"
strip -S -x "$APP/Contents/MacOS/$NAME"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>dev.darpan.Darpan</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>DarpanRepository</key><string>$REPO</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSHumanReadableCopyright</key><string>Darpan — remote desktop for your Linux computer</string>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null
cp "$MAC/.build/libtailscale/LICENSE" "$APP/Contents/Resources/libtailscale-LICENSE.txt"

echo "==> icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$MAC/assets/logo-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$MAC/assets/logo-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

echo "==> signing"
# A stable identity keeps the app's designated requirement the same from one release to the next,
# so the Keychain's "Always Allow" survives updates. DARPAN_SIGN_ID names a Developer ID
# certificate; otherwise the self-signed "Darpan" code-signing certificate in this Mac's keychain
# is used if there is one (it needs no trust setting to sign); otherwise the app is signed ad hoc.
SIGN_ID=${DARPAN_SIGN_ID:-Darpan}
if security find-identity -p codesigning | grep -qF "\"$SIGN_ID\""; then
    TS=--timestamp=none
    [ -n "${DARPAN_SIGN_ID:-}" ] && TS=--timestamp          # Apple's timestamp service is for Apple-issued certificates
    codesign --force --deep --options runtime $TS -s "$SIGN_ID" "$APP"
else
    echo "no \"$SIGN_ID\" code-signing certificate; signing ad hoc"
    codesign --force --deep -s - "$APP"
fi
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /designated requirement: /p'
codesign --verify --deep --strict "$APP"
if grep -rlaF /Users/ "$APP"; then echo "the app contains a home path"; exit 1; fi

echo "==> $DIST/$NAME.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# The window: icon positions and the one-time "Open Anyway" steps (assets/dmg/make.py).
cp "$MAC/assets/dmg/How to open Darpan.png" "$STAGE/"
cp "$MAC/assets/dmg/DS_Store" "$STAGE/.DS_Store"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$NAME.dmg" >/dev/null
rm -rf "$STAGE"

echo
echo "$DIST/$NAME.dmg"
shasum -a 256 "$DIST/$NAME.dmg"
