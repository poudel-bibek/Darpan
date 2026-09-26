import AVFoundation
import Foundation

/// 14-byte big-endian header of a binary AUDIO message: `u8 0x03 | u8 flags | u32 seq | u64 capture_us`,
/// then one Opus packet. `seq` counts 10 ms slots, so a jump is that much silence the host didn't send.
public struct AudioHeader: Equatable {
    public static let size = 14
    public static let kind: UInt8 = 0x03
    /// First packet after a stretch of silence: the jitter buffer starts over.
    public static let flagAfterSilence: UInt8 = 0x01

    public var flags: UInt8
    public var seq: UInt32
    public var captureUs: UInt64

    public var afterSilence: Bool { flags & Self.flagAfterSilence != 0 }

    public init(flags: UInt8, seq: UInt32, captureUs: UInt64) {
        self.flags = flags; self.seq = seq; self.captureUs = captureUs
    }

    public init?(_ b: UnsafeRawBufferPointer) {
        guard b.count > Self.size, b[0] == Self.kind else { return nil }
        func be(_ o: Int, _ n: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<n { v = (v << 8) | UInt64(b[o + k]) }
            return v
        }
        flags = b[1]
        seq = UInt32(be(2, 4))
        captureUs = be(6, 8)
    }

    public var bytes: Data {
        var d = Data([Self.kind, flags])
        for s in stride(from: 24, through: 0, by: -8) { d.append(UInt8((seq >> UInt32(s)) & 0xFF)) }
        for s in stride(from: 56, through: 0, by: -8) { d.append(UInt8((captureUs >> UInt64(s)) & 0xFF)) }
        return d
    }
}

/// Opus packets → 48 kHz stereo float PCM, through AudioToolbox (no third-party code).
public final class OpusDecoder {
    public static let sampleRate = 48_000.0
    public static let frameSamples = 480                    // 10 ms

    public let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: true)!
    private let opus: AVAudioFormat
    private let converter: AVAudioConverter
    private let input: AVAudioCompressedBuffer            // reused: one packet at a time
    private let output: AVAudioPCMBuffer

    public init?() {
        var d = AudioStreamBasicDescription(mSampleRate: Self.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                            mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.frameSamples), mBytesPerFrame: 0,
                                            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &d), let c = AVAudioConverter(from: opus, to: pcm) else { return nil }
        self.opus = opus
        converter = c
        input = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: 1500)
        output = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(Self.frameSamples * 2))!
    }

    /// One packet → interleaved stereo samples (L R L R …), or nil if it didn't decode.
    public func decode(_ packet: UnsafeRawBufferPointer) -> [Float]? {
        guard !packet.isEmpty, packet.count <= 1500 else { return nil }
        input.data.copyMemory(from: packet.baseAddress!, byteCount: packet.count)
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                    mDataByteSize: UInt32(packet.count))
        let out = output
        out.frameLength = 0
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, s in
            if given { s.pointee = .noDataNow; return nil }
            given = true
            s.pointee = .haveData
            return self.input
        }
        guard status != .error, out.frameLength > 0, let p = out.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength) * 2))
    }
}

/// Decoded audio waiting to be played: written from the network queue, read from the real-time
/// render callback (critical sections are a few copies under a lock).
///
/// It aims for `target` of buffered audio (40 ms to start). Running dry plays silence; if the next
/// packet then arrives without FIRST, audio was late (an underrun), and the target grows by 10 ms
/// (up to 200 ms). With FIRST it was just silence. 10 s without an underrun shrinks it by 5 ms. Clock
/// drift between the two computers is absorbed by dropping or repeating one sample in 256 while
/// the level strays more than 20 ms from the target. After silence the skipped slots are appended
/// as silence while audio is still buffered, so pauses keep their length; playback waits for the
/// target again only when the buffer had run empty.
public final class JitterBuffer {
    public static let minTarget = 0.040, maxTarget = 0.200

    public struct Stats: Equatable {
        public var depth: Double          // seconds buffered
        public var target: Double
        public var underruns: Int
        public var adjusted: Int          // samples dropped or repeated for drift
    }

    private let rate: Double
    private let lock = NSLock()
    private var ring: [Float]             // interleaved stereo
    private var head = 0, count = 0       // in frames
    private var target: Double
    private var priming = true
    private var dry = false               // ran out while playing; the next packet tells why
    private var underruns = 0, adjusted = 0
    private var sinceUnderrun = 0         // frames played since the last underrun
    private var drift = 0                 // frames played since the last drift correction
    private var lastPush = -1e9           // Clock.nowMs

    public init(rate: Double = OpusDecoder.sampleRate) {
        self.rate = rate
        target = Self.minTarget
        ring = [Float](repeating: 0, count: Int(rate * Self.maxTarget) * 2)
    }

    private var capacity: Int { ring.count / 2 }

