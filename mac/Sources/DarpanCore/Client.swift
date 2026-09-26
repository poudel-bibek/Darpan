import CoreMedia
import CoreVideo
import Foundation
import Network

/// Receives decoded frames. Called on a VideoToolbox thread, in decode order, the moment a
/// frame exists; must not block.
public protocol VideoSink: AnyObject {
    func display(_ image: CVImageBuffer)
}

/// Everything the UI hears from the client, on the main queue.
public protocol ClientDelegate: AnyObject {
    func clientStateChanged(_ client: Client)
    func client(_ client: Client, received event: Client.Event)
}

/// Sign-in material that may be kept in the Keychain: PBKDF2 output, never the password.
public struct SavedKey: Codable, Equatable {
    public let key: Data
    /// Base64, exactly as the host sent it.
    public let salt: String
    public let iter: Int

    public init(key: Data, salt: String, iter: Int) {
        self.key = key; self.salt = salt; self.iter = iter
    }
}

/// One Darpan session (PROTOCOL.md): sign-in, video with per-frame acks, clock sync,
/// watchdog and automatic reconnection, plus the small request/response parts (uploads).
///
/// Threads: network callbacks, parsing and decode submission run on one serial queue; decoded
/// frames are displayed and acked straight from VideoToolbox's output callback; `send` is
/// callable from any thread (input goes out from the main thread without a hop). UI-facing
/// state and events arrive on the main queue.
public final class Client {
    public enum State: Equatable {
        case idle
        /// The user pressed Connect; nothing on screen yet.
        case connecting
        case connected
        /// The connection dropped; retrying with backoff. `restarting`: the host said so (4004).
        case reconnecting(restarting: Bool)
        case failed(Failure)
    }

    public enum Failure: Equatable, CustomStringConvertible {
        case needPassword
        case wrongPassword(retry: Int)
        case locked(retry: Int)
        case noPassword
        case busy
        case passwordChanged
        case savedKeyExpired
        case denied
        case unreachable(String?)
        case offline
        case tls(String)
        case kicked(String?)
        case protocolError(String)

        public var description: String {
            switch self {
            case .needPassword: return "Enter the password."
            case .wrongPassword(let r): return r > 0 ? "Wrong password. Locked for \(r) s." : "Wrong password."
            case .locked(let r): return "Too many attempts. Try again in \(r) s."
            case .noPassword: return "No password is set on the remote computer. Run “darpan setup” there."
            case .busy: return "Too many people are connected right now."
            case .passwordChanged: return "The password on the remote computer changed — enter it again."
            case .savedKeyExpired: return "Saved sign-in expired — enter the password."
            case .denied: return "Access denied."
            case .unreachable(let d):
                return "Could not reach the remote computer. Is Tailscale running?" + (d.map { "\n(\($0))" } ?? "")
            case .offline: return "This Mac is offline."
            case .tls(let d): return "Could not set up a secure connection: \(d)"
            case .kicked: return "Disconnected by the remote computer"
            case .protocolError(let d): return "The remote computer sent something unexpected (\(d))."
            }
        }

        /// Seconds until the host accepts another attempt, for a countdown.
        public var retryAfter: Int? {
            switch self {
            case .wrongPassword(let r), .locked(let r): return r > 0 ? r : nil
            default: return nil
            }
        }

        /// The password field should be focused and cleared.
        public var wantsPassword: Bool {
            switch self {
            case .needPassword, .wrongPassword, .passwordChanged, .savedKeyExpired: return true
            default: return false
            }
        }
    }

    public struct Welcome {
        public let sid: String
        public let hostName: String?
        public let screen: DisplayMode?
        public let encoder: String?
        public let gpu: String?
        public let url: String?
        public let caps: [String]
    }

    public struct StreamInfo: Equatable {
        public let id: UInt16
        public let width: Int
        public let height: Int
        public let fps: Int
        public let encoder: String
    }

