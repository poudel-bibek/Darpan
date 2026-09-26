#!/bin/bash
# Builds libtailscale (tsnet as a C library, BSD-3) at a pinned commit into a universal static
# archive for the app: mac/.build/libtailscale/{libtailscale.a,tailscale.h,LICENSE}.
# Needs Go (on PATH or in ~/.local/go) and network access for the Go modules. Does nothing if
# the archive for this commit already exists.
set -euo pipefail

COMMIT=59d4bb82744915815178e0f0776d60026a397ee7   # tailscale.com v1.94.1
MAC="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$MAC/.build/libtailscale"
SRC="$OUT/src"

STAMP="$COMMIT nologs"
if [ -f "$OUT/libtailscale.a" ] && [ "$(cat "$OUT/commit" 2>/dev/null)" = "$STAMP" ]; then exit 0; fi

GO="$(command -v go || true)"
[ -z "$GO" ] && [ -x "$HOME/.local/go/bin/go" ] && GO="$HOME/.local/go/bin/go"
[ -n "$GO" ] || { echo "Go is needed to build libtailscale (https://go.dev/dl, or ~/.local/go)" >&2; exit 1; }

mkdir -p "$OUT"
if [ ! -d "$SRC/.git" ]; then git clone -q https://github.com/tailscale/libtailscale "$SRC"; fi
git -C "$SRC" fetch -q origin "$COMMIT" 2>/dev/null || git -C "$SRC" fetch -q origin
git -C "$SRC" checkout -q --detach "$COMMIT"

# Never upload logs to Tailscale (the host runs tailscaled --no-logs-no-support too). This has to be
# compiled in: the Go runtime copies the environment when the library loads, before the app runs.
cat > "$SRC/darpan_nologs.go" <<'GO'
package main

import (
	"tailscale.com/envknob"
	"tailscale.com/logtail"
)

func init() { envknob.SetNoLogsNoSupport(); logtail.Disable() }
GO

export CGO_ENABLED=1 GOTOOLCHAIN=local MACOSX_DEPLOYMENT_TARGET=14.0
for arch in arm64 amd64; do
    clangarch=$([ $arch = amd64 ] && echo x86_64 || echo arm64)
    (cd "$SRC" && GOOS=darwin GOARCH=$arch CC="clang -arch $clangarch -mmacosx-version-min=14.0" \
        CGO_CFLAGS="-mmacosx-version-min=14.0" "$GO" build -trimpath -buildmode=c-archive \
        -ldflags=-s -o "$OUT/libtailscale-$arch.a" .)
done
lipo -create "$OUT/libtailscale-arm64.a" "$OUT/libtailscale-amd64.a" -output "$OUT/libtailscale.a"
cp "$SRC/tailscale.h" "$SRC/LICENSE" "$OUT/"
echo "$STAMP" > "$OUT/commit"
echo "libtailscale $COMMIT → $OUT/libtailscale.a"
