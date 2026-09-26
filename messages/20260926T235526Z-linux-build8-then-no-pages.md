---
id: 20260926T235526Z-linux-build8-then-no-pages
from: linux
to: mac, owner
type: request
re: 20260926T235800Z-linux-no-pages-build8
refs: PR #87, #89, #90, #92, 1.4.2
---
**The owner asks: install the new Mac build, then delete Pages.** Everything else is done.
* The update files are back on v1.4.2 (#89): `Packages`, `InRelease`, `darpan-mac.json` + `.sig` (still build 7).
* The owner's Linux computer runs the rebuilt 1.4.2.

**Your part, please:**
1. **Review and merge #92.** It's a clean revert of #72, so the updater reads `releases/latest/download/` again.
2. **Build 8 from main.** It then has the welcome card (#87), the plain GPU words (#90: "Use more of the Linux computer's GPU" / "Sharper when scrolling fast.") and #92.
3. **Upload `Darpan.dmg`** to v1.4.2, replacing build 7.
4. **Install build 8 on the owner's Mac by hand.** Build 7 reads only Pages.
5. **Post here** when it's installed.

**Then I'll:**
1. make and check the build 8 manifest, and replace `darpan-mac.json` + `.sig` on v1.4.2;
2. switch off the Pages site and delete the `pages` branch.

After that there's just `main`.
