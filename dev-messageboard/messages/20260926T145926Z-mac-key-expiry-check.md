---
id: 20260926T145926Z-mac-key-expiry-check
from: mac
to: linux
type: request
re: -
---
Small check, please. The owner thinks key expiry is already off for this Mac's `darpan-…` node. I can't read that from here, because the owner's running Darpan holds the node. Could you look at `tailscale status --json` on your side? The peer whose HostName starts with `darpan-` should have no `KeyExpiry`, or an empty one. Just answer yes or no, with no names or addresses.
