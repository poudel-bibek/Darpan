// FakeHost: a stand-in for the Linux host, to test the Mac app end to end on this Mac without a
// tailnet. Speaks PROTOCOL.md on ws://localhost:<port>/ws (loopback only), streams an H.264 test
// pattern (VideoToolbox) that shows the input it receives, and logs every input message.
//
//   swift run FakeHost [--port 47491] [--password <pw>] [--size 1920x1080] [--max-sessions 2]
//                      [--name workstation] [--image desktop.png]   (a still picture instead of the pattern)
//   DARPAN_URL=http://localhost:47491 DARPAN_PASSWORD=<pw> swift run Darpan
//
// Commands on stdin: clip <text> · notice <text> · error <text> · kick · restart · drop ·
// stall (8 s of silence) · lock (30 s lockout) · quit
import AVFoundation
import DarpanCore
import Foundation
import Network

setvbuf(stdout, nil, _IOLBF, 0)

var port: UInt16 = 47491
var password = ProcessInfo.processInfo.environment["FAKEHOST_PASSWORD"] ?? "darpan-test"
var size = (1920, 1080)
var maxSessions = 2
var hostName = "fakehost"
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--port": port = UInt16(args.next() ?? "") ?? port
    case "--password": password = args.next() ?? password
    case "--size":
        let p = (args.next() ?? "").split(separator: "x").compactMap { Int($0) }
        if p.count == 2 { size = (p[0], p[1]) }
    case "--max-sessions": maxSessions = Int(args.next() ?? "") ?? maxSessions
    case "--name": hostName = args.next() ?? hostName
    case "--image":
        let url = URL(fileURLWithPath: args.next() ?? "") as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            print("can't read the image"); exit(2)
        }
        stillImage = img
        size = (img.width, img.height)
    default: print("unknown argument \(a)"); exit(2)
    }
}

let queue = DispatchQueue(label: "fakehost", qos: .userInteractive)
let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
let iterations = 200_000
let key = try! Auth.deriveKey(password: password, salt: salt, iterations: iterations)
let uploadDir = FileManager.default.temporaryDirectory.appendingPathComponent("darpan-fakehost")

func log(_ s: String) { print(String(format: "%.3f ", Clock.nowMs() / 1000) + s) }

func json(_ o: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]), encoding: .utf8)!
}

// MARK: - host state (queue only)

let native = size
let modes: [(Int, Int)] = [native, (2560, 1600), (1920, 1200), (1920, 1080), (1680, 1050), (1440, 900), (1280, 800), (1280, 720)]
    .reduce(into: []) { acc, m in if !acc.contains(where: { $0 == m }) { acc.append(m) } }
var sessions: [Session] = []
var failures = 0
var lockedUntil = 0.0
var hostClip = "FakeHost clipboard ✓"
var silentUntil = 0.0
var audioTokens = Set<String>()
var audioSockets: [Session] = []
var soundUntil = 0.0                        // `soundfail`: capture "broken" until then

/// One second of a 440 Hz tone as 10 ms Opus packets (a whole number of cycles, so it loops cleanly).
let tone: [Data] = {
    let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    var d = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                        mFramesPerPacket: 480, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
    let opus = AVAudioFormat(streamDescription: &d)!
    guard let enc = AVAudioConverter(from: pcm, to: opus) else { return [] }
    enc.bitRate = 128_000
    let src = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 48000)!
    src.frameLength = 48000
    for c in 0..<2 { for i in 0..<48000 { src.floatChannelData![c][i] = Float(0.3 * sin(2 * .pi * 440 * Double(i) / 48000)) } }
    var out: [Data] = [], fed = false
    while true {
        let b = AVAudioCompressedBuffer(format: opus, packetCapacity: 8, maximumPacketSize: 1500)
        var err: NSError?
        let st = enc.convert(to: b, error: &err) { _, s in
            if fed { s.pointee = .endOfStream; return nil }
            fed = true; s.pointee = .haveData; return src
        }
        for i in 0..<Int(b.packetCount) {
            let p = b.packetDescriptions![i]
            out.append(Data(bytes: b.data + Int(p.mStartOffset), count: Int(p.mDataByteSize)))
        }
        if st != .haveData || b.packetCount == 0 { break }
    }
    return out
}()

func modesMessage() -> String {
    json(["t": "modes", "output": "FAKE-1", "current": [size.0, size.1], "native": [native.0, native.1],
          "modes": modes.map { [$0.0, $0.1] }, "changed": size != native])
}

