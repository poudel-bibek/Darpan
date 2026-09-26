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