    public struct Cursor {
        public let id: Int
        public let png: Data?
        public let width: Int
        public let height: Int
        public let hotX: Int
        public let hotY: Int
    }

    public struct Modes: Equatable {
        public let output: String?
        public let current: DisplayMode?
        public let native: DisplayMode?
        public let modes: [DisplayMode]
        public let changed: Bool
    }

    public struct HostStats: Equatable {
        public let fps: Double
        public let kbps: Double
        public let captureMs: Double
        public let encodeMs: Double
        public let targetKbps: Double
        public let rtt: Double
        public let queueMs: Double
    }

    public enum Upload: Equatable {
        case progress(name: String, fraction: Double)
        case done(name: String, path: String)
        case failed(name: String, reason: String)
    }

    public enum Event {
        case welcome(Welcome)
        /// A new stream (first frame is a key frame). Pointer coordinates are in these pixels.
        case stream(StreamInfo)
        case screen(DisplayMode)
        case cursor(Cursor)
        /// `initial`: the first clipboard after connecting — show it, don't copy it.
        case clipboard(String, initial: Bool)
        case modes(Modes)
        case notice(String, error: Bool)
        case upload(Upload)
        /// Sign-in with a freshly typed password worked; keep this if the user asked to be remembered.
        case authenticated(SavedKey)
        /// The saved key is no longer valid.
        case forgetKey
    }

    public struct Stats {
        public var stream: StreamInfo?
        public var fps = 0.0
        public var mbps = 0.0
        public var rtt: Double?
        /// Host capture → frame handed to the display layer (ms, clock-offset corrected).
        public var latency: Double?
        public var decodeMs = 0.0
        public var host: HostStats?
        public var hardwareDecoder = false
        public var framesTotal = 0
    }

    public let address: HostAddress
    /// Set: every connection attempt goes through this proxy (the built-in tailnet node).
    public let proxy: SOCKSProxy?
    public weak var delegate: ClientDelegate?
    /// Main-thread view of the state.
    public private(set) var state: State = .idle

    // Shared with other threads: guarded by `lock`.
    private let lock = NSLock()
    private var live: WebSocket?                 // set while signed in: `send` uses it
    private var clock = ClockSync()
    private var counters = Counters()
    private weak var sink: VideoSink?

    // Everything below: `queue` only.
    private let queue = DispatchQueue(label: "dev.darpan.Darpan.io", qos: .userInteractive)
    private var socket: WebSocket?
    private var generation = 0
    private var password: String?
    private var key: SavedKey?
    private var keyIsNew = false
    private var usedPassword = false
    private var everConnected = false
    private var authed = false
    private var helloSeen = false
    private var deniedWith: Failure?
    private var byeReason: String?
    private var helloHost: String?
    private var hostRestarting = false
    private var retry = 0
    private var lastInbound = 0.0
    private var pingTimer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?

    private var wantVideo = false
    private var streaming = false
    private var fps = 60
    private var bitrate = 0
    private var stream: StreamInfo?
    private var decoder: H264Decoder!
    private var needKeySince = 0.0
    private var lastKeyRequest = -1e9
    private var lastDecodeError = -1e9
    private var decodeErrors: [Double] = []
    private var warnedDecoder = false
    private var lastStop = -1e9
    private var clipSeen = false
    private var wantAudio = false
    private var hostHasAudio = false
    private var audio: AudioStream?
    private weak var audioSink: AudioSink?

    private let uploads: Uploader

    public init(address: HostAddress, sink: VideoSink, proxy: SOCKSProxy? = nil) {
        self.address = address
        self.proxy = proxy
        self.sink = sink
        uploads = Uploader()
        decoder = H264Decoder { [weak self] frame, image, status in
            self?.decoded(frame, image, status)
        }
        uploads.client = self
    }

    deinit {
        pingTimer?.cancel()
        socket?.close()
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
    }

    // MARK: - public API

