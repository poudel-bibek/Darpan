import Foundation

/// One computer's viewer settings, as kept in the preferences (a property list): what a window chooses
/// applies to its own computer only.
public struct ViewerPrefs: Equatable {
    /// Bitrates (kbit/s) a viewer can choose: the host encodes at the chosen one from the first frame and
    /// goes lower only while the network can't carry it. The same four as the browser.
    public static let qualities = [6000, 15000, 30000, 50000]
    public static let frameRates = [30, 60, 120]
    /// The keys stored, which were app-wide (one value for every computer) up to 1.4.3.
    public static let keys = ["scale", "quality", "fps", "fullGPU", "command", "scrollSpeed", "invertScroll",
                              "showStats", "captureSystemKeys", "sound"]

    public var scale = ScaleMode.fit
    /// The chosen bitrate in kbit/s (one of `qualities`).
    public var quality = 15000
    public var fps = 60
    /// Let the Linux computer use more of its GPU (NVENC through CUDA), for sharper fast scrolling.
    public var fullGPU = false
    public var command = CommandKey.ctrl
    public var scrollSpeed = 1.0
    public var invertScroll = false
    public var showStats = false
    /// ⌘Tab, ⌘Space, Mission Control… go to the remote too (needs Accessibility permission).
    public var captureSystemKeys = false
    /// Play the remote computer's sound.
    public var sound = true

    public init() {}

    /// From stored values; anything missing or out of range takes its default.
    public init(plist p: [String: Any]) {
        if let s = p["scale"] as? String, let m = ScaleMode(rawValue: s) { scale = m }
        if let q = p["quality"] as? Int { quality = Self.quality(q) }
        if let f = p["fps"] as? Int, Self.frameRates.contains(f) { fps = f }
        if let b = p["fullGPU"] as? Bool { fullGPU = b }
        if let s = p["command"] as? String, let c = CommandKey(rawValue: s) { command = c }
        if let v = p["scrollSpeed"] as? Double { scrollSpeed = min(3, max(0.25, v)) }
        if let b = p["invertScroll"] as? Bool { invertScroll = b }
        if let b = p["showStats"] as? Bool { showStats = b }
        if let b = p["captureSystemKeys"] as? Bool { captureSystemKeys = b }
        if let b = p["sound"] as? Bool { sound = b }
    }

    public var plist: [String: Any] {
        ["scale": scale.rawValue, "quality": quality, "fps": fps, "fullGPU": fullGPU, "command": command.rawValue,
         "scrollSpeed": scrollSpeed, "invertScroll": invertScroll, "showStats": showStats,
         "captureSystemKeys": captureSystemKeys, "sound": sound]
    }

    /// A saved quality from before the four choices → the nearest one now (the old Auto and 10 Mbit/s
    /// become Balanced).
    public static func quality(_ q: Int) -> Int {
        switch q {
        case 6000, 15000, 30000, 50000: return q
        case 3000: return 6000
        case 20000: return 30000
        default: return 15000                   // 0 (Auto), 10000, and anything unknown
        }
    }

    /// Upgrading from one set of settings for every computer: those settings, for each computer known.
    public static func migrate(global: [String: Any], to origins: some Sequence<String>) -> [String: [String: Any]] {
        let values = ViewerPrefs(plist: global).plist
        return Dictionary(origins.map { ($0, values) }, uniquingKeysWith: { a, _ in a })
    }
}
