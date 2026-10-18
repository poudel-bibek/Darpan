import Foundation

/// What the display panel says is in effect: the latest `stream` and the host's bitrate target,
/// next to what the viewer chose, so a choice that didn't take (GPU memory full, say) shows.
public struct InEffect: Equatable {
    public let picture: String
    public let colour: String
    public let encoding: String
    public let bitrate: String?
    /// Chosen, but not in effect right now.
    public let notes: [String]

    /// The host gives 4:4:4 from this bitrate up, to a viewer that decodes it (PROTOCOL.md §8).
    public static let fullColourKbps = 25000

    public init(stream s: Client.StreamInfo, targetKbps: Double?, chosenKbps: Int, fullGPU: Bool, decodesFullColour: Bool) {
        let software = s.api == "software" || (s.api == nil && s.encoder == "x264")
        // Software encoding runs at 30 fps at most, whatever the stream says was asked for.
        picture = "\(s.width)×\(s.height), \(software ? min(s.fps, 30) : s.fps) fps"
        colour = s.chroma == 444 ? "Full colour (4:4:4)" : "Standard colour (4:2:0)"
        switch s.api {
        case "cuda": encoding = "On the GPU, using more of it (CUDA)"
        case "vulkan": encoding = "On the GPU (Vulkan)"
        default: encoding = software ? "On the processor (no GPU)" : "On the GPU"
        }
        bitrate = targetKbps.flatMap { t in
            guard t > 0 else { return nil }
            let now = String(format: "%.1f Mbit/s now", t / 1000)
            // Below the choice: the network, or an older host still climbing to it; just the numbers.
            return t < Double(chosenKbps) * 0.9 ? now + ", below the \(chosenKbps / 1000) chosen" : now
        }
        var notes: [String] = []
        if software { notes.append("The Linux computer is encoding on its processor: its GPU isn't available right now.") }
        if fullGPU && s.api == "vulkan" { notes.append("More GPU isn't in use right now.") }
        if decodesFullColour && chosenKbps >= Self.fullColourKbps && s.chroma != 444 && !software {
            notes.append("Full colour isn't in use right now.")
        }
        self.notes = notes
    }
}
