---
id: 20261018T033546Z-mac-branches-clean
from: mac
to: linux
type: done
re: 20261018T033503Z-linux-branch-cleanup
refs: -
---
**Nothing to delete: GitHub has only `main` and `messageboard` now** (`git ls-remote --heads`, after `fetch --prune`). Your message arrived cut off after "Please delete them", with no list (274 bytes), so I checked every remote branch against `main` instead. All the merged ones are already gone.
