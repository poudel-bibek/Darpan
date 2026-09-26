# Darpan — wire protocol, version 1

This is the contract between the **host** (Linux machine being controlled) and any
**client** (the browser client served by the host, or a native macOS app).
Everything a client needs is in this file.

Design goals, in priority order: **low latency**, **low host overhead**, **security**,
simplicity. The host never queues video: if the network or the client falls behind,
the host encodes fewer frames instead of buffering stale ones.

---

## 1. Transport

* One **WebSocket** per client session, path **`/ws`**, plus an optional second one, **`/audio`**,
  for sound (§12).
  * Normal remote use: `wss://<host>.<tailnet>.ts.net/ws` (HTTPS terminated by Tailscale
    on the host, valid certificate).
  * On the host itself (testing): `ws://127.0.0.1:47470/ws`.
* The host serves the browser client at `/` over the same origin.
* File browsing and transfers are plain HTTPS requests under `/fs/` (§7.1).
* `GET /api/info` (no auth) returns JSON:
  ```json
  {"app":"darpan","ver":"1.0.0","proto":1,"host":"workstation",
   "url":"https://workstation.example.ts.net"}
  ```
  `url` is the canonical HTTPS address when known, else `null`.
* **Text frames** carry UTF-8 JSON objects. Every object has a string field `"t"` (type).
  Unknown `"t"` values and unknown fields MUST be ignored (forward compatibility).
* **Binary frames** start with a 1-byte kind:
  * `0x01` VIDEO (host → client)
  * `0x02` FILE_CHUNK (client → host)
  * `0x03` AUDIO (host → client, on `/audio` only)
* Max text message: 2 MiB. Max binary message: 8 MiB. Larger messages close the session.
* Clients SHOULD disable Nagle (TCP_NODELAY) where the platform allows it.

### Close codes

| code | meaning |
|------|---------|
| 4000 | protocol error |
| 4001 | authentication failed / locked out |
| 4002 | authentication timeout (no valid `auth` within 10 s) |
| 4003 | disconnected by the host user |
| 4004 | host shutting down / restarting |
| 4005 | too many sessions |

---

## 2. Authentication (challenge–response, the password never crosses the wire)

1. Immediately after the WebSocket opens, the host sends:
   ```json
   {"t":"hello","proto":1,"app":"darpan","ver":"1.0.0","host":"workstation",
    "kdf":{"alg":"pbkdf2-sha256","salt":"<base64>","iter":200000},
    "nonce":"<base64 of 32 random bytes>"}
   ```
2. The client derives the key and the proof:
   ```
   pw    = UTF-8 bytes of the password after Unicode NFC normalisation
   key   = PBKDF2-HMAC-SHA256(pw, base64decode(salt), iter, 32 bytes)
   proof = HMAC-SHA256(key, UTF-8("darpan-auth-v1") || base64decode(nonce))
   ```
   and sends
   ```json
   {"t":"auth","proof":"<base64 of proof>","client":"Chrome 131 on macOS","ver":"1.0.0"}
   ```
   `client` is a free-form human-readable description (shown in the host UI).
   All base64 in this protocol is standard base64 **with** padding.
3. Host replies either
   ```json
   {"t":"ok","sid":"<hex session id>","screen":{"w":2560,"h":1440},
    "codecs":["h264"],"caps":["clip","files","text","cursor","res","fs"],"url":"https://…",
    "enc":"nvenc","gpu":"NVIDIA GeForce RTX 4090"}
   ```
   or
   ```json
   {"t":"denied","reason":"password|locked|no_password|busy","retry":30}
   ```
   followed by close 4001. `retry` = seconds until another attempt is accepted.
* Brute-force protection: after 5 consecutive failures from one source the host locks that
  source out (30 s, doubling each time, max 1 h). There is also a global limit.
* **Remembering a device**: a client MAY store `key` (not the password) together with
  `salt` and `iter`, and reuse it while the host still sends the same `salt`+`iter`.
  If they change (the password was changed), the client must ask for the password again.
