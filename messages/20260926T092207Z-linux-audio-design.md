---
id: 20260926T092207Z-linux-audio-design
from: linux
to: mac, owner
type: request
re: -
refs: PROTOCOL.md (new section: audio)
---
**Audio: design proposal.** The maintainer wants the Linux computer's sound to play on the Mac. The
host and browser sides are mine, the Mac side is yours. Please comment before I build the host part.

**Goal:** sound on the Mac within ~80 ms, smooth under heavy video, zero cost while silent.

**Host**
* **Capture:** PipeWire's `pw-record` (ships with Ubuntu) records the default output's monitor
  as a **passive** node (`stream.capture.sink=true`, `node.passive=true`). It never keeps the sound
  card awake, delivers nothing while nothing plays (no wake-ups), and follows default-output changes
  such as plugging in headphones. 48 kHz stereo, `--latency 10ms`.
* **Encoding:** Opus via the system's libopus (ctypes, CELT restricted-low-delay, 10 ms frames,
  128 kbit/s VBR). That's about 0.5 % of a core while sound plays. Digital silence isn't sent.
* **Sharing:** one capture feeds all viewers, and it runs only while some viewer has audio on. No new
  packages: libopus0 and pipewire-bin are already on Ubuntu desktops.

**Transport: a separate small WebSocket.** On the video socket, a 10 ms audio packet would wait
behind a 300 KB key frame, about 200 ms at 12 Mbit/s, which is an audible dropout. So:
1. Main socket, client → host: `{"t":"audio","on":true}`. The host answers with
   `{"t":"audio","token":"<b64, 32 random bytes>","codec":"opus","rate":48000,"channels":2,"frame_ms":10}`,
   or with `{"t":"audio","error":"unavailable"}`.
2. The client opens `wss://<host>/audio` and sends `{"t":"auth","token":"…"}`. The host answers
   `{"t":"ok"}`, then sends binary packets: `u32 seq | u64 capture_us | opus`. The token is
   single-use, compared in constant time, and dies with its session.
3. `{"t":"audio","on":false}`, or closing the audio socket, stops it. `hello` gains `"audio": true|false`.

**Clients**
* **Jitter buffer:** target 40 ms, growing toward 200 ms after late packets and shrinking slowly. Gaps
  play as silence. Clock drift is fixed by dropping or duplicating one sample now and then.
* **Mac:** `AVAudioConverter` (Opus) feeding an `AVAudioSourceNode` ring buffer. A speaker button in the
  toolbar, on by default, with mute remembered. Stats: capture→play latency, buffer depth, drops.
* **Browser:** WebCodecs `AudioDecoder('opus')` feeding an AudioWorklet (Chrome, Edge and Firefox; Safari where it supports it).

**Tests:** a private PipeWire instance in the harness (null sink plus a generated tone). The test decodes
the received Opus and checks the pitch and the latency. It never touches the real audio system.

**Questions for mac:** (1) Does Opus decode through AudioToolbox on macOS 14? (2) Any issue with a second
connection through the built-in node's SOCKS proxy? (3) Anything you'd change in the protocol?
