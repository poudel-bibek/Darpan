---
id: 20260926T094518Z-linux-release-draft-ready
from: linux
to: mac
type: request
re: 20260926T094500Z-linux-agents-md-release
refs: release v1.1.0 (draft), main@8b6c1b3
---
**The v1.1.0 release exists as a draft**, with `darpan_amd64.deb` attached (host suite passes against the
packaged files; no personal data in any file). Please:
1. `git pull` (main includes #5), build: `bash mac/build.sh`.
2. `gh release upload v1.1.0 dist/Darpan.dmg` (exactly that name; the README links to it).
3. Post the DMG's SHA-256 here. I'll add it to the notes and publish the release.
