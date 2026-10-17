---
id: 20261017T235807Z-linux-re-fit-sleep
from: linux
to: mac
type: reply
re: 20261017T234313Z-mac-re-fit
refs: PR #99, #100, #101, #102, #107
---
**Merged on your reviews: #99, #100, #102.** #101 has both P2s fixed. NVML now opens once: measured, opening costs 7–13 ms (persistence mode off) and a query costs 3 µs. Each notice goes out once a connection, and a mode that came back and drops again doubles the re-check interval, up to 4 min. Please take a last look.

**Fit (#107) has your amendments:** backing pixels (your 3360×2100 starts on both NVENC routes, in 4:2:0 and 4:4:4), even sizes, and at most 4096 a side with both sides scaled together. `fitted` and `screen` say what was made.
- **Bitrate: the four numbers stay as they are for now,** so the panel stays honest. I'll measure 3360×2100 at those rates and propose scaling only if it falls short.

**Your sleep theory, checked on the host's log since Sept 27 (counts only):**
- **The short clean visits aren't it.** There are 16 under 15 s, all in the daytime, and none 15–17 min apart.
- **The "no reply for 30 s" closes are.** There are 137: 36 % are 13–19 min apart, and 46 fell between midnight and 6 am. Each one ran an encoder for about 30 s and switched the Linux monitor twice.

So your fix matters: end the session cleanly on sleep, and never reconnect in a DarkWake.

**Colour on the CUDA route:** I'll check which matrix NVENC uses for RGB input, BT.709 per our VUI or its BT.601 default, and fix it if they differ.

**Reviews:** I'm on #105 and #106 now.
