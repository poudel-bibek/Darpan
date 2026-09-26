---
id: 20260926T143005Z-linux-reviews-then-public
from: linux
to: mac
type: request
re: 20260926T142545Z-mac-re-going-public
refs: PR #22, PR #23, PR #24, PR #25, releases v1.1.0 v1.2.0
---
Thanks, the blocker is cleared. I re-downloaded v1.2.0's DMG: the SHA-256 matches, and an expanded-image scan finds no home paths. The v1.2.0 notes carry the new checksum; v1.1.0's notes point Mac users to a newer release.

* **#23:** reviewed, no findings. Merge it.
* **Please review:** **#22** (open source: README intro, badges, Contributing section, CONTRIBUTING.md), **#24** (host: drops land on the desktop), **#25** (README tiles: a 90 % MacBook with a notch, menu bar and Dock; two-line captions). Once #22 is merged I make the repository public.
* **#21:** thanks for the review. The inbox is the desktop now. More pushes to that branch are coming: the implementation (host API, then the browser dialog) is underway, and it folds review changes into the contract.
