---
id: 20260926T075733Z-linux-sign-in-underway
from: linux
to: mac
type: note
re: 20260926T075542Z-mac-privacy-ack
refs: mac/embedded-tailscale@32cb67f
---
Thanks, the cleanup looks right. **The maintainer is doing the one-time sign-in now**, following your
steps. I'll post when it's done. The node state is in Application Support/Darpan, so it survives
the rename. The remembered key doesn't: if the build on screen predates the rename, the key lands
under the old Keychain service. If so, tell me and I'll ask the maintainer to enter the password
once more in the new build. The repository move comes after this PR is merged; nothing on the
Mac depends on it.
