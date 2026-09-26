import CoreGraphics
import Foundation

/// Scroll events → `wh` units (1/120 notch, `dy > 0` scrolls down).
///
/// AppKit's scrolling deltas describe how the *content* should move (natural scrolling already
/// applied); the protocol wants the scroll direction, hence the minus sign. Trackpads report
/// pixels (`hasPreciseScrollingDeltas`): 50 px ≈ one notch → ×2.4. Mouse wheels report lines:
/// one line = one notch → ×120. Fractions are kept for the next event.
public struct WheelAccumulator {
    public var speed: Double
    public var invert: Bool
    private var rx = 0.0, ry = 0.0

    public init(speed: Double = 1, invert: Bool = false) {
        self.speed = speed
        self.invert = invert
    }

    public static func factor(precise: Bool) -> Double { precise ? 2.4 : 120 }

    public mutating func add(deltaX: Double, deltaY: Double, precise: Bool) -> (dx: Int, dy: Int)? {
        guard deltaX.isFinite, deltaY.isFinite else { return nil }
        let k = Self.factor(precise: precise) * speed * (invert ? -1 : 1)
        rx -= deltaX * k
        ry -= deltaY * k
        let dx = Int(rx.rounded(.towardZero)), dy = Int(ry.rounded(.towardZero))
        guard dx != 0 || dy != 0 else { return nil }
        rx -= Double(dx)
        ry -= Double(dy)
        return (dx, dy)
    }

    public mutating func reset() { rx = 0; ry = 0 }
}

/// NSEvent.buttonNumber → protocol `b` (DOM numbering). Left 0, right 2, middle 1, back 3, forward 4.
public func protocolButton(_ buttonNumber: Int) -> Int? {
    switch buttonNumber {
    case 0: return 0
    case 1: return 2
    case 2: return 1
    case 3: return 3
    case 4: return 4
    default: return nil
    }
}

public enum ScaleMode: String, CaseIterable {
    case fit
    case actual
}

/// Where the video goes inside the viewer and how view points map to stream pixels.
/// Coordinates are top-left based (the viewer view is flipped).
public enum VideoGeometry {
    /// The video rectangle in view points.
    ///
    /// * `fit`: the largest aspect-correct rectangle, centred (letterboxed), snapped to device pixels.
    /// * `actual`: one stream pixel per device pixel. Along an axis where the video is larger than
    ///   the view it pans with the pointer, so the pointer's relative position in the view is its
    ///   relative position on the remote screen and every remote pixel stays reachable.
    public static func videoRect(mode: ScaleMode, stream: CGSize, bounds: CGSize,
                                 backingScale: CGFloat, pointer: CGPoint?) -> CGRect {
        guard stream.width > 0, stream.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = max(backingScale, 1)
        switch mode {
        case .fit:
            let s = min(bounds.width / stream.width, bounds.height / stream.height)
            let w = max(1, (stream.width * s * scale).rounded(.down)) / scale
            let h = max(1, (stream.height * s * scale).rounded(.down)) / scale
            let x = ((bounds.width - w) / 2 * scale).rounded() / scale
            let y = ((bounds.height - h) / 2 * scale).rounded() / scale
            return CGRect(x: x, y: y, width: w, height: h)
        case .actual:
            let w = stream.width / scale, h = stream.height / scale
            func origin(_ content: CGFloat, _ view: CGFloat, _ p: CGFloat?) -> CGFloat {
                if content <= view { return ((view - content) / 2 * scale).rounded() / scale }
                let f = min(max((p ?? view / 2) / view, 0), 1)
                return (-(content - view) * f * scale).rounded() / scale
            }
            return CGRect(x: origin(w, bounds.width, pointer?.x), y: origin(h, bounds.height, pointer?.y),
                          width: w, height: h)
        }
    }

    /// View point → stream pixel, clamped to the stream.
    public static func streamPoint(_ p: CGPoint, videoRect r: CGRect, streamWidth: Int, streamHeight: Int) -> (x: Int, y: Int) {
        guard r.width > 0, r.height > 0, streamWidth > 0, streamHeight > 0 else { return (0, 0) }
        let fx = ((p.x - r.minX) * CGFloat(streamWidth) / r.width).rounded(.down)
        let fy = ((p.y - r.minY) * CGFloat(streamHeight) / r.height).rounded(.down)
        let x = fx.isFinite ? Int(max(0, min(CGFloat(streamWidth - 1), fx))) : 0
        let y = fy.isFinite ? Int(max(0, min(CGFloat(streamHeight - 1), fy))) : 0
        return (x, y)
    }
}