    /// Start signing in. `password` wins over `saved`; with neither the host's hello is
    /// answered with `.failed(.needPassword)`.
    public func connect(password: String?, saved: SavedKey?) {
        state = .connecting
        delegate?.clientStateChanged(self)
        queue.async {
            self.password = password
            self.key = saved
            self.keyIsNew = false
            self.everConnected = false
            self.retry = 0
            self.hostRestarting = false
            self.open(initial: true)
        }
    }

    /// User-initiated: close the session, no reconnect.
    public func disconnect() {
        queue.async {
            self.generation += 1
            self.teardown()
            self.publish(.idle)
        }
    }

    public var isAuthenticated: Bool {
        lock.lock(); defer { lock.unlock() }
        return live != nil
    }

    /// Sends a text message if signed in. Any thread.
    public func send(_ text: String?) {
        guard let text else { return }
        lock.lock()
        let s = live
        lock.unlock()
        s?.send(text: text)
    }

    func sendBinary(_ data: Data, completion: (() -> Void)? = nil) -> Bool {
        lock.lock()
        let s = live
        lock.unlock()
        guard let s else { return false }
        s.send(binary: data, completion: completion)
        return true
    }

    /// Visible → stream; hidden/minimised → `stop` (the host encoder idles, ~0 cost).
    public func setVideoActive(_ on: Bool) {
        queue.async {
            guard self.wantVideo != on else { return }
            self.wantVideo = on
            guard self.authed else { return }
            if on && !self.streaming {
                self.sendStart()
            } else if !on && self.streaming {
                self.streaming = false
                self.lastStop = Clock.nowMs()
                self.socket?.send(text: Msg.stop)
            }
        }
    }

    /// Maximum frame rate and bitrate (kbit/s, 0 = adaptive).
    public func setVideo(fps: Int, bitrate: Int) {
        queue.async {
            let f = max(1, min(120, fps)), b = max(0, bitrate)
            let changedFps = f != self.fps, changedBitrate = b != self.bitrate
            self.fps = f
            self.bitrate = b
            if self.streaming && (changedFps || changedBitrate) {
                self.socket?.send(text: Msg.cfg(fps: changedFps ? f : nil, bitrate: changedBitrate ? b : nil))
            }
        }
    }

    /// After the Mac wakes: probe at once instead of waiting for the next ping.
    public func wake() {
        queue.async {
            guard self.authed else { return }
            self.lastInbound = Clock.nowMs()
            self.ping()
        }
    }

    /// Sound on or off (PROTOCOL.md §12). Decoded audio goes to `sink`, on its own queue.
    public func setAudio(_ on: Bool, sink: AudioSink?) {
        queue.async {
            self.audioSink = sink
            guard self.wantAudio != on else { return }
            self.wantAudio = on
            guard self.authed, self.hostHasAudio else { return }
            if !on { self.audio?.close(); self.audio = nil }
            self.socket?.send(text: Msg.audio(on: on))
        }
    }

    public func upload(_ urls: [URL]) { uploads.enqueue(urls) }

    public func cancelUploads() { uploads.cancelAll(reason: "cancelled") }

    /// Counters since the previous call (call it every 500 ms while the stats are shown).
    public func takeStats() -> Stats {
        let now = Clock.nowMs()
        lock.lock()
        let c = counters
        counters.frames = 0
        counters.bytes = 0
        counters.since = now
        let rtt = clock.rtt
        lock.unlock()
        let dt = max(1, now - c.since) / 1000
        var s = Stats()
        s.stream = c.stream
        s.fps = Double(c.frames) / dt
        s.mbps = Double(c.bytes) * 8 / dt / 1e6
        s.rtt = rtt
        s.latency = c.latency
        s.decodeMs = c.decodeMs
        s.host = c.host
        s.hardwareDecoder = c.hardware
        s.framesTotal = c.framesTotal
        return s
    }