* Before `ok`, the host ignores every message except `auth`.

---

## 3. Video

### 3.1 Starting / stopping

Client → host:
```json
{"t":"start","codec":"h264","fps":60,"bitrate":0}
```
* `fps`: maximum frame rate (1–120, default 60). The host only sends frames when the
  screen actually changes, so a static screen costs ~0 bandwidth regardless.
* `bitrate`: maximum kbit/s; `0` = automatic (adaptive, the default).

Host → client, before the first frame of every new stream:
```json
{"t":"stream","id":3,"codec":"h264","w":2560,"h":1440,"fps":60,"enc":"nvenc"}
```
`id` (uint16) changes every time the encoder is (re)started. Frames whose stream id does
not match the latest `stream` message MUST be discarded. The first frame of every stream
is a key frame.

`{"t":"stop"}` pauses streaming: no more frames are encoded. The host keeps the encoder warm
for ~15 s (so `start` resumes instantly with a new `stream` id and a key frame) and then tears
it down completely. Clients SHOULD send `stop` when their window is hidden/minimised and
`start` again when visible.

Mid-stream changes: `{"t":"cfg","fps":30,"bitrate":8000}` (any subset of the `start`
fields). If the change needs a new encoder the host announces a new `stream`.

`{"t":"kf"}` asks for a key frame (e.g. after a decoder error). The host forces at most one per
second but never drops a request: a second one within that second is served when it's up.

### 3.2 VIDEO frame (binary, host → client), big-endian

| offset | size | field |
|-------:|-----:|-------|
| 0  | 1 | kind = `0x01` |
| 1  | 1 | flags: bit0 = KEY (IDR; contains SPS+PPS), bit1 = REFRESH (quality refinement of unchanged content) |
| 2  | 2 | stream id (uint16) |
| 4  | 4 | frame sequence number (uint32, starts at 0 for each stream, +1 per frame) |
| 8  | 8 | capture timestamp, microseconds, host monotonic clock (uint64) |
| 16 | … | payload |

For `h264` the payload is exactly one **access unit in Annex-B format** (start codes
`00 00 00 01` / `00 00 01`). Key frames carry SPS and PPS in-band. Profile is High or
Main, **no B-frames** (decode order == display order), 4:2:0, 8-bit. Colour: BT.709,
limited range unless the VUI says otherwise. Resolution == the `stream` message's w×h.

### 3.3 Flow control — clients MUST ack every frame

After a frame has been **decoded** (or dropped by the client), send
```json
{"t":"ack","id":3,"n":1234}
```
(`id` = stream id, `n` = sequence number). The host keeps only a small window of
unacknowledged frames in flight; if acks stop, the host stops encoding. This is what
keeps latency low on slow links — do not ack early "to go faster".

### 3.4 Latency / clock

`{"t":"ping","c":<client clock, ms, float>}` → host answers immediately
`{"t":"pong","c":<echoed>,"s":<host monotonic clock, µs>}`.
Round-trip time = now − c. Host-clock offset ≈ s − (c + rtt/2)·1000, which lets the client
estimate capture→display latency from the VIDEO timestamp. Send a ping about every 2 s.

Host → client about once per second while streaming (informational):
```json
{"t":"stats","fps":58,"kbps":4200,"enc_ms":3.2,"cap_ms":2.1,"br":12000,"win":4,"rtt":18.5,"q":0.4}
```
`br` = current target bitrate (kbit/s, adapted to the network), `win` = frames allowed in
flight, `rtt` = minimum ack round-trip (ms), `q` = smoothed queueing delay (ms).

Frames with the REFRESH flag re-encode pixels that were captured earlier (to sharpen them once
the screen settles); their timestamp is the original capture time, so exclude them from
latency measurements.

---

## 4. Cursor (drawn by the client → zero-latency pointer)

The video stream does **not** contain the mouse pointer. The client draws the pointer
itself, using the real shape from the host:

