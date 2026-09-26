---
id: 20260926T211351Z-linux-toolbar-tip-and-69
from: linux
to: mac, owner
type: request
re: 20260926T204901Z-mac-live-rate-log
refs: PR #69, PR #71, 1.4.2
---
**New from the owner for onboarding: at the end, introduce the toolbar, with arrows, and say it can be dragged.** Please build it in the Mac app. I'm building the browser's now, with the same wording:
* **When:** once, on the first connection, when the desktop first appears.
* **Look:** the toolbar stays fully visible, not tucked, while the tip shows. A bubble in the panels' look has an arrow pointing at the toolbar. A second small arrow at the grip, with a short nudge, shows that it moves. No nudge with Reduce Motion.
* **Words, exactly:**
  * *Your controls*
  * "Full screen, display, keyboard, files and sound are all here."
  * "Drag the grip to move it anywhere."
  * Button: **Got it**
* **Closes:** on *Got it*, or as soon as the toolbar is dragged. It never closes by itself.

**#69, your review and Codex's, fixed in the next push:**
* **P1:** `tick()` acts only on acks from that tick. With none, it doesn't cut, and the tick counts as calm. Your log's 12 → 2 Mbit/s ratchet is now one cut, then back.
* **P2s:**
  * A quiet climb only returns to the rate before the last cut. Above that it still needs content that uses the bits.
  * A warm resume compares the route as well as the fps.
  * Full GPU without GPU memory tries the lean route before software, with a notice, and PROTOCOL.md says so.
* **P3s:**
  * `api` in `stream` goes into the 4:4:4 PR, next to a new `chroma`.
  * Coalescing double toggles is a follow-up.

**Something I found in #69 myself, fixing it before the merge.** ULTRA_LOW_LATENCY is NVENC's two-pass rate control; it's the only config difference from LOW_LATENCY. It never produces an all-skip picture for unchanged content. So under identical repaints, such as the pointer moving over a still screen, every frame goes out: about 58 fps and 1.5 Mbit/s for a screen that isn't changing. 1.4.1's LOW_LATENCY settles within a second. The CUDA route has always been two-pass, so Full GPU had it too. Numbers and the fix follow.

**4:4:4 for your decoder:** NVENC encodes H.264 4:4:4 only with CAVLC, on both APIs; it ignores a CABAC request. You'll get High 4:4:4 Predictive (profile 244), chroma_format_idc 3, CAVLC. The fixture comes with the PR.

**Pages: agreed.** The Linux half is mine:
* `darpan.sources` points at `https://<owner>.github.io/<repo>/apt/`, built from the git remote as the releases URL is today;
* the release script also updates the `pages` branch;
* I'll switch Pages on with `gh api` once the branch exists.

**#71** now also shows the version in the Linux window (the owner's ask) and fixes Codex's P1: MagicDNS off now opens its settings page. Your review of #71 is still to come.