    /// Latest latency estimate for the quality dot, without resetting counters.
    public var quality: Double? {
        lock.lock(); defer { lock.unlock() }
        return counters.latency ?? clock.rtt
    }

    // MARK: - connection lifecycle (queue)

    private func open(initial: Bool) {
        generation += 1
        let gen = generation
        helloSeen = false
        deniedWith = nil
        byeReason = nil
        let ws = WebSocket(url: address.webSocketURL, userAgent: Self.userAgent, proxy: proxy, queue: queue) { [weak self] e in
            guard let self, self.generation == gen else { return }
            self.handle(e)
        }
        socket = ws
        ws.start()
        queue.asyncAfter(deadline: .now() + (initial ? 10 : 15)) { [weak self] in
            guard let self, self.generation == gen, !self.authed else { return }
            self.attemptFailed(.unreachable("timed out"))
        }
    }

    private func handle(_ e: WebSocket.Event) {
        switch e {
        case .ready:
            lastInbound = Clock.nowMs()
        case .waiting(let err):
            // Network.framework would keep retrying; on the first attempt a definite answer
            // is better than a spinner. Reconnects wait (Wi-Fi coming back, etc.).
            guard !everConnected else { return }
            if err.isNameResolution {
                attemptFailed(.unreachable(nil))
            } else if err.isTLS {
                attemptFailed(.tls(err.localizedDescription))
            } else if err.isOffline {
                attemptFailed(.offline)
            } else if err.isRefused {
                attemptFailed(.unreachable("connection refused — is Darpan running there?"))
            }
        case .text(let d):
            lastInbound = Clock.nowMs()
            if d.count <= Msg.maxTextMessage, let m = Incoming(d) { onMessage(m) }
        case .binary(let d):
            lastInbound = Clock.nowMs()
            onVideo(d)
        case .closed(let code, let err):
            socket = nil
            ended(code: code, error: err)
        }
    }

    /// The current attempt failed before sign-in completed.
    private func attemptFailed(_ f: Failure) {
        generation += 1
        teardown()
        if everConnected {
            scheduleReconnect()
        } else {
            publish(.failed(f))
        }
    }

    private func ended(code: UInt16?, error: NWError?) {
        generation += 1
        let wasAuthed = authed
        teardown()
        if let f = deniedWith { publish(.failed(f)); return }
        switch code {
        case 4003?: publish(.failed(.kicked(byeReason))); return
        case 4004?: hostRestarting = true; scheduleReconnect(); return
        case 4001?: publish(.failed(.denied)); return
        case 4005?: publish(.failed(.busy)); return
        case 4000?, 4002?, 1002?, 1003?, 1007?, 1009?:
            publish(.failed(.protocolError("closed with code \(code!)"))); return
        default: break
        }
        if everConnected {
            scheduleReconnect()
        } else if let error, error.isTLS {
            publish(.failed(.tls(error.localizedDescription)))
        } else if let error, error.isOffline {
            publish(.failed(.offline))
        } else {
            let detail = error?.localizedDescription ?? (wasAuthed || helloSeen ? "the connection closed" : nil)
            publish(.failed(.unreachable(detail)))
        }
    }

