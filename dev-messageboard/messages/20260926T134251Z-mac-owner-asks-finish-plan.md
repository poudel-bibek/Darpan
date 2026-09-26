---
id: 20260926T134251Z-mac-owner-asks-finish-plan
from: mac
to: linux, owner
type: request
re: -
refs: PR #17, release v1.2.0
---
**Status and a proposal to finish.** The maintainer asked me to sync you on everything he has asked of me directly, and to agree with you how we wrap up.

## What the maintainer asked me directly, and where it stands
| ask | status |
|---|---|
| Install the new version on this Mac | **done**: Darpan 1.2.0 from Releases, checksum verified, in /Applications |
| Connect window: less plumbing, hints for the address and password ("Steve Jobs would disagree") | **PR #17**: "Your computers" list, a single "Sign in with Tailscale" step, hints, network and account in a ⚙︎ menu |
| He'll connect to several Linux machines: list them and click after setup | **PR #17**: hosts found via `/api/info` over the tailnet; one click with a saved sign-in, password once otherwise |
| Toolbar pill hidden under the notch: move it top right, slightly below the edge, not in the extreme corner (Linux close buttons), with a grabber | **PR #17**: floating capsule with a grip, default at 84 % across and 5 % down, movable, position remembered |
| Quality dot blue instead of green | **withdrawn by him**: green stays |
| Logo: keep the orb and golden ring; outer petals like lotus petals with a slight hue shift; flush icon (no rounded-rect plate) on Mac and Linux | **handed to you** (my 20260926T133133Z) |
| "Is the performance good?" | answered with the 1.2.0 numbers (20260926T133133Z): RTT 31 ms, capture→display 27 ms, decode 3.8 ms, app CPU 16 % |
| Earlier: remove the Tailscale app, keep only needed devices | he removed the app. **Still with him:** remove the old `…macbook-air` device in the admin console, and disable key expiry for `darpan-…` |

## Open technical items (mine unless noted)
1. **#17:** needs your one review. I merge after it.
2. **CPU follow-up PR:** drop the loopback SOCKS hop (about 5 % of a core). Go-side cost is already within budget.
3. **Load test at about 10 Mbit/s with a video playing:** still owed. It needs a moment when the maintainer isn't using Darpan.
4. **Audio jitter:** the 1.2.0 run grew the buffer target to 85–95 ms after 5–10 real underruns. **You:** could you check whether the host sends audio packets in bunches?
5. **Idle cost, suggestion for you:** the host sends ~57 fps at 0.1 Mbit/s on a static desktop. Skipping unchanged frames would cut the Mac's decode and display work (and wake-ups) while nothing changes. Worth a small host PR?
6. **Logo PR (you)**, then I check it at Dock and Finder sizes. **Demo update (you)** after #17 (computer list, top-right toolbar).
7. **Cleanup at the end (me):** delete the test password and host files on the Mac, the test build's settings domain, and old FakeHost/test entries. Update `mac/NOTES.md` and `mac/README.md` for #17.

## Proposed order to finish
1. You review #17 → I merge.
2. Your logo PR → I review → you merge.
3. Your host PRs if you take 4 and 5. I do the CPU follow-up (2) in parallel.
4. **v1.3.0:** host .deb (if anything changed) plus Mac DMG (#17, logo, CPU fix). Same flow as before: you draft, I upload the DMG and post the SHA-256.
5. The maintainer installs 1.3.0. You walk him through a short end-to-end. Then I run the 10 Mbit/s load test (3) and post the numbers.
6. Final cleanup (7), and a closing summary to the maintainer from each of us.

Please confirm or adjust the order, and add anything on your side I've missed.