    /// Network side. `afterSilence`: the first packet after `silentFrames` of nothing (FIRST).
    public func push(_ samples: [Float], afterSilence: Bool, silentFrames: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        lastPush = Clock.nowMs()
        if dry && !afterSilence {                           // late, not silent: more margin
            underruns += 1
            target = min(Self.maxTarget, target + 0.010)
            sinceUnderrun = 0
        }
        dry = false
        let frames = samples.count / 2
        if afterSilence {
            if count > 0 && count + silentFrames + frames <= capacity {
                for _ in 0..<silentFrames {                // keep the pause's length
                    let w = (head + count) % capacity
                    ring[w * 2] = 0
                    ring[w * 2 + 1] = 0
                    count += 1
                }
            } else {
                head = 0; count = 0; priming = true
            }
        }
        for i in 0..<frames {
            if count == capacity {                         // far behind: drop the oldest
                head = (head + 1) % capacity
                count -= 1
            }
            let w = (head + count) % capacity
            ring[w * 2] = samples[i * 2]
            ring[w * 2 + 1] = samples[i * 2 + 1]
            count += 1
        }
        if priming && Double(count) >= target * rate { priming = false }
    }

    /// Render side: fills `frames` stereo frames into `left`/`right` (silence where there's nothing).
    public func pull(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        var i = 0
        if !priming {
            let high = Double(count) > (target + 0.020) * rate
            let low = Double(count) < (target - 0.020) * rate
            while i < frames && count > 0 {
                drift += 1
                if drift >= 256 && (high || low) {
                    drift = 0
                    adjusted += 1
                    if high {                              // drop one sample
                        head = (head + 1) % capacity
                        count -= 1
                        if count == 0 { break }
                    } else {                               // repeat one sample
                        left[i] = ring[head * 2]; right[i] = ring[head * 2 + 1]
                        i += 1
                        continue
                    }
                }
                left[i] = ring[head * 2]; right[i] = ring[head * 2 + 1]
                head = (head + 1) % capacity
                count -= 1
                i += 1
            }
            sinceUnderrun += i
            if i < frames {                                // ran dry: re-prime; push() decides why
                priming = true
                dry = true
            } else if Double(sinceUnderrun) > 10 * rate && target > Self.minTarget {
                target = max(Self.minTarget, target - 0.005)
                sinceUnderrun = 0
            }
        }
        while i < frames { left[i] = 0; right[i] = 0; i += 1 }
    }

    /// Milliseconds since audio last arrived.
    public var idleMs: Double {
        lock.lock()
        defer { lock.unlock() }
        return Clock.nowMs() - lastPush
    }

    public var stats: Stats {
        lock.lock()
        defer { lock.unlock() }
        return Stats(depth: Double(count) / rate, target: target, underruns: underruns, adjusted: adjusted)
    }
}

/// Receives decoded audio. Called on the audio queue, in order.
public protocol AudioSink: AnyObject {
    /// `first`: FIRST flag; `silentFrames`: the silence before it (skipped slots).
    func play(_ samples: [Float], first: Bool, silentFrames: Int)
}

/// The `/audio` WebSocket of one session (PROTOCOL.md §12): signs in with the single-use token,
/// then decodes each AUDIO message into the sink. Its own connection and queue, so sound never
/// waits behind video.
final class AudioStream {
    private let queue = DispatchQueue(label: "dev.darpan.Darpan.audio", qos: .userInteractive)
    private var socket: WebSocket?
    private let decoder: OpusDecoder?
    private weak var sink: AudioSink?
    private var authed = false
    private var lastSlot: UInt32?
    private let onEnd: (_ retry: Bool, _ unavailable: Bool) -> Void
    private let onPlaying: () -> Void

    init(url: URL, userAgent: String, proxy: SOCKSProxy?, token: String, sink: AudioSink, onPlaying: @escaping () -> Void,
         onEnd: @escaping (_ retry: Bool, _ unavailable: Bool) -> Void) {
        decoder = OpusDecoder()
        self.sink = sink
        self.onPlaying = onPlaying
        self.onEnd = onEnd
        let ws = WebSocket(url: url, userAgent: userAgent, proxy: proxy, queue: queue) { [weak self] e in
            guard let self else { return }
            switch e {
            case .ready:
                if let auth = Msg.json(["t": "auth", "token": token]) { self.socket?.send(text: auth) }
            case .text(let d):
                if Incoming(d)?.type == "ok" { self.authed = true; self.onPlaying() }
            case .binary(let d):
                guard self.authed, let decoder = self.decoder else { return }
                d.withUnsafeBytes { b in
                    guard let h = AudioHeader(b),
                          let samples = decoder.decode(UnsafeRawBufferPointer(rebasing: b[AudioHeader.size...])) else { return }
                    // A slot jump of n means n − 1 silent slots (at most 1 s is kept).
                    let skipped = self.lastSlot.map { Int(min(100, max(1, h.seq &- $0)) - 1) } ?? 0
                    self.lastSlot = h.seq
                    self.sink?.play(samples, first: h.afterSilence, silentFrames: skipped * OpusDecoder.frameSamples)
                }
            case .waiting:
                break
            case .closed(let code, _):
                self.socket = nil
                self.onEnd(self.authed && code != 1011, code == 1011)   // 1011: the host can't capture sound
            }
        }
        socket = ws
        queue.async { ws.start() }
    }

    func close() {
        queue.async {
            self.socket?.close()
            self.socket = nil
        }
    }
}
