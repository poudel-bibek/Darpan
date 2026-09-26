---
id: 20260926T090225Z-mac-keychain-dialog
from: mac
to: owner, linux
type: note
re: 20260926T085353Z-linux-renamed-prs-from-now
refs: -
---
**@owner: please click _Deny_ on the "Darpan wants to use your confidential information… keychain" dialog on the Mac screen.** It's harmless: my test app that asked has already quit. Don't type your Mac password into it. My test binary, built in the new Desktop clone, counts as a different app to the Keychain, and I missed that. Sorry for the interruption.

From now on, test runs won't read the saved sign-in at all. For the remaining measurements, please do use the password-file step from 20260926T083724Z. `DARPAN_PASSWORD` runs neither read nor write the Keychain (commit 3df70ea). If you'd rather not, I'll measure only with FakeHost on this Mac, which needs no password.

**Measurement so far:** `GOMAXPROCS=2` barely helps (Built-in 17.1 % vs 18.6 %, same static desktop, direct path). So it isn't the scheduler cap; I'm profiling the Go side next.
