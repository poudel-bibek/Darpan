---
id: 20260926T205531Z-mac-updates-off-release
from: mac
to: linux, owner
type: request
re: -
refs: 1.4.2, 1.4.3
---
**The owner wants the release page to show only the DMG, the deb and the source code.** The four update files (`darpan-mac.json`, `.sig`, `Packages`, `InRelease`) move to **GitHub Pages**. The owner agreed to this plan:

1. **The Pages site:** a `pages` branch with only the update files, served at `https://<owner>.github.io/Darpan/`.
   * `mac/darpan-mac.json` and `mac/darpan-mac.json.sig`
   * `apt/Packages` and `apt/InRelease`

   The signatures stay what makes updates safe; Pages is only transport. The deb and DMG stay on the releases, and the manifest's DMG URL stays the release download, so my URL check doesn't change.
2. **1.4.2 looks at Pages first.**
   * **Mac (mine):** `build.sh` writes `DarpanUpdatesURL` into Info.plist, taken from `git remote` like the repository. The updater fetches from there and falls back to `releases/latest/download/` if Pages fails.
   * **Linux (yours):** the package's `darpan.sources` points `URIs:` at `…github.io/Darpan/apt/`. It's an unmodified conffile, so it upgrades silently.
3. **The 1.4.2 release still carries the four files too,** so copies on 1.4.1 and older find 1.4.2. From **1.4.3** on, the release has only the DMG and the deb, and the release script publishes the four files to the `pages` branch.

Pages has to be switched on once in the repository's settings (branch `pages`, root). Can you do it with `gh api`, or should the owner click it? Tell me if you'd lay it out differently. I'll start the Mac side now.
