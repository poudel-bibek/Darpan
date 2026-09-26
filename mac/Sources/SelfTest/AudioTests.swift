import AVFoundation
import DarpanCore
import Foundation

/// 10 ms Opus packets of a sine wave, encoded with AudioToolbox (the host uses libopus; same format).
private func opusPackets(hz: Double, seconds: Double) -> [Data] {
    let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    var d = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                        mFramesPerPacket: 480, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
    let opus = AVAudioFormat(streamDescription: &d)!
    guard let enc = AVAudioConverter(from: pcm, to: opus) else { return [] }
    enc.bitRate = 128_000
    let n = AVAudioFrameCount(48000 * seconds)
    let src = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: n)!
    src.frameLength = n
    for c in 0..<2 { for i in 0..<Int(n) { src.floatChannelData![c][i] = Float(0.5 * sin(2 * .pi * hz * Double(i) / 48000)) } }
    var packets: [Data] = []
    var fed = false
    while true {
        let out = AVAudioCompressedBuffer(format: opus, packetCapacity: 8, maximumPacketSize: 1500)
        var err: NSError?
        let st = enc.convert(to: out, error: &err) { _, s in
            if fed { s.pointee = .endOfStream; return nil }
            fed = true
            s.pointee = .haveData
            return src
        }
        for i in 0..<Int(out.packetCount) {
            let p = out.packetDescriptions![i]
            packets.append(Data(bytes: out.data + Int(p.mStartOffset), count: Int(p.mDataByteSize)))
        }
        if st != .haveData || out.packetCount == 0 { break }
    }
    return packets
}

func audioTests() {
    section("AUDIO header") {
        let h = AudioHeader(flags: AudioHeader.flagAfterSilence, seq: 0x0102_0304, captureUs: 0x1122_3344_5566_7788)
        var msg = h.bytes
        eq(msg.count, AudioHeader.size, "14 bytes")
        eq(hex(msg), "0301010203041122334455667788", "big-endian layout")
        msg.append(0xAA)
        let back = msg.withUnsafeBytes { AudioHeader($0) }
        eq(back, h, "round trip")
        check(back?.afterSilence == true, "after-silence flag")
        check(h.bytes.withUnsafeBytes { AudioHeader($0) } == nil, "header without a packet refused")
        check(Data([0x01] + [UInt8](repeating: 0, count: 14)).withUnsafeBytes { AudioHeader($0) } == nil, "other kinds refused")
    }

    section("Opus decode (AudioToolbox)") {
        let packets = opusPackets(hz: 440, seconds: 1)
        check(packets.count >= 100, "encoded \(packets.count) packets")
        guard let dec = OpusDecoder() else { return check(false, "decoder available") }
        var samples: [Float] = []
        let t0 = Clock.nowMs()
        for p in packets {
            guard let s = p.withUnsafeBytes({ dec.decode($0) }) else { return check(false, "packet decodes") }
            samples += s
        }
        let ms = (Clock.nowMs() - t0) / Double(packets.count)
        check(samples.count / 2 >= 48000, "about 1 s decoded (\(samples.count / 2) frames)")
        var crossings = 0
        var last: Float = 0
        for i in stride(from: 0, to: samples.count, by: 2) {
            if last < 0 && samples[i] >= 0 { crossings += 1 }
            last = samples[i]
        }
        let hz = Double(crossings) / (Double(samples.count / 2) / 48000)
        check(abs(hz - 440) < 5, String(format: "pitch preserved (%.0f Hz)", hz))
        check(samples.map { abs($0) }.max()! > 0.4, "level preserved")
        check(ms < 1, String(format: "decode %.3f ms per 10 ms packet", ms))
        check(Data().withUnsafeBytes { dec.decode($0) } == nil, "empty packet refused")
    }

    section("jitter buffer") {
        let j = JitterBuffer(rate: 48000)
        var l = [Float](repeating: 1, count: 480), r = l
        let packet = [Float](repeating: 0.25, count: 960)          // 10 ms stereo
        func pull(_ n: Int = 480) { l = [Float](repeating: 1, count: n); r = l; j.pull(frames: n, left: &l, right: &r) }

        j.push(packet, afterSilence: true)
        pull()
        check(l.allSatisfy { $0 == 0 }, "priming: silence until 40 ms are buffered")
        for _ in 0..<3 { j.push(packet, afterSilence: false) }
        pull()
        check(l.allSatisfy { $0 == 0.25 } && r.allSatisfy { $0 == 0.25 }, "plays once the target is buffered")
        eq(j.stats.underruns, 0, "no underrun yet")
        pull(); pull(); pull()                                        // 40 ms buffered, 40 ms pulled
        pull()
        check(l.last == 0, "silence while dry")
        eq(j.stats.underruns, 0, "running dry alone isn't an underrun (could be silence)")
        j.push(packet, afterSilence: false)
        eq(j.stats.underruns, 1, "a late packet (no FIRST) after running dry is one")
        check(abs(j.stats.target - 0.050) < 1e-9, "and adds 10 ms to the target")

        // Silence: dry, then the next packet has FIRST: no underrun, target unchanged.
        let q = JitterBuffer(rate: 48000)
        for _ in 0..<4 { q.push(packet, afterSilence: false) }
        for _ in 0..<5 { l = [Float](repeating: 1, count: 480); r = l; q.pull(frames: 480, left: &l, right: &r) }
        q.push(packet, afterSilence: true)
        eq(q.stats.underruns, 0, "silence then FIRST: no underrun")
        check(abs(q.stats.target - 0.040) < 1e-9, "target unchanged after silence")

        for _ in 0..<4 { j.push(packet, afterSilence: false) }        // 50 ms: primed again
        pull()
        check(l.allSatisfy { $0 == 0.25 }, "resumes at the new target")

        // Too much buffered: one sample in 256 is dropped until it's back near the target.
        let k = JitterBuffer(rate: 48000)
        for _ in 0..<20 { k.push(packet, afterSilence: false) }       // 200 ms vs. a 40 ms target
        let before = k.stats.depth
        l = [Float](repeating: 0, count: 4800); r = l
        k.pull(frames: 4800, left: &l, right: &r)
        check(k.stats.adjusted >= 18, "drift: samples dropped (\(k.stats.adjusted))")
        check(before - k.stats.depth > 0.100, "drained faster than played")

        k.push(packet, afterSilence: true)
        check(abs(k.stats.depth - 0.010) < 1e-9, "after silence: the buffer starts over")

        // The target shrinks again after 10 s without an underrun.
        let m = JitterBuffer(rate: 1000)                              // small rate: 10 s = 10 000 frames
        m.push([Float](repeating: 0.1, count: 2 * 40), afterSilence: true)
        var ml = [Float](repeating: 0, count: 60), mr = ml
        m.pull(frames: 60, left: &ml, right: &mr)                     // runs dry…
        m.push([Float](repeating: 0.1, count: 2 * 10), afterSilence: false)   // …and audio was late: 50 ms
        let grown = m.stats.target
        for _ in 0..<5 { m.push([Float](repeating: 0.1, count: 2 * 10), afterSilence: false) }   // back at the target
        for _ in 0..<1100 {                                           // 11 s of steady 10 ms packets
            m.push([Float](repeating: 0.1, count: 2 * 10), afterSilence: false)
            var a = [Float](repeating: 0, count: 10), b = a
            m.pull(frames: 10, left: &a, right: &b)
        }
        eq(m.stats.underruns, 1, "no more underruns at a steady rate")
        check(m.stats.target < grown, String(format: "target shrinks after quiet time (%.3f → %.3f s)", grown, m.stats.target))
    }
}
