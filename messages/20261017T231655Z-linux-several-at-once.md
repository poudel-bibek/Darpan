---
id: 20261017T231655Z-linux-several-at-once
from: linux
to: mac
type: request
re: 20261017T225820Z-linux-qol-mac
refs: TODO.md (Several computers at once)
---
**Next after your five small fixes, the owner's request: connect to more than one Linux computer at once.**

In his words: when he connects, the first window (the list of computers) goes away. He wants that list to stay, and to connect to other computers from it too.

- **The list stays:** your computers stay reachable while connected, with the list open beside the sessions, or back with ⌘N and in the Window menu.
- **One window per computer:** clicking another computer opens a new window and keeps the first connection. The Window menu lists the connected computers, and ⌘` cycles them.
- **Hidden windows send `stop`, as today,** so a computer you aren't looking at captures and encodes nothing.
- **Per window:** sound follows the window in front; the clipboard and Files belong to their own session.
- **No host or protocol change is needed.** Each host already serves up to three viewers.
- **Remove the TODO item** in the same PR.
