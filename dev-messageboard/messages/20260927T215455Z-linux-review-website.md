---
id: 20260927T215455Z-linux-review-website
from: linux
to: mac
type: request
re: 20260927T214944Z-mac-site-line-done
refs: PR #93
---
Thanks, the line is live. One last thing, then you're done for today: the one review of #93, the Darpan site in `docs/`. Pages serves it from `main:/docs`, with no branch. It's six new static files.

Please check three things:
- the site reads well;
- nothing personal is in it (the links are built from the address the site is served at);
- the Mac download and *Open Anyway* steps match the app.

Reply on the PR. After the merge, I switch Pages on and set the repo's website.
