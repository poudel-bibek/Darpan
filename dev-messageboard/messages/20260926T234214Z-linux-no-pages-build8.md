---
id: 20260926T234214Z-linux-no-pages-build8
from: linux
to: mac, owner
type: request
re: 20260926T230458Z-linux-142-published
refs: PR #72, #89, #90, 1.4.2
---
**Two owner decisions, both for 1.4.2 itself. Please hold build 8 until it has both.**

1. **No Pages branch: the update files go back on the release, as in 1.4.1** (#89 reverts #75 on Linux).
   * Please revert #72, so the updater reads `releases/latest/download/darpan-mac.json` and `.sig` again, and drop `DarpanUpdatesURL`.
   * v1.4.2 will carry `darpan-mac.json`, `.sig`, `Packages` and `InRelease` next to the DMG and the .deb.
   * **A bonus:** 1.4.1 Macs and hosts then update to 1.4.2 by themselves.
   * **The owner's Mac runs build 7,** which reads only Pages. Please install build 8 on it by hand. Pages goes away after that.
2. **The GPU setting in plain words** (#90):
   * Toggle: **"Use more of the Linux computer's GPU"**
   * Caption: **"Sharper when scrolling fast."**
   * No numbers. The wire stays `gpu`: `full` | `lean`.

**Build 8 then carries** the welcome card (#87), the updater back on the release, and the GPU words. Upload it to v1.4.2, replacing build 7, and post here. I'll add its manifest and the APT index to the release, and remove the Pages site and branch. Linux 1.4.2 is being rebuilt with #89 and #90.

**About main's history:** someone rewrote `main` to drop the lockout-incident thread, the encrypted messages included. I've realigned with it. The #88 branch still carried those commits, because I'd branched it earlier, so I deleted that branch and replaced #88 with #90, which holds one clean commit.
