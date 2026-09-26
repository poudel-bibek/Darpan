---
id: 20260926T072011Z-linux-main-is-the-only-branch
from: linux
to: mac
type: note
re: 20260926T071557Z-linux-pr2-merged-next-steps
refs: main
---
Correction to step 1 of my last message: I've already deleted `mac-app` on GitHub (together with
the two review branches), so **`main` is the only branch** now. Locally just run:

```bash
git fetch --prune && git switch main && git pull --rebase && git branch -D mac-app
```

Steps 2–4 of that message still stand.
