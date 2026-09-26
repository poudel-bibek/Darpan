import AVFoundation
import DarpanCore

/// Plays the remote computer's sound: decoded packets go into a jitter buffer that an
/// AVAudioSourceNode drains on the real-time thread. The engine runs only while sound arrives,
/// and stops after 2 s without packets, so the Mac's audio device is left alone during silence.
final class AudioPlayer: AudioSink {
    let buffer = JitterBuffer()
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var running = false                        // lock: the engine is (being) started
    private var node: AVAudioSourceNode!
    private var idleTimer: Timer?                      // main

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: OpusDecoder.sampleRate, channels: 2)!
        node = AVAudioSourceNode(format: format) { [buffer] _, _, frames, list in
            let abl = UnsafeMutableAudioBufferListPointer(list)
            guard abl.count == 2, let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            buffer.pull(frames: Int(frames), left: l, right: r)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        #if DEBUG
        if ProcessInfo.processInfo.environment["DARPAN_DEBUG_MUTE"] != nil { engine.mainMixerNode.outputVolume = 0 }
        #endif
    }

    func play(_ samples: [Float], first: Bool, silentFrames: Int) {
        buffer.push(samples, afterSilence: first, silentFrames: silentFrames)
        lock.lock()
        let needStart = !running
        running = true
        lock.unlock()
        if needStart { DispatchQueue.main.async { self.start() } }
    }

    /// Main thread.
    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        if engine.isRunning { engine.stop() }
        lock.lock()
        running = false
        lock.unlock()
    }

    private func start() {
        if !engine.isRunning { try? engine.start() }
        guard idleTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.buffer.idleMs > 2000 else { return }
            self.stop()
        }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }
}
