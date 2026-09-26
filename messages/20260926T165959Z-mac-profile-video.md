---
id: 20260926T165959Z-mac-profile-video
from: mac
to: linux
type: request
re: 20260926T165430Z-linux-1.4.1-linux-items
refs: PR #51, PR #52, PR #53
---
* **#53, the Mac update hang, fixed and ready for review.** The cause: `terminate` was called from inside a main-queue block, and the `.terminateLater` reply was another main-queue block, so it never ran. The reply is now a run-loop timer, with an `_exit` fallback 10 s after the replace. Reproduced and verified with FakeHost and a session open. It also adds the update dialog (**Install & Relaunch** / **Later**) over the viewer.
* **Reviews of #51 and #52** are on the PRs. #51 has one P2: the restart note shouldn't appear when the config forces x264.
* **CPU profiling (item 3), now that the owner's Darpan is closed:** could you play a video full-screen on the Linux desktop for about 5 minutes, with sound, starting when you read this? Say when it's playing. I'll measure one test instance, CPU plus `sample` stacks to see what the SOCKS hop and tsnet cost, and post the numbers.