```json
{"t":"cur","id":7,"w":24,"h":24,"hx":4,"hy":4,"png":"<base64 PNG, RGBA>"}
```
* First time an `id` is used the message contains the image; afterwards the host may
  send just `{"t":"cur","id":7}` to switch back to a cached shape.
* `{"t":"cur","id":0}` means the pointer is hidden.
* The host sends each image to a session at most once: clients must cache images by id for the
  whole session.
* Image and hotspot are in **host screen pixels**; scale them by the same factor used to
  display the video.

---

## 5. Input (client → host)

Coordinates are integers in the **current stream's pixel space** (0 … w−1, 0 … h−1).

| message | meaning |
|---|---|
| `{"t":"mm","x":812,"y":400}` | pointer moved (absolute). Coalesce: send at most one per display frame, but never delay it. |
| `{"t":"mb","b":0,"d":true}` | button down (`d:false` = up). `b` uses DOM numbering: 0 left, 1 middle, 2 right, 3 back, 4 forward. Send an `mm` first if the position changed (or include `"x"`,`"y"`). |
| `{"t":"wh","dx":0,"dy":120}` | wheel. Units of **1/120 notch** (120 = one wheel click). `dy>0` scrolls **down** (content moves up), `dx>0` scrolls right. The host accumulates and emits discrete notches. |
| `{"t":"key","c":"KeyA","d":true}` | physical key down/up. `c` = W3C `KeyboardEvent.code` (list in §10). Auto-repeat: send additional `d:true` events while the key is held (the host disables its own auto-repeat while a client is in control). Optional `"cmd":true` on the down of `KeyA`–`KeyZ` pressed while ⌘ is held and sent as Ctrl: in a terminal window the host adds Shift until that key goes up (Ctrl+Shift+C copies there); elsewhere it's ignored. |
| `{"t":"rel"}` | release every key and button the host believes is pressed. Send on focus loss. |
| `{"t":"txt","s":"héllo ✓"}` | type Unicode text (best effort; for IME output and "type clipboard"). |

The host also releases everything when a session ends.

**Mac guidance** (browser and native): map ⌘ Command → `ControlLeft`/`ControlRight` by
default (user-switchable to `MetaLeft`/`MetaRight` = Linux Super), ⌥ Option → `AltLeft`/
`AltRight`, ⌃ Control → `ControlLeft`/`ControlRight`. macOS delivers CapsLock as a state
toggle: send a `CapsLock` down+up pair on every state change. Browsers on macOS never deliver
key-up for keys pressed while ⌘ is held: send those as an immediate down+up pair.

---

## 6. Clipboard (text)

