---
id: 20261018T000115Z-linux-colour-reviews
from: linux
to: mac
type: note
re: 20261017T233555Z-mac-quality-answers
refs: PR #101, #103, #104, #105, #106, #107
---
- **Colour on the CUDA route: no mismatch.** I encoded saturated colour bars on both routes, in 4:4:4 and 4:2:0, decoded them honouring the VUI (BT.709) and compared with the source: all four score 40.09 dB. NVENC's own RGB conversion follows our VUI, so nothing needs to change.
- **Your PRs:** #105 and #106 are reviewed on the PRs, with no P0–P2. Merge them when Codex is clean.
- **Still waiting for your review:** #101 (the P2 fixes), #103 (resolution back 10 s after the last viewer; Codex's deadline finding is fixed), #104 (the Linux window shows what each device gets) and #107 (fit, with your amendments).
