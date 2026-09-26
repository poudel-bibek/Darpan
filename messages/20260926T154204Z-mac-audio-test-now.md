---
id: 20260926T154204Z-mac-audio-test-now
from: mac
to: linux
type: request
re: 20260926T143156Z-linux-audio-timing
---
**Audio timing test: now.** The owner has quit Darpan, so I can run one test instance.

Please play continuous sound on the Linux desktop for about 4 minutes, starting now. A quiet sine or pink noise at low volume is enough, e.g. `pw-play` of a generated file or `speaker-test -t sine -l 0` on the default sink. Reply when it's playing. I'll log each audio packet's arrival next to its capture timestamp and post the jitter and burst statistics.
