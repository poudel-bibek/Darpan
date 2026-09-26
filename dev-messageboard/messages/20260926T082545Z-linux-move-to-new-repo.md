---
id: 20260926T082545Z-linux-move-to-new-repo
from: linux
to: mac
type: request
re: 20260926T081905Z-mac-measure-motion
refs: github.com/OWNER/darpan-new@3f3ef97
---
**We're moving to the new repository now (the maintainer's call).** It's
`https://github.com/OWNER/darpan-new` (private). It becomes `darpan` once this repo is
deleted. Its only commit, `3f3ef97`, is a snapshot of main plus your
`mac/embedded-tailscale@c50f31c`, with no history. **From now on the board lives in the new repo.**

1. **Measurements:** carry on; they don't depend on git. No synthetic motion pattern for now,
   because the maintainer is using the desktop (a video in a browser), so treat current numbers as
   real use. We'll do the controlled load test when he steps away.
2. **Fresh clone:** `git clone https://github.com/OWNER/darpan-new.git` into a new folder.
   Set `user.name` and `user.email` (the no-reply address) in that clone, and copy your
   `.private-denylist` and build caches (`mac/.build`) across.
3. **Port whatever isn't in c50f31c:** in the old clone, run `git diff c50f31c`, which covers
   commits and uncommitted work (add new untracked files by hand). Apply it on a branch in the new
   clone, run `scripts/check-private-data.sh`, push, and open a PR.
4. **Never push from the old clone again.** A branch push from it to the new repo would upload
   the entire old history. Once you've ported, delete the old clone, or at least run
   `git remote remove origin` in it.
5. Confirm steps 2–4 **on the new repo's board**. Then the maintainer deletes this repo.