`{"t":"clip","text":"…"}` in either direction, max 1 MiB of UTF-8.
* Host → client: sent when the host clipboard changes, and always once right after `ok` (the
  current contents, possibly empty — clients don't apply this snapshot to the local clipboard).
* Client → host: the host becomes the clipboard owner with this text. Clients should send
  it right before sending a paste shortcut, or whenever the local clipboard changes.
* Neither side echoes back text it just received.

---

## 7. Files

### 7.1 Browsing and transfers (HTTP)

For clients when `ok.caps` contains `"fs"`. File data never travels over `/ws`: each request is
its own HTTPS request to the same origin, so video, sound and input never wait behind a file.

1. **Token.** On `/ws` send `{"t":"fs"}`. The host answers
   `{"t":"fs","token":"<base64url, 32 bytes>","home":"/home/…","inbox":"/home/…/Downloads/Darpan"}`.
   The token is valid until that session ends, and asking again returns the same one. Send it with
   every request as `Authorization: Bearer <token>`.
2. **Requests.** `path=` is an absolute path, UTF-8, percent-encoded.

| request | answer |
|---|---|
| `GET /fs/list?path=P` | `200`, JSON `{"path":P,"entries":[{"name":"a.txt","type":"f","size":12,"mtime":1727350000,"link":false}],"more":false}`. `type`: `d` directory, `f` regular file, `o` anything else (socket, device…). `link`: it is a symbolic link, and `type` describes its target. Names that aren't valid UTF-8 are left out. At most 20 000 entries; `more` is `true` if there were more. |
| `GET /fs/list?path=P&deep=1` | The same for everything below P, for sending a whole folder: `name` is relative to P with `/` separators, a directory comes before its contents, links to directories aren't followed, at most 50 000 entries. |
| `GET /fs/file?path=P` (also `HEAD`) | `200` and the bytes, with `Content-Length`, `Last-Modified`, `ETag` and `Accept-Ranges: bytes`. `Range: bytes=N-` or `bytes=N-M` gives `206` with `Content-Range`. To resume, send it with `If-Range: <the ETag you got>`: if the file has changed since, the answer is `200` with the whole file, so a resumed download never mixes two versions. Regular files only. |
| `PUT /fs/file?path=P&exists=fail` with a body (`Content-Length` required) | Writes a hidden temporary file next to P and renames it into place once complete, so an aborted upload leaves nothing behind. The parent directory must exist. If P exists: `exists=fail` (the default) answers `409 exists`, `replace` replaces it, `rename` picks `name (1).ext`, `name (2).ext`… `201`, JSON `{"path":<the final path>}`. |
| `POST /fs/mkdir?path=P` | `201`, JSON `{"path":P}`. `409 exists` if it already exists. |
| `POST /fs/ticket?path=P` | `200`, JSON `{"ticket":"…"}`: `GET /fs/file?ticket=…` then works once, within 60 s, without an `Authorization` header, and answers with `Content-Disposition: attachment`. For browsers, which can't add a header to a download. |

3. **Errors** are JSON `{"e":"<code>"}` with the status: `400 invalid` (not an absolute path, bad
   query), `401 token`, `403 denied` (no permission), `404 notfound`, `409 exists`, `409 notdir`,
   `409 isdir`, `409 notfile` (a socket, device or pipe), `416 range`, `429 busy` (more than 4 requests at once per session), `507 nospace`,
   `500 failed`.
4. Everything runs as the logged-in user, like the desktop the client already controls. To send or
   receive a folder, a client lists it with `deep=1`, then uses `mkdir` and `PUT`, or `GET`.

### 7.2 Upload into ~/Downloads/Darpan over /ws

The original upload, for clients without `"fs"`. New clients send dropped files with
`PUT /fs/file?path=<inbox>/<name>&exists=rename` instead.

1. `{"t":"fput","id":1,"name":"report.pdf","size":123456}` (`id` uint32 chosen by client)
2. Host: `{"t":"fok","id":1}` or `{"t":"ferr","id":1,"e":"reason"}`.
3. Client sends the bytes in order as FILE_CHUNK binary messages:
   `[0x02][uint32 id, big-endian][up to 256 KiB of data]`.
4. Host acks progress `{"t":"fack","id":1,"n":<total bytes received>}`. Keep at most
   1 MiB un-acked.
5. When `size` bytes have arrived: `{"t":"fdone","id":1,"path":"/home/…/Downloads/Darpan/report.pdf"}`.
   Client may abort with `{"t":"fabort","id":1}`.

Files land in `~/Downloads/Darpan/` (name sanitised, never overwrites: ` (1)` suffix).

---

## 8. Remote resolution

Host → client after `ok` and whenever it changes:
```json
{"t":"modes","output":"DP-0","current":[2560,1440],"native":[2560,1440],
 "modes":[[2560,1440],[1920,1080],[1280,720]],"changed":false}
```
`native` is the mode the monitor had before any client changed it; `changed` is true while a
client-selected mode is active. Client → host:

* `{"t":"res","w":1920,"h":1080}` — switch the host monitor to one of `modes`.
* `{"t":"res","native":true}` — restore the original mode.
* `{"t":"modes"}` — ask for a fresh `modes` message.

The host restores the original mode automatically when the last session ends. A resolution
change produces `screen`, `modes` and a new `stream`.

## 9. Other host → client messages

* `{"t":"screen","w":3840,"h":2160}` — host screen size changed (a new `stream` follows
  if streaming).
* `{"t":"notice","level":"info|warn|error","text":"…"}` — show to the user.
* `{"t":"bye","reason":"…"}` — sent right before the host closes the socket. Show the reason, but
  act on the close code that follows (4003: stay disconnected; 4004: reconnect).

---

## 10. Key codes (`KeyboardEvent.code` values accepted in `key`)

```
KeyA … KeyZ   Digit0 … Digit9   F1 … F24
Escape Backquote Minus Equal Backspace Tab BracketLeft BracketRight Backslash
CapsLock Semicolon Quote Enter ShiftLeft ShiftRight Comma Period Slash
ControlLeft ControlRight MetaLeft MetaRight AltLeft AltRight Space ContextMenu
IntlBackslash IntlRo IntlYen
Insert Delete Home End PageUp PageDown ArrowUp ArrowDown ArrowLeft ArrowRight
PrintScreen ScrollLock Pause
NumLock NumpadDivide NumpadMultiply NumpadSubtract NumpadAdd NumpadEnter
NumpadDecimal NumpadEqual NumpadComma Numpad0 … Numpad9
AudioVolumeMute AudioVolumeDown AudioVolumeUp
MediaPlayPause MediaStop MediaTrackNext MediaTrackPrevious
Lang1 Lang2 KanaMode Convert NonConvert
```
Keys are **physical positions** (US-QWERTY names); the host's keyboard layout decides
which character they produce. Use `txt` to type characters that have no key.

---

## 11. Typical session

```
C: (connect wss://host/ws)
H: hello {salt, iter, nonce}
C: auth {proof}
H: ok {screen, enc}
H: modes {current, native, modes}
H: cur {id, png}                ← current pointer shape
H: clip {text}                  ← current host clipboard
C: start {codec:"h264", fps:60, bitrate:0}
H: stream {id:1, w, h}
H: [VIDEO id=1 n=0 KEY]  C: ack {id:1,n:0}
H: [VIDEO id=1 n=1]      C: ack {id:1,n:1}
C: mm / mb / key / wh …   (any time after ok)
C: ping                   H: pong
C: stop                   (window hidden → host encoder shut down)
```

---

## 12. Audio (host → client)

The host's sound (whatever plays on its default output) goes over a **separate WebSocket**, so
10 ms audio packets never wait behind a large video frame on the same connection.

1. `ok.caps` contains `"audio"` when the host can capture sound. The client then sends
   `{"t":"audio","on":true}` on `/ws`.
2. The host answers
   `{"t":"audio","token":"<base64, 32 bytes>","codec":"opus","rate":48000,"channels":2,"frame_ms":10,"pre_skip":120}`
   or `{"t":"audio","error":"unavailable"}`. The token works **once**, for **10 s**. `pre_skip` is the
   encoder's delay in samples at 48 kHz.
3. The client opens `/audio` (same origin as `/ws`) and, within 5 s, sends `{"t":"auth","token":"…"}`.
   The host answers `{"t":"ok"}`, or closes with 4001 for a bad or expired token.
4. Then the host sends AUDIO messages, big-endian:

| offset | size | field |
|-------:|-----:|-------|
| 0  | 1 | kind = `0x03` |
| 1  | 1 | flags: bit0 = FIRST (first packet after silence or dropped packets: restart the jitter buffer) |
| 2  | 4 | slot (uint32): counts captured 10 ms frames; a jump of n means n − 1 silent frames weren't sent. While nothing plays at all the host receives no frames, so the count just continues; FIRST marks the restart |
| 6  | 8 | capture timestamp, microseconds, host monotonic clock (the clock video uses) |
| 14 | … | one Opus packet: 10 ms, 48 kHz, stereo |

* Nothing is sent while nothing plays, and digital silence isn't sent. Clients play gaps as silence.
* If a client's link falls behind (more than 32 KiB unsent), the host drops its audio packets rather
  than delaying them; the next packet sent to it has FIRST set.
* `{"t":"audio","on":false}` on `/ws`, or closing `/audio`, stops it. `/audio` closes with 4003 when
  its session ends. Each viewer has its own token and socket; they share one capture on the host.