    private func scheduleReconnect() {
        publish(.reconnecting(restarting: hostRestarting))
        let delay = min(10, 0.4 * pow(2, Double(min(retry, 10))))
        retry += 1
        let gen = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.open(initial: false)
        }
    }

    /// Drops the socket and everything that belongs to a session.
    private func teardown() {
        socket?.close()
        socket = nil
        lock.lock()
        live = nil
        lock.unlock()
        authed = false
        streaming = false
        stream = nil
        pingTimer?.cancel()
        pingTimer = nil
        decoder.invalidate()
        audio?.close()
        audio = nil
        hostHasAudio = false
        uploads.cancelAll(reason: "connection lost")
    }

    private func publish(_ s: State) {
        switch s {
        case .connected, .reconnecting:
            if activity == nil {
                // Timer/IO precision for the whole session; idle system sleep stays allowed
                // (a forgotten session shouldn't keep a laptop awake — it reconnects after wake).
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Remote desktop session")
            }
        case .idle, .failed, .connecting:
            if let a = activity {
                ProcessInfo.processInfo.endActivity(a)
                activity = nil
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state = s
            self.delegate?.clientStateChanged(self)
        }
    }

    private func emit(_ e: Event) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.client(self, received: e)
        }
    }

    // MARK: - messages (queue)

    private func onMessage(_ m: Incoming) {
        switch m.type {
        case "hello": onHello(m)
        case "ok": onOK(m)
        case "denied": onDenied(m)
        case "bye": byeReason = m.string("reason")
        case "stream": onStream(m)
        case "pong":
            guard let c = m.double("c"), let s = m.double("s") else { return }
            let now = Clock.nowMs()
            lock.lock()
            clock.pong(c: c, s: s, now: now)
            lock.unlock()
        case "stats":
            let h = HostStats(fps: m.double("fps") ?? 0, kbps: m.double("kbps") ?? 0, captureMs: m.double("cap_ms") ?? 0,
                              encodeMs: m.double("enc_ms") ?? 0, targetKbps: m.double("br") ?? 0,
                              rtt: m.double("rtt") ?? 0, queueMs: m.double("q") ?? 0)
            lock.lock()
            counters.host = h
            lock.unlock()
        case "cur":
            guard let id = m.int("id") else { return }
            emit(.cursor(Cursor(id: id, png: m.data("png"), width: m.int("w") ?? 0, height: m.int("h") ?? 0,
                                hotX: m.int("hx") ?? 0, hotY: m.int("hy") ?? 0)))
        case "audio":
            onAudio(m)
        case "clip":
            guard let text = m.string("text") else { return }
            let initial = !clipSeen
            clipSeen = true
            emit(.clipboard(text, initial: initial))
        case "modes":
            emit(.modes(Modes(output: m.string("output"), current: m.mode("current"), native: m.mode("native"),
                              modes: m.modes("modes"), changed: m.bool("changed") ?? false)))
        case "screen":
            if let w = m.int("w"), let h = m.int("h"), w > 0, h > 0 { emit(.screen(DisplayMode(w, h))) }
        case "notice":
            if let t = m.string("text"), !t.isEmpty { emit(.notice(t, error: m.string("level") == "error")) }
        case "fok", "fack", "fdone", "ferr":
            uploads.handle(m)
        default:
            break                                   // unknown types are ignored (PROTOCOL.md §1)
        }
    }

    private func onHello(_ m: Incoming) {
        guard !helloSeen else { return }
        helloSeen = true
        helloHost = m.string("host")
        guard let kdf = m.object("kdf"), (kdf.string("alg") ?? "pbkdf2-sha256") == "pbkdf2-sha256",
              let saltText = kdf.string("salt"), let salt = Data(base64Encoded: saltText),
              let iter = kdf.int("iter"), let nonce = m.data("nonce"), nonce.count >= 16 else {
            fail(.protocolError("unsupported sign-in"))
            return
        }
        let k: Data
        if let pw = password {
            password = nil
            do {
                k = try Auth.deriveKey(password: pw, salt: salt, iterations: iter)
            } catch {
                fail(.protocolError("unsafe sign-in parameters"))
                return
            }
            key = SavedKey(key: k, salt: saltText, iter: iter)
            keyIsNew = true
            usedPassword = true
        } else if let saved = key {
            guard saved.salt == saltText, saved.iter == iter else {
                key = nil
                emit(.forgetKey)
                fail(.passwordChanged)
                return
            }
            k = saved.key
            usedPassword = false
        } else {
            fail(.needPassword)
            return
        }
        socket?.send(text: Msg.auth(proof: Auth.proof(key: k, nonce: nonce), client: Auth.clientName()) ?? "")
    }

    private func onOK(_ m: Incoming) {
        guard helloSeen, !authed, let s = socket else { return }
        authed = true
        everConnected = true
        retry = 0
        hostRestarting = false
        clipSeen = false
        lock.lock()
        live = s
        clock = ClockSync()
        counters = Counters()
        counters.since = Clock.nowMs()
        lock.unlock()
        let screen = m.object("screen").flatMap { o -> DisplayMode? in
            guard let w = o.int("w"), let h = o.int("h"), w > 0, h > 0 else { return nil }
            return DisplayMode(w, h)
        }
        emit(.welcome(Welcome(sid: m.string("sid") ?? "", hostName: helloHost, screen: screen, encoder: m.string("enc"),
                              gpu: m.string("gpu"), url: m.string("url"),
                              caps: (m["caps"] as? [Any])?.compactMap { $0 as? String } ?? [])))
        if keyIsNew, let key {
            keyIsNew = false
            emit(.authenticated(key))
        }
        publish(.connected)
        lastInbound = Clock.nowMs()
        startPing()
        if wantVideo { sendStart() }
        uploads.pump()
        hostHasAudio = ((m["caps"] as? [Any]) ?? []).contains { $0 as? String == "audio" }
        if wantAudio && hostHasAudio { socket?.send(text: Msg.audio(on: true)) }
    }

    /// The host's answer to `audio on`: a token for `/audio`, or an error.
    private func onAudio(_ m: Incoming) {
        guard authed, wantAudio, let token = m.string("token"), let sink = audioSink else {
            if let e = m.string("error") { emit(.notice("No sound from the remote computer (\(e)).", error: false)) }
            return
        }
        audio?.close()
        let gen = generation
        audio = AudioStream(url: address.audioURL, userAgent: Self.userAgent, proxy: proxy, token: token, sink: sink) {
            [weak self] wasPlaying in
            // The sound socket ended while the session goes on: ask again, unless it was refused.
            guard wasPlaying else { return }
            self?.queue.asyncAfter(deadline: .now() + 1) {
                guard let self, self.generation == gen, self.authed, self.wantAudio, self.hostHasAudio else { return }
                self.socket?.send(text: Msg.audio(on: true))
            }
        }
    }

    private func onDenied(_ m: Incoming) {
        let retry = max(0, m.int("retry") ?? 0)
        switch m.string("reason") {
        case "password":
            key = nil
            if usedPassword {
                deniedWith = .wrongPassword(retry: retry)
            } else {
                emit(.forgetKey)
                deniedWith = .savedKeyExpired
            }
        case "locked": deniedWith = .locked(retry: retry)
        case "no_password": deniedWith = .noPassword
        case "busy": deniedWith = .busy
        default: deniedWith = .denied
        }
    }

    /// Ends the session with a failure that reconnecting can't fix.
    private func fail(_ f: Failure) {
        generation += 1
        teardown()
        publish(.failed(f))
    }

    private func startPing() {
        pingTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        pingTimer = t
        ping()
    }

    private func tick() {
        guard authed else { return }
        if Clock.nowMs() - lastInbound > 6000 {   // three pongs missing: the connection is dead
            ended(code: nil, error: nil)
            return
        }
        ping()
    }

    private func ping() { socket?.send(text: Msg.ping(Clock.nowMs())) }

    // MARK: - video (queue)

    private func sendStart() {
        streaming = true
        socket?.send(text: Msg.start(fps: fps, bitrate: bitrate))
    }

    private func onStream(_ m: Incoming) {
        guard let id = m.int("id"), (0...0xFFFF).contains(id), let w = m.int("w"), let h = m.int("h"),
              w > 0, h > 0 else { return }
        let info = StreamInfo(id: UInt16(id), width: w, height: h, fps: m.int("fps") ?? fps, encoder: m.string("enc") ?? "")
        stream = info
        decoder.requireKeyFrame()
        needKeySince = Clock.nowMs()
        lock.lock()
        counters.stream = info
        lock.unlock()
        emit(.stream(info))
    }

    private func onVideo(_ d: Data) {
        d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            guard let h = VideoHeader(b), let st = stream, h.stream == st.id else { return }   // superseded stream
            lock.lock()
            counters.bytes += b.count
            lock.unlock()
            guard wantVideo else {
                ack(h.stream, h.seq)
                let now = Clock.nowMs()
                if !streaming && now - lastStop > 1000 {      // our stop crossed a (re)start: say it again
                    lastStop = now
                    socket?.send(text: Msg.stop)
                }
                return
            }
            let wasWaiting = decoder.needKey
            switch decoder.decode(h, payload: UnsafeRawBufferPointer(rebasing: b[VideoHeader.size...])) {
            case .submitted:
                if wasWaiting {
                    lock.lock()
                    counters.hardware = decoder.isHardwareAccelerated
                    lock.unlock()
                }
            case .skipped:
                ack(h.stream, h.seq)
                if decoder.needKey { wantKeyFrame(urgent: false) }
            case .failed:
                ack(h.stream, h.seq)
                decodeFailed()
            }
        }
    }

    private func ack(_ stream: UInt16, _ seq: UInt32) {
        socket?.send(text: Msg.ack(stream: stream, seq: seq))
    }

    /// VideoToolbox output thread: exactly once per submitted frame.
    private func decoded(_ f: H264Decoder.Frame, _ image: CVImageBuffer?, _ status: OSStatus) {
        if status == noErr, let image { sink?.display(image) }
        let now = Clock.nowMs()
        lock.lock()
        let s = live
        if status == noErr && image != nil {
            counters.frames += 1
            counters.framesTotal += 1
            let ms = now - f.submittedMs
            counters.decodeMs = counters.framesTotal == 1 ? ms : counters.decodeMs * 0.9 + ms * 0.1
            if !f.isRefresh, let l = clock.latency(captureUs: f.captureUs, now: now) { counters.latency = l }
        }
        lock.unlock()
        s?.send(text: Msg.ack(stream: f.stream, seq: f.seq))
        if status != noErr {
            queue.async { [weak self] in self?.decodeFailed() }
        }
    }

    private func decodeFailed() {
        guard authed else { return }
        let now = Clock.nowMs()
        if now - lastDecodeError > 250 {             // one burst counts once
            decodeErrors = decodeErrors.filter { now - $0 < 10_000 } + [now]
            if decodeErrors.count > 6 && !warnedDecoder {
                warnedDecoder = true
                emit(.notice("The video keeps failing to decode. Still trying…", error: true))
            }
        }
        lastDecodeError = now
        if !decoder.needKey { needKeySince = now }
        decoder.requireKeyFrame()
        wantKeyFrame(urgent: true)
    }

    /// `kf`, at most once a second (the host rate-limits too). Non-urgent requests wait a
    /// moment so a stream's own first key frame isn't doubled.
    private func wantKeyFrame(urgent: Bool) {
        let now = Clock.nowMs()
        if !urgent && now - needKeySince < 300 { return }
        guard now - lastKeyRequest >= 1000 else { return }
        lastKeyRequest = now
        socket?.send(text: Msg.kf)
    }

    static let userAgent: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "DarpanMac/\(DarpanVersion.string) (macOS \(v.majorVersion).\(v.minorVersion))"
    }()

    private struct Counters {
        var since = 0.0
        var frames = 0
        var bytes = 0
        var framesTotal = 0
        var decodeMs = 0.0
        var latency: Double?
        var host: HostStats?
        var stream: StreamInfo?
        var hardware = false
    }
}

