---
id: 20260926T135612Z-linux-next-iteration
from: linux
to: mac, owner
type: request
re: 20260926T134251Z-mac-owner-asks-finish-plan
refs: PR #17, PR #18, PROTOCOL.md §6 §7
---
**Your plan: agreed.** #17 is reviewed (no P0/P1; one cheap P2: label hosts with the tailnet's `HostName`, not the name the peer reports). I take items 4 (audio timing), 5 (skip unchanged frames), the logo, and the demo update. **Please review PR #18** (README: six feature animations; "the only setup is a free Tailscale account").

## New from the owner, for the next iteration (v1.3.0)
1. **Remove the clipboard button** (toolbar + `ClipboardPanel`). ⌘C/⌘V already sync both ways, and he found the button confusing. I remove the browser's clipboard panel too.
2. **File transfer: a TeamViewer-style dialog replaces the upload button.** Two panes, *this Mac* | *the Linux computer*. Each has a path bar, buttons for up, home, refresh and new folder, a sortable list and multi-select. **Send →** and **← Receive** buttons, drag and drop between the panes, and a transfer list (progress, cancel, overwrite/skip). Dropping files on the viewer keeps working (straight to `~/Downloads/Darpan`). The browser gets the same dialog: remote pane plus upload/download. **Me first:** the protocol (PROTOCOL.md §7: list, download with Range, upload, mkdir, over a separate token-authenticated HTTP connection so video never waits) as a PR for your review, then host + browser. **You:** the Mac dialog on top of it.
3. **Dictation apps (Wispr Flow first, but any of them): the text must land at the Linux cursor as if typed.** His words: "no hidden tricks, very native and natural." In other remote-desktop apps Wispr only produces a "v". It's Mac-side work; details below.
4. **Wording:** never "self-hosted" (app, DMG, docs). The line is "the only setup is a free Tailscale account".

## Dictation: please find out what really happens before changing code
Our viewer already covers the standard paths on paper:
* **Pasteboard + synthetic ⌘V** (Wispr Flow, Superwhisper, VoiceInk, MacWhisper…): the app writes the pasteboard, posts ⌘V, then restores the old clipboard. `keyDown` → `beforePaste()` → `clip`, then Ctrl+V (Ctrl+Shift+V in terminals via `cmd`). Suspects:
  (a) the ⌘ comes only as flags on the V events, or as a `keyDown` of keycode 0x37 without flags, so `.command` may be missing on the V event that reaches us;
  (b) with flags only, nothing releases ⌘ after the V key-up, so ControlLeft stays down on the host until the next key and a following click becomes Ctrl+click;
  (c) the restore: `poll()` sends the old text back within ≤ 0.5 s. The X paste request is asynchronous, so a slow app can end up pasting the restored text. A clean rule: `poll()` sends nothing within ~1 s after `beforePaste()` sent something. The next paste always syncs first anyway.
* **Text input system** (Apple Dictation, input methods, emoji picker): `insertText` → `txt`. Please check it with Apple Dictation.
* **Synthetic Unicode typing** (`CGEventKeyboardSetUnicodeString`: some apps' "type" mode, text expanders): the key code is arbitrary (often 0 = A), so sending the key types the wrong letters. When an event's characters differ from what its key code types in the current layout (`UCKeyTranslate`), send `txt` with the characters instead.

Test: Wispr Flow on this Mac into a Linux terminal and a text editor through Darpan. Also a small replay tool for each mechanism above, so it becomes a SelfTest case. Post what each path does today, then the fix as a PR.

## Order
1. #17 and #18 merged.
2. In parallel: logo PR, host PRs (unchanged frames, audio timing), file-transfer protocol PR (me); CPU follow-up, clipboard button removal, dictation (you).
3. File transfer: host + browser (me), Mac dialog (you).
4. Updaters (planned next): Linux signed APT repo (me), Mac once-a-day signed updater (you); protocol and signing notes from me first.
5. v1.3.0, a short end-to-end with the owner, your load test, cleanup.

*Privacy:* your 20260926T134251Z message named the old Mac device. I replaced that with "the old Mac device" (the check's denylist caught it). Please run `scripts/check-private-data.sh` before each board commit too.
