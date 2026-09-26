# Working on Darpan

Guidelines for everyone who changes this repository, agents and humans alike.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

- **State assumptions explicitly.** If you're unsure, ask rather than guess.
- **Present multiple interpretations.** Don't pick one silently when there's ambiguity.
- **Push back when warranted.** If a simpler approach exists, say so.
- **Stop when confused.** Name what's unclear and ask for clarification.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If 200 lines could be 50, rewrite it.

**The test:** would a senior engineer say this is overcomplicated? If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match the existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it; don't delete it.

When your changes create orphans:

- Remove imports, variables and functions that *your* changes made unused.
- Don't remove pre-existing dead code unless asked.

**The test:** every changed line should trace directly to the request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

| Instead of… | Do this |
|---|---|
| "Add validation" | Write tests for invalid inputs, then make them pass |
| "Fix the bug" | Write a test that reproduces it, then make it pass |
| "Refactor X" | Make sure the tests pass before and after |

## Project rules

* **Pull requests, with bounded reviews.** Every code or docs change goes through a PR. It gets
  **one** automated review (Codex, on opening) and **one** review by the other agent. Fix P0 and P1
  findings. Fix P2 findings only if they are cheap and in scope; answer the rest in one line
  ("won't fix: …" or "follow-up"). **Don't request another review round:** verify fixes with tests,
  then merge. Nits and new ideas go into a follow-up, not the PR under review.
* **Merging.** Merge locally with a merge commit (`Merge #N: <title>`), made as the GitHub no-reply
  identity, then push. A merge on the GitHub website can record the account's real e-mail address.
  Delete the branch once it's merged.
* **Board messages** (`dev-messageboard/`) go straight to `main`; see its README.
* **Privacy.** No personal data anywhere: names, e-mail addresses, account, machine or tailnet
  names, IP addresses, home paths. Run `scripts/check-private-data.sh` before every commit. Commit
  as the GitHub no-reply address.
* **Efficiency.** Zero work while nobody is connected. Measure before claiming a number.
* **Tests.** Host: `python3 linux/tools/test_host.py` and `node linux/tools/webclient_test.mjs`. They
  run on a private Xvfb display, never on the real desktop. Mac: `swift run SelfTest` in `mac/`.
