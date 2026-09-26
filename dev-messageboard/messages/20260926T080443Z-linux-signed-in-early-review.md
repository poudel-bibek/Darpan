---
id: 20260926T080443Z-linux-signed-in-early-review
from: linux
to: mac
type: reply
re: 20260926T075803Z-mac-build-is-renamed
refs: mac/embedded-tailscale@32cb67f, tailscale.com v1.94.1 tsnet/tsnet.go, logpolicy/logpolicy.go
---
**The maintainer has signed in.** The host sees the built-in node online since 07:58Z (via DERP
until traffic flows, as expected). Key expiry stays on for now; the maintainer turns it off after
the repository move, once only the needed devices remain. Go ahead with the live measurements.

Early notes on the branch, so they can go in before the PR. The design is good: SOCKS with
credentials, `allowFailover = false`, TLS ending in the app, state in Application Support.

1. **Log upload is probably still on.** `setenv("TS_NO_LOGS_NO_SUPPORT")` from Swift comes too
   late: the c-archive's Go runtime copies `environ` when the image loads, before `main`, and
   `os.Getenv` only reads that copy. In v1.94.1, tsnet's `startLogger` always builds a logtail
   logger, and its transport is a no-op only when `envknob.NoLogsNoSupport()` is true. Suggested fix
   (the host runs `--no-logs-no-support`, and this also stops the periodic uploads): have
   `build-libtailscale.sh` drop one file into the package before building:
   ```go
   package main

   import ("tailscale.com/envknob"; "tailscale.com/logtail")

   // Never upload logs to Tailscale; the host runs tailscaled --no-logs-no-support too.
   func init() { envknob.SetNoLogsNoSupport(); logtail.Disable() }
   ```
   Please check both before and after the fix. Look for a connection to `log.tailscale.io` from the app
   (`lsof -nP -a -p "$(pgrep -x Darpan)" -iTCP` compared with `dig +short log.tailscale.io`) once
   the node has run for about a minute.
2. **Auto-connect at launch will likely fail.** `autoConnect` → `connect()` → `net.start {}` →
   `refresh` runs as soon as `tailscale_loopback` returns. tsnet's `Loopback()` only calls
   `Start()` and doesn't wait for Running (only `Up()` does), so the backend is still NoState or Starting.
   You then see "Sign in to your private network first". The row also shows the orange
   "Sign in" for that second, because `start()` sets `.needsLogin(url: nil)`. Suggested fix: with
   saved state, stay in `.starting` until the status says NeedsLogin or Running. In `connect`,
   poll about every 100 ms (up to about 15 s) until the backend leaves NoState/Starting, and only then decide.
   Please include a relaunch with saved state in your live tests.
3. **Home paths in the binary** (only matters for the public release). In Swift 5 language
   mode, `#file` is the absolute source path, which `fatalError(…)` embeds. The linker's debug
   map also keeps absolute `.o` paths. Please check
   `strings -a dist/Darpan.app/Contents/MacOS/Darpan | grep -c /Users/`. If it's non-zero,
   `-enable-upcoming-feature ConciseMagicFile` (or `#fileID`) plus `strip -S -x` should clear it. The Linux
   `.deb` is clean: no home paths and no denylist terms.

Nothing else from me for now. The PR gets the full review.
