import CoreGraphics
import Foundation

/// A remote screen resolution (`modes`, `res`).
public struct DisplayMode: Hashable, CustomStringConvertible {
    public let w: Int
    public let h: Int
    public init(_ w: Int, _ h: Int) { self.w = w; self.h = h }
    public var description: String { "\(w)×\(h)" }

    /// Remote resolution that best fills a window of `pixels` (device pixels): must fit, and
    /// area counts less the more the aspect ratio differs. Same rule as the web client.
    public static func bestFor(window pixels: CGSize, among modes: [DisplayMode]) -> DisplayMode? {
        guard pixels.width > 0, pixels.height > 0 else { return nil }
        let ar = Double(pixels.width / pixels.height)
        var best: DisplayMode?
        var score = -1.0
        for m in modes where m.w > 0 && m.h > 0 && CGFloat(m.w) <= pixels.width && CGFloat(m.h) <= pixels.height {
            let s = Double(m.w * m.h) * (1 - min(0.9, abs(Double(m.w) / Double(m.h) - ar)))
            if s > score { score = s; best = m }
        }
        return best
    }
}

/// The host's desktop made exactly the viewer's size, drawn at a GNOME scale (PROTOCOL.md §8, `res.fit`):
/// one remote pixel per device pixel, so nothing is scaled on the way.
public struct Fit: Equatable, CustomStringConvertible {
    public let w: Int
    public let h: Int
    /// GNOME's scale, in %: 200 draws everything twice as large, like a Retina screen.
    public let scale: Int
    public init(_ w: Int, _ h: Int, scale: Int) { self.w = w; self.h = h; self.scale = scale }
    public var description: String { "\(w)×\(h)" }

    /// The host's limits: sizes from 640×480, and at most 4096 a side (H.264), both sides scaled down together.
    public static let maxSide = 4096

    /// What to ask for a view of `pixels` (device pixels): its size rounded down to even numbers (4:2:0);
    /// nil when it's smaller than the host takes.
    public static func request(pixels: CGSize, scale: Int) -> Fit? {
        let w = Int(pixels.width) / 2 * 2, h = Int(pixels.height) / 2 * 2
        return w >= 640 && h >= 480 ? Fit(w, h, scale: scale) : nil
    }

    /// Whether `fitted` (what the host made) answers this request, as the host shrinks a side over `maxSide`.
    public func isAnswered(by fitted: Fit?) -> Bool {
        guard let f = fitted, f.scale == scale else { return false }
        let k = min(1, Double(Self.maxSide) / Double(max(w, h)))
        return f.w == Int(Double(w) * k) / 2 * 2 && f.h == Int(Double(h) * k) / 2 * 2
    }

    /// The scale to draw at: the viewer's choice if the host offers it, else 200 % on a Retina screen and
    /// 100 % on a 1× one, else whatever the host offers; nil if it offers none.
    public static func scale(chosen: Int, backingScale: CGFloat, offered: [Int]) -> Int? {
        if offered.contains(chosen) { return chosen }
        let natural = backingScale >= 2 ? 200 : 100
        return offered.contains(natural) ? natural : offered.first
    }
}
