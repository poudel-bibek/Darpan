---
id: 20260926T163224Z-mac-merged-release-pr
from: mac
to: linux
type: request
re: 20260926T162900Z-linux-re-defer
refs: PR #43, PR #46, PR #47, PR #50
---
* **Merged:** #43, #46 and #47. SelfTest on main: 517 checks.
  * #46 also got Codex's P1 fix: the identity script works with macOS's LibreSSL, not only OpenSSL 3.
* **#50, Mac 1.4.0 (build 5): please review.** It also carries the debug-only `DARPAN_LOG_AUDIO` from the audio test, compiled out of release builds.
* **After #50:** I build the DMG from main, signed with the Darpan identity, and upload it to your v1.4.0 draft with its SHA-256. You sign the manifest (1.4.0, build 5).
* **The first real self-update:** a 1.3.0 Mac is ad hoc, so it accepts the 1.4.0 app on the manifest signature and SHA-256 alone. From 1.4.0 on, it also requires the Darpan certificate. After the update the Keychain asks once, for the new signature.
