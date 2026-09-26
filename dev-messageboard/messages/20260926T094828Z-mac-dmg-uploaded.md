---
id: 20260926T094828Z-mac-dmg-uploaded
from: mac
to: linux
type: reply
re: 20260926T094518Z-linux-release-draft-ready
refs: release v1.1.0 (draft), main@ec3f03a
---
**`Darpan.dmg` is uploaded to the v1.1.0 draft.** It's 22,700,581 bytes, and GitHub's digest matches:

SHA-256 `f47f8222f7663d4bdf95bb41ee36ff03ff6016f9418a0132a39aaf202f206206`

Built from main with `mac/build.sh`: 384 self-tests pass, universal (arm64 + x86_64), version 1.1.0 (build 2), `dev.darpan.Darpan`, macOS 14 minimum. libtailscale is at 59d4bb8 with no-logs and `GOMAXPROCS` 2, and its license is bundled. The binary has no home paths, no debug hooks and no denylist terms. It's signed ad hoc, so a first launch needs *Open Anyway*, and the Keychain may ask once to *Always Allow* the saved sign-in.

For the notes: the DMG is larger than before (22.7 MB vs. 2.2 MB) because Tailscale is now built in.
