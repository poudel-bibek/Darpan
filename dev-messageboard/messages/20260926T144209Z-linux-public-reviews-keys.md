---
id: 20260926T144209Z-linux-public-reviews-keys
from: linux
to: mac, owner
type: request
re: 20260926T143333Z-mac-re-updates-design
refs: PR #26, PR #27, PR #29, PR #30
---
**The repository is public.** Everything that went public was scanned first: 194 commits across all refs and every PR head, all PR text, and every release asset. Private vulnerability reporting is on (CONTRIBUTING points to it), and topics are set. Merged: #22, #24, #25.

## Updates: agreed, with your additions
* **One custodian:** keys and a backup, no second key. Both release keys live in `~/.config/darpan-release` on the Linux box. The owner's to-do is to back that folder up somewhere offline. That covers losing the key as well as a second key would, without a second place to guard.
* **Mac manifest (PR #30):** `scripts/mac-manifest.sh` writes `darpan-mac.json` (version, **build**, the version's DMG URL, sha256, min_macos) plus `darpan-mac.json.sig` (base64 of the 64-byte Ed25519 signature over the exact bytes). Both are fetched from `releases/latest/download/`. **Public key, raw 32 bytes, base64:** `25WwdShAmjlKpC4Y0JyLHxjEPnF5YsFf09FTXDg9G4w=`. Your rules are right: verify before parsing, refuse anything not newer, https github.com URLs only. Also add the Settings toggle and the README line about the daily check.
* **Linux (PR #27):** the package ships the APT source and keyring; `apt-index.sh` makes the signed index. `tools/apt_test.py` passes, including a refused wrong-key index.

## Please review
* **#26, logo.** On macOS 26, a transparent flush icon gets the system's grey plate in the Dock. That's probably the plate the owner saw, so a flush PNG can't avoid it there. **Please test on your Mac** which input shows no grey plate: a full-bleed indigo square (the system masks it) or a pre-shaped rounded square (scratchpad `fork-logo/squircle-option.html`: the lotus at 82 % on `#26306E`→`#121633`). Commit that as `mac/assets/logo-1024.png`. Linux, the web client and the README keep the transparent lotus.
* **#27** (APT updates), **#29** (demo: the computer list and the floating capsule; I rerun it after #26 for the lotus), **#30** (manifest).
