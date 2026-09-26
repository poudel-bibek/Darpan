import CoreGraphics
import CoreText
import CoreVideo
import DarpanCore
import Foundation
import ImageIO
import VideoToolbox

/// `--image`: shown as it is instead of the test pattern (screenshots with sample data).
var stillImage: CGImage?

/// What the test pattern shows besides motion: the last input the host received.
struct Scene {
    var pointer: (x: Int, y: Int)?
    var buttons = Set<Int>()
    var lastKey = ""
    var typed = ""
    var wheel = (dx: 0, dy: 0)
    var clip = ""
}

/// Draws the test pattern and encodes it with VideoToolbox (real time, no reordering, BT.709).
final class Encoder {
    let width: Int, height: Int
    private(set) var fps: Int
    private var session: VTCompressionSession?
    private var frame = 0
    private var forceKey = true
    private let output: (Data, Bool, UInt64, Double) -> Void     // Annex-B, key, capture µs, encode ms

    init?(width: Int, height: Int, fps: Int, kbps: Int, output: @escaping (Data, Bool, UInt64, Double) -> Void) {
        self.width = width
        self.height = height
        self.fps = fps
        self.output = output
        let src: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                    kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                    kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()]
        var s: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                         codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                         imageBufferAttributes: src as CFDictionary, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr, let s else { return nil }
        session = s
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 100_000 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        set(fps: fps, kbps: kbps)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit { invalidate() }

    func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    func set(fps: Int, kbps: Int) {
        guard let session else { return }
        self.fps = fps
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        let bps = (kbps > 0 ? kbps : 12_000) * 1000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
    }

    func keyFrame() { forceKey = true }

    /// Draws and submits one frame; `output` runs on a VideoToolbox thread.
    func encode(_ scene: Scene) {
        guard let session, let pool = VTCompressionSessionGetPixelBufferPool(session) else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return }
        let captureUs = UInt64(Clock.nowMs() * 1000)
        draw(scene, into: pb)
        frame += 1
        let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKey = false
        let submitted = Clock.nowMs()
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)),
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [output] status, _, sample in
            guard status == noErr, let sample, let (data, key) = Self.annexB(sample) else { return }
            output(data, key, captureUs, Clock.nowMs() - submitted)
        }
    }

    private static func annexB(_ sample: CMSampleBuffer) -> (Data, Bool)? {
        guard let fd = CMSampleBufferGetFormatDescription(sample), let bb = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(atts?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var len = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len,
                                          dataPointerOut: &ptr) == kCMBlockBufferNoErr, let ptr else { return nil }
        var params: [Data] = []
        var nalLen: Int32 = 4
        if key {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: &nalLen)
            for k in 0..<count {
                var p: UnsafePointer<UInt8>?
                var n = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: k, parameterSetPointerOut: &p,
                                                                   parameterSetSizeOut: &n, parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: nil)
                if let p { params.append(Data(bytes: p, count: n)) }
            }
        }
        return (AnnexB.fromAVCC(Data(bytes: ptr, count: len), lengthSize: Int(nalLen), prepend: params), key)
    }

    // MARK: - the picture

    /// Colour bars (for a colour check), a moving bar (motion), a red frame at the very edge
    /// (nothing cropped), a crosshair where the host believes the pointer is, and the last input.
    private func draw(_ scene: Scene, into pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        let W = CGFloat(width), H = CGFloat(height)
        if let stillImage {
            ctx.draw(stillImage, in: CGRect(x: 0, y: 0, width: W, height: H))
            return
        }
        ctx.translateBy(x: 0, y: H)                      // top-left origin, like the remote screen
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setFillColor(rgb(0x202428))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let bars: [UInt32] = [0xff0000, 0x00ff00, 0x0000ff, 0xffffff, 0x808080, 0x300a24, 0xffff00, 0x00ffff]
        let bw = (W / 2 / CGFloat(bars.count)).rounded(.down)
        for (i, c) in bars.enumerated() {
            ctx.setFillColor(rgb(c))
            ctx.fill(CGRect(x: CGFloat(i) * bw, y: 0, width: bw, height: H * 0.4))
        }
        let x = CGFloat((frame * 6) % max(1, width - 16))
        ctx.setFillColor(rgb(0xe0e0e0))
        ctx.fill(CGRect(x: x, y: H * 0.42, width: 16, height: H * 0.08))
        // 1-pixel checkerboard: sharp only when one remote pixel is one Mac pixel
        ctx.interpolationQuality = .none
        ctx.draw(Self.checker, in: CGRect(x: W - 132, y: H * 0.42, width: 120, height: 120))
        ctx.setStrokeColor(rgb(0xff3030))
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: 1, y: 1, width: W - 2, height: H - 2))

        let size = max(14, (H / 40).rounded())
        var y = H * 0.56
        func line(_ s: String, _ color: UInt32 = 0xe9eaee) {
            text(ctx, s, x: 24, y: y, size: size, color: rgb(color))
            y += size * 1.5
        }
        line("Darpan FakeHost  \(width)×\(height)  \(fps) fps  frame \(frame)", 0xffffff)
        line("pointer \(scene.pointer.map { "\($0.x), \($0.y)" } ?? "–")  buttons \(scene.buttons.sorted())  wheel \(scene.wheel.dx), \(scene.wheel.dy)")
        line("key \(scene.lastKey)")
        line("typed \(scene.typed.suffix(60))")
        line("clip \(scene.clip.prefix(60).replacingOccurrences(of: "\n", with: "⏎"))")
        line("right half: I-beam cursor · bottom strip: hidden cursor", 0x9a9ca5)

        if let p = scene.pointer {
            let px = CGFloat(p.x) + 0.5, py = CGFloat(p.y) + 0.5
            ctx.setStrokeColor(rgb(scene.buttons.isEmpty ? 0x3ccf7a : 0xff5f57))
            ctx.setLineWidth(1)
            ctx.strokeLineSegments(between: [CGPoint(x: px - 30, y: py), CGPoint(x: px + 30, y: py),
                                             CGPoint(x: px, y: py - 30), CGPoint(x: px, y: py + 30)])
        }
    }

    private static let checker: CGImage = {
        let n = 120
        var px = [UInt8](repeating: 255, count: n * n * 4)
        for y in 0..<n { for x in 0..<n where (x + y) % 2 == 1 { let i = (y * n + x) * 4; px[i] = 0; px[i + 1] = 0; px[i + 2] = 0 } }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }()

    private func text(_ ctx: CGContext, _ s: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor) {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let attrs = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                     NSAttributedString.Key(kCTForegroundColorAttributeName as String): color] as [NSAttributedString.Key: Any]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.textPosition = CGPoint(x: x, y: y + size)
        CTLineDraw(line, ctx)
    }
}