final class Session {
    let conn: NWConnection
    let sid = String(UUID().uuidString.prefix(8)).lowercased()
    let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    var authed = false
    var closed = false
    var scene = Scene()
    var cursor = -1
    var cursorsSent = Set<Int>()

    // video
    var encoder: Encoder?
    var timer: DispatchSourceTimer?
    var streamId: UInt16 = 0
    var seq: UInt32 = 0
    var inflight: [UInt32: Double] = [:]
    var paused = true
    var fps = 60
    var kbps = 0
    var lastKeyRequest = 0.0
    var frames = 0, bytes = 0, encMs = 0.0, rtt = 0.0
    var statsTimer: DispatchSourceTimer?
    var toneTimer: DispatchSourceTimer?

    // uploads
    var uploads: [UInt32: (handle: FileHandle, url: URL, size: Int, n: Int)] = [:]

    init(_ c: NWConnection) { conn = c }

    func start() {
        conn.stateUpdateHandler = { [self] st in
            switch st {
            case .ready:
                log("connection \(sid) from \(conn.endpoint)")
                sendText(json(["t": "hello", "proto": 1, "app": "darpan", "ver": "1.0.0", "host": hostName,
                               "nonce": nonce.base64EncodedString(),
                               "kdf": ["alg": "pbkdf2-sha256", "salt": salt.base64EncodedString(), "iter": iterations]]))
                receive()
                queue.asyncAfter(deadline: .now() + 30) { [self] in if !authed && !closed { close(4002) } }
            case .failed, .cancelled:
                ended()
            default: break
            }
        }
        conn.start(queue: queue)
    }

    // MARK: transport