/// File uploads (PROTOCOL.md §7): one file at a time, 256 KiB chunks, at most 512 KiB
/// un-acknowledged. Runs on its own utility queue so reading never delays video.
final class Uploader {
    weak var client: Client?
    private let queue = DispatchQueue(label: "dev.darpan.Darpan.upload", qos: .utility)
    private var pending: [URL] = []
    private var current: Item?
    private var nextId: UInt32 = 1

    private final class Item {
        let id: UInt32
        let url: URL
        let name: String
        let size: Int64
        var handle: FileHandle?
        var sent: Int64 = 0
        var acked: Int64 = 0
        var started = false
        var lastPercent = -1
        init(id: UInt32, url: URL, name: String, size: Int64) {
            self.id = id; self.url = url; self.name = name; self.size = size
        }
    }

    func enqueue(_ urls: [URL]) {
        queue.async {
            self.pending += urls
            self.pumpLocked()
        }
    }

    func pump() { queue.async { self.pumpLocked() } }

    func cancelAll(reason: String) {
        queue.async {
            if let c = self.current {
                self.client?.send(Msg.fabort(id: c.id))
                try? c.handle?.close()
                self.report(.failed(name: c.name, reason: reason))
            }
            self.current = nil
            for u in self.pending { self.report(.failed(name: u.lastPathComponent, reason: reason)) }
            self.pending.removeAll()
        }
    }