func rgb(_ v: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

/// Cursor images: 1 arrow, 2 I-beam (id 0 = hidden). `cur` messages carry them as PNG.
enum Cursors {
    static func message(_ id: Int, full: Bool) -> [String: Any] {
        guard id != 0, full, let (png, w, h, hx, hy) = image(id) else { return ["t": "cur", "id": id] }
        return ["t": "cur", "id": id, "w": w, "h": h, "hx": hx, "hy": hy, "png": png.base64EncodedString()]
    }

    private static func image(_ id: Int) -> (Data, Int, Int, Int, Int)? {
        let (w, h) = (24, 24)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let hot: (Int, Int)
        if id == 1 {
            let p = CGMutablePath()
            p.addLines(between: [CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 18), CGPoint(x: 5.5, y: 14), CGPoint(x: 9, y: 21),
                                 CGPoint(x: 12, y: 20), CGPoint(x: 8.5, y: 13), CGPoint(x: 14, y: 13)])
            p.closeSubpath()
            ctx.addPath(p); ctx.setFillColor(rgb(0xffffff)); ctx.fillPath()
            ctx.addPath(p); ctx.setStrokeColor(rgb(0x000000)); ctx.setLineWidth(1.2); ctx.strokePath()
            hot = (1, 1)
        } else {
            ctx.setStrokeColor(rgb(0xff00ff)); ctx.setLineWidth(2)
            ctx.strokeLineSegments(between: [CGPoint(x: 12, y: 3), CGPoint(x: 12, y: 21), CGPoint(x: 8, y: 3), CGPoint(x: 16, y: 3),
                                             CGPoint(x: 8, y: 21), CGPoint(x: 16, y: 21)])
            hot = (12, 12)
        }
        guard let img = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data, w, h, hot.0, hot.1)
    }
}
