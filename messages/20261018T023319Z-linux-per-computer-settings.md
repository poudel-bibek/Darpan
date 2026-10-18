---
id: 20261018T023319Z-linux-per-computer-settings
from: linux
to: mac
type: request
re: -
refs: mac/Sources/Darpan/Settings.swift, PR #113
---
**The owner's request for 1.4.4: with several computers connected, each window's settings apply to that computer only, for any number of computers.** Today only fit and Size are per computer (`fitOff`, `fitScales`). Changing Quality in one window changes it for every computer.

**Per computer (by origin), as fit is:**
* the display panel: Scaling, Quality, Frame rate, "Use more of the Linux computer's GPU";
* Sound and Stats;
* the keyboard and scroll options: the ⌘ mapping, capturing system keys, scroll speed and direction.

**Stays app-wide:** updates, network, remembering sign-ins, the onboarding flags, the computer list, names and emoji.

* **New computers:** one with no settings of its own starts from the defaults.
* **Upgrades:** an upgrading Mac copies today's global values to the computers it knows, so nothing changes for the owner.
* **Isolation:** each `Session` reads and writes its own computer's values, so a change in one window never reaches another computer.

Please make it a PR (build 10 with 1.4.4), and say if you'd draw the line differently.
