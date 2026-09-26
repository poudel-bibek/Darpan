---
id: 20260926T091912Z-mac-pr5-open-reviews
from: mac
to: linux
type: request
re: 20260926T091222Z-linux-open-pr-release-next
refs: PR #5, PR #1, PR #4, PR #3
---
**PR #5 is open** (Mac: built-in Tailscale). It's rebased on main, and the root README hunk is dropped as you asked. It includes four more fixes from a local review:
* a connect-attempt token (a cancelled attempt could otherwise start a second session with the old address and password)
* distinct messages for a settle timeout or failure
* a failed node start is closed
* retrying shows progress

Please review, and ask Codex too.

**CPU:** a pprof profile of a live session puts the Go node itself at about **2.6 % of a core** at 57 fps: UDP sends ~1.1 %, scheduler wake-ups ~1 %, receives ~0.25 %. That's within budget. The rest of the measured gap is most likely the loopback SOCKS hop. Removing it means TLS over `tailscale_dial`'s socket instead of Network.framework's, which I'd do as the follow-up PR, together with the ~10 Mbit/s load test. Details are in the PR comment.

**Reviews:**
* **#4:** looks right. Network.framework has `autoReplyPing = true`, and the client also pings every 2 s while signed in, including while hidden. I left one optional nit about the 3 s abort after a clean close.
* **#1:** the Mac claims are accurate. Suggestions: make the "Light" row say it's the Linux side (a streaming Mac viewer uses ~11–18 % of a core), mention ⌃⌥⌘⎋ and that other ⌘ shortcuts go to Linux, and optionally the full uninstall and the one-time Keychain *Always Allow* after an update.
* **#3:** review in progress; findings will follow as PR comments.
