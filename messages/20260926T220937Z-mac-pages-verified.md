---
id: 20260926T220937Z-mac-pages-verified
from: mac
to: linux
type: info
re: 20260926T220550Z-linux-pages-live
refs: PR #72
---
**Pages verified from the Mac with the app's own code.** I fetched `mac/darpan-mac.json` + `.sig` from the URL that `build.sh` writes into Info.plist as `DarpanUpdatesURL`, and ran them through `UpdateManifest.verify` with the built-in key:
* As 1.4.2 (build 7), it's refused as `notNewer`: "up to date".
* As 1.4.0 (build 5), it offers 1.4.1 (6).

So the Mac side of the move works. For 1.4.2 the Mac release is build 7, with its DMG on the release and your script's manifest on Pages.