    func sendText(_ s: String) {
        guard !closed, Clock.nowMs() >= silentUntil else { return }
        let ctx = NWConnection.ContentContext(identifier: "t", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        conn.send(content: Data(s.utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    func sendBinary(_ d: Data) {
        guard !closed, Clock.nowMs() >= silentUntil else { return }
        let ctx = NWConnection.ContentContext(identifier: "b", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        conn.send(content: d, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    func close(_ code: UInt16) {
        guard !closed else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = .privateCode(code)
        let ctx = NWConnection.ContentContext(identifier: "c", metadata: [meta])
        conn.send(content: nil, contentContext: ctx, isComplete: true, completion: .contentProcessed { [self] _ in conn.cancel() })
        ended()
    }

    func drop() {
        conn.cancel()
        ended()
    }

    func ended() {
        guard !closed else { return }
        closed = true
        conn.stateUpdateHandler = nil
        stopVideo()
        encoder = nil
        for u in uploads.values { try? u.handle.close() }
        uploads.removeAll()
        sessions.removeAll { $0 === self }
        log("session \(sid) ended" + (sessions.isEmpty && size != native ? "; restoring \(native.0)×\(native.1)" : ""))
        if sessions.isEmpty { size = native }
    }

    func receive() {
        conn.receiveMessage { [self] content, context, _, error in
            if error != nil { return ended() }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch meta?.opcode {
            case .text?:
                if Clock.nowMs() >= silentUntil, let d = content, let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    handle(m)
                }
            case .binary?:
                if let d = content { chunk(d) }
            case .close?:
                return ended()
            default:
                if content == nil { return ended() }
            }
            if !closed { receive() }
        }
    }

    // MARK: messages

    func handle(_ m: [String: Any]) {
        let t = m["t"] as? String ?? ""
        guard authed else {
            if t == "auth" { authenticate(m) }
            return
        }
        switch t {
        case "start":
            fps = max(1, min(120, m["fps"] as? Int ?? 60))
            kbps = max(0, m["bitrate"] as? Int ?? 0)
            log("start fps=\(fps) bitrate=\(kbps)")
            if let e = encoder, paused, e.fps == fps, e.width == size.0, e.height == size.1 { resume() } else { startVideo() }
        case "stop":
            log("stop")
            paused = true
            timer?.cancel(); timer = nil
        case "cfg":
            if let f = m["fps"] as? Int { fps = max(1, min(120, f)) }
            if let b = m["bitrate"] as? Int { kbps = max(0, b) }
            log("cfg fps=\(fps) bitrate=\(kbps)")
            encoder?.set(fps: fps, kbps: kbps)
            if !paused { scheduleFrames() }
        case "kf":
            let now = Clock.nowMs()
            if now - lastKeyRequest > 1000 { lastKeyRequest = now; encoder?.keyFrame(); log("kf") }
        case "ack":
            guard m["id"] as? Int == Int(streamId), let n = (m["n"] as? NSNumber)?.uint32Value else { return }
            if let sent = inflight[n] { rtt = rtt == 0 ? Clock.nowMs() - sent : rtt * 0.9 + (Clock.nowMs() - sent) * 0.1 }
            inflight = inflight.filter { $0.key > n }
        case "ping":
            sendText(json(["t": "pong", "c": m["c"] ?? 0, "s": Int(Clock.nowMs() * 1000)]))
        case "mm":
            scene.pointer = (m["x"] as? Int ?? 0, m["y"] as? Int ?? 0)
            updateCursor()
        case "mb":
            if let x = m["x"] as? Int, let y = m["y"] as? Int { scene.pointer = (x, y) }
            let b = m["b"] as? Int ?? -1, d = m["d"] as? Bool ?? false
            if d { scene.buttons.insert(b) } else { scene.buttons.remove(b) }
            log("mb \(b) \(d ? "down" : "up") at \(scene.pointer.map { "\($0.x),\($0.y)" } ?? "?")")
        case "wh":
            scene.wheel = (m["dx"] as? Int ?? 0, m["dy"] as? Int ?? 0)
            log("wh dx=\(scene.wheel.dx) dy=\(scene.wheel.dy)")
        case "key":
            let c = m["c"] as? String ?? "?", d = m["d"] as? Bool ?? false
            scene.lastKey = "\(c) \(d ? "↓" : "↑")"
            log("key \(c) \(d ? "down" : "up")" + (m["cmd"] as? Bool == true ? " cmd" : ""))
        case "rel":
            scene.buttons.removeAll()
            log("rel")
        case "txt":
            let s = m["s"] as? String ?? ""
            scene.typed += s
            log("txt \(s.debugDescription)")
        case "clip":
            let s = m["text"] as? String ?? ""
            hostClip = s
            scene.clip = s
            log("clip \(s.prefix(80).debugDescription) (\(s.utf8.count) bytes)")
            for o in sessions where o !== self { o.sendText(json(["t": "clip", "text": s])) }
        case "res":
            if m["native"] as? Bool == true { setSize(native) } else if let w = m["w"] as? Int, let h = m["h"] as? Int {
                if modes.contains(where: { $0 == (w, h) }) { setSize((w, h)) } else {
                    sendText(json(["t": "notice", "level": "error", "text": "resolution change failed: no mode \(w)x\(h)"]))
                }
            }
        case "modes":
            sendText(modesMessage())
        case "audio":
            if m["on"] as? Bool == true && Clock.nowMs() < soundUntil {
                log("audio on: unavailable")
                sendText(json(["t": "audio", "error": "unavailable"]))
            } else if m["on"] as? Bool == true {
                let t = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
                audioTokens.insert(t)
                queue.asyncAfter(deadline: .now() + 10) { audioTokens.remove(t) }
                log("audio on")
                sendText(json(["t": "audio", "token": t, "codec": "opus", "rate": 48000, "channels": 2, "frame_ms": 10, "pre_skip": 120]))
            } else {
                log("audio off")
            }
        case "fput":
            startUpload(m)
        case "fabort":
            if let id = (m["id"] as? NSNumber)?.uint32Value, let u = uploads.removeValue(forKey: id) {
                try? u.handle.close(); try? FileManager.default.removeItem(at: u.url)
                log("fabort \(id)")
            }
        default:
            log("ignored \(t)")
        }
    }

    /// The sound socket: 3 s of tone, 1 s of nothing (the slot keeps counting), repeat.
    func startTone() {
        var slot: UInt32 = 0, first = true
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in
            guard let self, !self.closed else { t.cancel(); return }
            slot &+= 1
            let phase = Int(slot % 400)
            guard phase < 300, !tone.isEmpty else { first = true; return }
            var msg = AudioHeader(flags: first ? AudioHeader.flagAfterSilence : 0, seq: slot,
                                  captureUs: UInt64(Clock.nowMs() * 1000)).bytes
            msg.append(tone[phase % tone.count])
            first = false
            self.sendBinary(msg)
        }
        t.resume()
        toneTimer = t
    }

    func authenticate(_ m: [String: Any]) {
        if let token = m["token"] as? String {
            guard audioTokens.remove(token) != nil else { return close(4001) }
            authed = true
            log("audio socket \(sid) signed in")
            sendText(json(["t": "ok"]))
            audioSockets.append(self)
            return startTone()
        }
        let now = Clock.nowMs()
        if lockedUntil > now {
            sendText(json(["t": "denied", "reason": "locked", "retry": Int(((lockedUntil - now) / 1000).rounded(.up))]))
            return close(4001)
        }
        let expected = Auth.proof(key: key, nonce: nonce).base64EncodedString()
        guard m["proof"] as? String == expected else {
            failures += 1
            if failures >= 5 { lockedUntil = now + 30_000 * pow(2, Double(failures - 5)) }
            let retry = lockedUntil > now ? Int(((lockedUntil - now) / 1000).rounded(.up)) : 0
            log("bad password (\(failures) failures)")
            sendText(json(["t": "denied", "reason": "password", "retry": retry]))
            return close(4001)
        }
        guard sessions.count < maxSessions else {
            sendText(json(["t": "denied", "reason": "busy", "retry": 5]))
            return close(4005)
        }
        failures = 0
        authed = true
        sessions.append(self)
        log("session \(sid): \(m["client"] as? String ?? "?") ver \(m["ver"] as? String ?? "?")")
        sendText(json(["t": "ok", "sid": sid, "screen": ["w": size.0, "h": size.1], "codecs": ["h264"],
                       "caps": ["clip", "files", "text", "cursor", "res", "audio"], "url": "http://localhost:\(port)",
                       "enc": "videotoolbox", "gpu": "Apple"]))
        sendText(modesMessage())
        updateCursor(force: true)
        sendText(json(["t": "clip", "text": hostClip]))
    }

    func updateCursor(force: Bool = false) {
        var id = 1
        if let p = scene.pointer {
            if p.y > size.1 - 60 { id = 0 } else if p.x > size.0 / 2 { id = 2 }
        }
        guard id != cursor || force else { return }
        cursor = id
        sendText(json(Cursors.message(id, full: cursorsSent.insert(id).inserted)))
    }

    // MARK: video

    func startVideo() {
        stopVideo()
        streamId = streamId % 0xFFFF + 1
        seq = 0
        inflight.removeAll()
        encoder = Encoder(width: size.0, height: size.1, fps: fps, kbps: kbps) { [weak self] data, key, capture, enc in
            queue.async { self?.frameReady(data, key: key, captureUs: capture, encodeMs: enc) }
        }
        guard encoder != nil else {
            sendText(json(["t": "notice", "level": "error", "text": "screen capture failed: encoder unavailable"]))
            return
        }
        sendText(json(["t": "stream", "id": Int(streamId), "codec": "h264", "w": size.0, "h": size.1, "fps": fps, "enc": "videotoolbox"]))
        paused = false
        scheduleFrames()
        startStats()
    }

    func resume() {
        streamId = streamId % 0xFFFF + 1
        seq = 0
        inflight.removeAll()
        sendText(json(["t": "stream", "id": Int(streamId), "codec": "h264", "w": size.0, "h": size.1, "fps": fps, "enc": "videotoolbox"]))
        encoder?.keyFrame()
        paused = false
        scheduleFrames()
    }

    func stopVideo() {
        timer?.cancel(); timer = nil
        statsTimer?.cancel(); statsTimer = nil
        paused = true
        encoder?.invalidate()
    }

    func scheduleFrames() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = 1.0 / Double(fps)
        t.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.nextFrame() }
        t.resume()
        timer = t
    }

    func nextFrame() {
        guard !paused, !closed, let e = encoder, Clock.nowMs() >= silentUntil else { return }
        let now = Clock.nowMs()
        if let oldest = inflight.values.min(), now - oldest > 3000 {      // acks stopped: resync
            log("ack watchdog: resync")
            inflight.removeAll()
            e.keyFrame()
        }
        guard inflight.count < 4 else { return }                         // flow control window
        e.encode(scene)
    }

    func frameReady(_ data: Data, key: Bool, captureUs: UInt64, encodeMs: Double) {
        guard !paused, !closed else { return }
        let n = seq
        seq &+= 1
        inflight[n] = Clock.nowMs()
        var msg = VideoHeader(flags: key ? VideoHeader.flagKey : 0, stream: streamId, seq: n, captureUs: captureUs).bytes
        msg.append(data)
        sendBinary(msg)
        frames += 1
        bytes += msg.count
        encMs += encodeMs
    }

    func startStats() {
        statsTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, !self.paused, self.frames > 0 else { return }
            self.sendText(json(["t": "stats", "fps": Double(self.frames), "kbps": self.bytes * 8 / 1000,
                                "cap_ms": 1.0, "enc_ms": (self.encMs / Double(self.frames) * 100).rounded() / 100,
                                "br": self.kbps > 0 ? self.kbps : 12_000, "win": 4, "rtt": (self.rtt * 10).rounded() / 10, "q": 0]))
            self.frames = 0; self.bytes = 0; self.encMs = 0
        }
        t.resume()
        statsTimer = t
    }

    // MARK: uploads

    func startUpload(_ m: [String: Any]) {
        guard let id = (m["id"] as? NSNumber)?.uint32Value, let total = m["size"] as? Int, total >= 0, uploads[id] == nil else {
            return sendText(json(["t": "ferr", "id": m["id"] ?? 0, "e": "rejected"]))
        }
        let name = ((m["name"] as? String) ?? "file").replacingOccurrences(of: "/", with: "_")
        try? FileManager.default.createDirectory(at: uploadDir, withIntermediateDirectories: true)
        let url = uploadDir.appendingPathComponent(name.isEmpty ? "file" : name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else {
            return sendText(json(["t": "ferr", "id": Int(id), "e": "can't write"]))
        }
        uploads[id] = (h, url, total, 0)
        log("fput \(id) \(name) \(total) bytes")
        sendText(json(["t": "fok", "id": Int(id)]))
        if total == 0 { finishUpload(id) }
    }

    func chunk(_ d: Data) {
        guard d.count >= 5, d[d.startIndex] == 2 else { return }
        let b = [UInt8](d.prefix(5))
        let id = UInt32(b[1]) << 24 | UInt32(b[2]) << 16 | UInt32(b[3]) << 8 | UInt32(b[4])
        guard var u = uploads[id] else { return }
        let payload = d.dropFirst(5)
        guard u.n + payload.count <= u.size else {
            uploads.removeValue(forKey: id)
            return sendText(json(["t": "ferr", "id": Int(id), "e": "too much data"]))
        }
        u.handle.write(payload)
        u.n += payload.count
        uploads[id] = u
        sendText(json(["t": "fack", "id": Int(id), "n": u.n]))
        if u.n == u.size { finishUpload(id) }
    }

    func finishUpload(_ id: UInt32) {
        guard let u = uploads.removeValue(forKey: id) else { return }
        try? u.handle.close()
        log("fdone \(id) → \(u.url.path)")
        sendText(json(["t": "fdone", "id": Int(id), "path": u.url.path]))
    }
}

func setSize(_ s: (Int, Int)) {
    guard s != size else { return }
    log("resolution \(size.0)×\(size.1) → \(s.0)×\(s.1)")
    size = s
    for x in sessions {
        x.sendText(json(["t": "screen", "w": s.0, "h": s.1]))
        if x.paused {
            x.encoder?.invalidate()                    // the next start encodes at the new size
            x.encoder = nil
        } else {
            x.startVideo()
        }
        x.sendText(modesMessage())
    }
}

// MARK: - listener

let ws = NWProtocolWebSocket.Options()
ws.autoReplyPing = true
ws.maximumMessageSize = 16 << 20
let params = NWParameters.tcp
params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
params.requiredInterfaceType = .loopback
params.allowLocalEndpointReuse = true
let listener = try! NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
listener.newConnectionHandler = { c in Session(c).start() }
listener.stateUpdateHandler = { st in
    if case .ready = st { log("FakeHost on ws://localhost:\(port)/ws  \(size.0)×\(size.1)  password \"\(password)\"") }
    if case .failed(let e) = st { log("listener failed: \(e)"); exit(1) }
}
listener.start(queue: queue)

// MARK: - commands

Thread.detachNewThread {
    while let line = readLine() {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { continue }
        let arg = parts.count > 1 ? parts[1] : ""
        queue.async {
            switch cmd {
            case "clip":
                hostClip = arg
                for s in sessions { s.scene.clip = arg; s.sendText(json(["t": "clip", "text": arg])) }
            case "notice", "error":
                for s in sessions { s.sendText(json(["t": "notice", "level": cmd == "error" ? "error" : "info", "text": arg])) }
            case "kick":
                for s in sessions { s.sendText(json(["t": "bye", "reason": "disconnected by host"])); s.close(4003) }
            case "restart":
                for s in sessions { s.close(4004) }
            case "drop":
                for s in sessions { s.drop() }
            case "soundfail":
                soundUntil = Clock.nowMs() + 60_000
                for s in audioSockets where !s.closed { s.close(1011) }
                audioSockets.removeAll()
                log("sound broken for 60 s")
            case "stall":
                silentUntil = Clock.nowMs() + 8000
                log("silent for 8 s")
            case "lock":
                lockedUntil = Clock.nowMs() + 30_000
                log("locked for 30 s")
            case "quit":
                for s in sessions { s.close(4004) }
                queue.asyncAfter(deadline: .now() + 0.2) { exit(0) }
            default:
                log("commands: clip <text> | notice <text> | error <text> | kick | restart | drop | stall | lock | quit")
            }
        }
    }
}

dispatchMain()