    func handle(_ m: Incoming) {
        guard let id = m.int("id") else { return }
        queue.async {
            guard let c = self.current, Int(c.id) == id else { return }
            switch m.type {
            case "fok":
                c.started = true
                self.sendChunks(c)
            case "fack":
                c.acked = Int64(m.int("n") ?? 0)
                let pct = c.size > 0 ? Int(100 * c.acked / c.size) : 100
                if pct != c.lastPercent {
                    c.lastPercent = pct
                    self.report(.progress(name: c.name, fraction: Double(pct) / 100))
                }
                self.sendChunks(c)
            case "fdone":
                try? c.handle?.close()
                self.current = nil
                self.report(.done(name: c.name, path: m.string("path") ?? c.name))
                self.pumpLocked()
            case "ferr":
                try? c.handle?.close()
                self.current = nil
                self.report(.failed(name: c.name, reason: m.string("e") ?? "rejected"))
                self.pumpLocked()
            default:
                break
            }
        }
    }

    private func pumpLocked() {
        guard current == nil, let client, client.isAuthenticated else { return }
        while !pending.isEmpty {
            let url = pending.removeFirst()
            let name = url.lastPathComponent
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey])
            guard v?.isRegularFile == true, let size = v?.fileSize else {
                report(.failed(name: name, reason: v?.isDirectory == true ? "folders can’t be sent — zip it first"
                                                                          : "not a readable file"))
                continue
            }
            guard let h = try? FileHandle(forReadingFrom: url) else {
                report(.failed(name: name, reason: "can’t read the file"))
                continue
            }
            let item = Item(id: nextId, url: url, name: name, size: Int64(size))
            nextId = nextId &+ 1
            item.handle = h
            current = item
            report(.progress(name: name, fraction: 0))
            client.send(Msg.fput(id: item.id, name: name, size: item.size))
            return
        }
    }

    private func sendChunks(_ c: Item) {
        guard c.started, current === c, let h = c.handle else { return }
        while c.sent < c.size && c.sent - c.acked < Int64(FileChunk.window) {
            let n = Int(min(Int64(FileChunk.maxData), c.size - c.sent))
            guard let data = try? h.read(upToCount: n), data.count == n else {
                client?.send(Msg.fabort(id: c.id))
                try? h.close()
                current = nil
                report(.failed(name: c.name, reason: "the file changed while sending"))
                pumpLocked()
                return
            }
            guard client?.sendBinary(FileChunk.message(id: c.id, data: data)) == true else { return }
            c.sent += Int64(n)
        }
    }

    private func report(_ u: Client.Upload) {
        guard let client else { return }
        DispatchQueue.main.async { [weak client] in
            guard let client else { return }
            client.delegate?.client(client, received: .upload(u))
        }
    }
}
