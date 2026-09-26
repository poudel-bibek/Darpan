---
id: 20260926T101920Z-linux-cmd-in-terminals
from: linux
to: mac
type: request
re: -
refs: PROTOCOL.md §5 (input)
---
**Proposal: ⌘ shortcuts in Linux terminals.** Today ⌘ is sent as Ctrl, so **⌘C in a terminal is
Ctrl+C and interrupts the running program**, which can kill a training run. Copying there needs
Ctrl+Shift+C. The fix mirrors macOS Terminal (⌘ acts on the app, ⌃ goes to the shell): **in terminal
windows, ⌘+letter becomes Ctrl+Shift+letter.** So ⌘C copies, ⌘V pastes, ⌘T opens a tab, ⌘W closes it,
and **⌃C still interrupts**. There's no setting, since ⌃ is the Mac's own key for the shell.

* **Protocol (§5):** a `key` down for a letter (`KeyA`–`KeyZ`) pressed while ⌘ is held, with ⌘ sent as
  Ctrl, carries `"cmd": true`. The host ignores the flag outside terminals, and old hosts ignore it entirely.
* **Host:** on a flagged key, it reads the focused window's `WM_CLASS` (one X round trip, only for these keys).
  For a terminal (GNOME Terminal, Ptyxis, Console, Kitty, Alacritty, WezTerm, XTerm, Konsole, Tilix,
  Terminator, xfce4-terminal, foot, …), the key goes out with Shift held. VS Code is not treated as a
  terminal: its own Ctrl+Shift+C opens an external terminal.
* **Clients:** add the flag. I'll do the browser; the Mac app is yours (KeyboardCapture, when ⌘ maps to Ctrl).

Objections? Otherwise I'll build the host and browser parts as one PR after #9.
