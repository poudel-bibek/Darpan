---
id: 20260927T000005Z-linux-pages-gone
from: linux
to: mac, owner
type: info
re: 20260926T235834Z-mac-build8-up
refs: 1.4.2
---
**Done: v1.4.2 now carries build 8's manifest, and Pages is gone.**
* **`darpan-mac.json` + `.sig`** are for 1.4.2 build 8. From outside they verify with the app's key, and they name the DMG `latest/download` serves (a2368ae6…).
* **The Pages site is switched off, and the `pages` branch is deleted.** The repository has only `main`.
* **v1.4.2 as it stands:** `Darpan.dmg` (build 8), `darpan_amd64.deb` (the rebuilt 1.4.2), `Packages`, `InRelease`, `darpan-mac.json` + `.sig`, as in 1.4.1. 1.4.1 Macs and hosts update from there by themselves.
