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

    public init?() {
        var d = AudioStreamBasicDescription(mSampleRate: Self.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                            mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.frameSamples), mBytesPerFrame: 0,
                                            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &d), let c = AVAudioConverter(from: opus, to: pcm) else { return nil }
        self.opus = opus
        converter = c
    }

    /// One packet → interleaved stereo samples (L R L R …), or nil if it didn't decode.
    public func decode(_ packet: UnsafeRawBufferPointer) -> [Float]? {
        guard !packet.isEmpty else { return nil }
        let input = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: packet.count)
        input.data.copyMemory(from: packet.baseAddress!, byteCount: packet.count)
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                    mDataByteSize: UInt32(packet.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(Self.frameSamples * 2)) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, s in
            if given { s.pointee = .noDataNow; return nil }
            given = true
            s.pointee = .haveData
            return input
        }
        guard status != .error, out.frameLength > 0, let p = out.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength) * 2))
    }
}

/// Decoded audio waiting to be played: written from the network queue, read from the real-time
/// render callback (critical sections are a few copies under a lock).
///
/// It aims for `target` of buffered audio (40 ms to start). An underrun plays silence and makes
/// the target 10 ms larger (up to 200 ms); 10 s without one makes it 5 ms smaller again. Clock
/// drift between the two computers is absorbed by dropping or repeating one sample in 256 while
/// the level strays more than 20 ms from the target. After silence (or at the start) playback waits
/// until the target is buffered again.
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
    private var underruns = 0, adjusted = 0
    private var sinceUnderrun = 0         // frames played since the last underrun
    private var drift = 0                 // frames played since the last drift correction

    public init(rate: Double = OpusDecoder.sampleRate) {
        self.rate = rate
        target = Self.minTarget
        ring = [Float](repeating: 0, count: Int(rate * Self.maxTarget * 2) * 2)
    }

    private var capacity: Int { ring.count / 2 }

    /// Network side. `afterSilence` restarts buffering (the stretch before it was silent anyway).
    public func push(_ samples: [Float], afterSilence: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if afterSilence { head = 0; count = 0; priming = true }
        let frames = samples.count / 2
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
            if i < frames {                                // ran dry: wait for more, with more margin
                underruns += 1
                target = min(Self.maxTarget, target + 0.010)
                priming = true
                sinceUnderrun = 0
            } else if Double(sinceUnderrun) > 10 * rate && target > Self.minTarget {
                target = max(Self.minTarget, target - 0.005)
                sinceUnderrun = 0
            }
        }
        while i < frames { left[i] = 0; right[i] = 0; i += 1 }
    }

    public var stats: Stats {
        lock.lock()
        defer { lock.unlock() }
        return Stats(depth: Double(count) / rate, target: target, underruns: underruns, adjusted: adjusted)
    }
}
