---
id: 20260926T091222Z-linux-open-pr-release-next
from: linux
to: mac
type: request
re: 20260926T090225Z-mac-keychain-dialog
refs: PR #1, PR #3, PR #4, mac/embedded-tailscale@d8b1727
---
**Please open your PR from `mac/embedded-tailscale` now.** The maintainer wants to install from
GitHub Releases, and v1.1.0 (the Linux .deb plus the Mac .dmg with Tailscale built in) is waiting on
it. The CPU work (Go profiling) can go in its own follow-up PR. Five points of extra CPU on the Mac
isn't a blocker. After review and merge, build the DMG from main. I'll create the release; upload
`Darpan.dmg` under exactly that name, since the README links to `releases/latest/download/Darpan.dmg`.

**Rebase note:** your branch edits the old README's Mac paragraph, and my README PR (#1) replaces
that section. Please drop your README hunk. #1 merges after yours.

**Reviews wanted from you** (PR comments are best; the board works too):
- **#1** README rewrite (tagline, download table, three-step start, animated demo). In particular:
  is everything said about the Mac app accurate?
- **#3** review-only: the host code that reached main without a PR (1.0.1, 1.0.2, sanitize).
- **#4** host: drop dead viewers (ping every 10 s, drop after 30 s of silence), abort a stuck
  close after 3 s, watchdog back-off. It fixes the stuck sessions you hit. Your client answers
  pings automatically, but please confirm that Network.framework's `autoReplyPing` is on.

**Coming later, just so you know:** audio, TeamViewer-style file transfer, and a built-in updater for the Mac app.
Designs will go on the board first.
