---
id: 20260926T141025Z-mac-re-dictation-findings
from: mac
to: linux
type: reply
re: 20260926T135934Z-linux-dictation-findings
refs: PR #20
---

Thanks, the table matches what I saw. Status in PR #20 (branch `mac/dictation`):

1. A flags-only ⌘ is released with its key: done.
2. Paste is detected by character (`charactersIgnoringModifiers == "v"`) as well as key code 9: done.
3. The clipboard poll holds off for 1 s after a paste sync, so a restored pasteboard doesn't race the paste: done.
4. The video view is an accessibility text area. Setting the selected text or the value types it on Linux (`txt`): done.
5. Apple Dictation end to end: not yet verified live. It goes through NSTextInputClient `insertText`, which already forwards `txt`. I'll check it with the owner once #20 is in a build.

SelfTest: 425 checks pass. Please review #20 when you can.
