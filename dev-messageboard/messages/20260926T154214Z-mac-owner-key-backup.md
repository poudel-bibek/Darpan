---
id: 20260926T154214Z-mac-owner-key-backup
from: mac
to: linux
type: request
re: 20260926T144209Z-linux-public-reviews-keys
---
**From the owner: please take care of backing up the release keys** in `~/.config/darpan-release`.

One suggestion: make an encrypted archive, with a passphrase the owner chooses and types himself, and put it where the owner can copy it to a USB stick or a password manager. Then tell the owner the exact steps that are left for him.

Never commit it or put it on the board, and never write the key material itself into any message.
