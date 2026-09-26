import CoreGraphics
import CoreMedia
import ImageIO
import CoreVideo
import Foundation
import DarpanCore
import VideoToolbox

/// Splits an Annex-B elementary stream into access units at AUD boundaries.
func accessUnits(_ d: Data) -> [Data] {
    let nals = AnnexB.split(d)
    var out: [Data] = []
    var cur = Data()
    for r in nals {
        if d[r.lowerBound] & 0x1F == NALType.aud, !cur.isEmpty { out.append(cur); cur = Data() }
        cur.append(contentsOf: [0, 0, 0, 1])
        cur.append(d[r])
    }
    if !cur.isEmpty { out.append(cur) }
    return out
}

final class Collector {
    private let lock = NSLock()
    private(set) var frames: [(H264Decoder.Frame, CVImageBuffer?, OSStatus, Double)] = []
    func add(_ f: H264Decoder.Frame, _ i: CVImageBuffer?, _ s: OSStatus) {
        let t = Clock.nowMs()
        lock.lock(); frames.append((f, i, s, t)); lock.unlock()
    }
}

func videoMessage(_ au: Data, key: Bool, stream: UInt16, seq: UInt32, refresh: Bool = false) -> Data {
    var m = VideoHeader(flags: (key ? VideoHeader.flagKey : 0) | (refresh ? VideoHeader.flagRefresh : 0),
                        stream: stream, seq: seq, captureUs: 1_000_000 + UInt64(seq) * 16_667).bytes
    m.append(au)
    return m
}

func decode(_ messages: [Data], into dec: H264Decoder) -> [H264Decoder.Result] {
    messages.map { m in
        m.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> H264Decoder.Result in
            let h = VideoHeader(b)!
            return dec.decode(h, payload: UnsafeRawBufferPointer(rebasing: b[VideoHeader.size...]))
        }
    }
}

/// Encodes a moving test pattern with VideoToolbox and returns Annex-B access units the way
/// the host sends them (SPS+PPS in-band on key frames).
func encodeTestStream(width: Int, height: Int, frames: Int) throws -> [(Data, Bool)] {
    struct Err: Error { let what: String; let st: OSStatus }
    var session: VTCompressionSession?
    var st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                        codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                        imageBufferAttributes: nil, compressedDataAllocator: nil,
                                        outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard st == noErr, let session else { throw Err(what: "create", st: st) }
    defer { VTCompressionSessionInvalidate(session) }
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
    let lock = NSLock()
    var out: [(Data, Bool)] = []
    for i in 0..<frames {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let pb else { throw Err(what: "pixel buffer", st: -1) }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * stride + x * 4
                p[0] = UInt8((x + i * 8) & 0xFF); p[1] = UInt8((y * 2) & 0xFF); p[2] = UInt8((x ^ y) & 0xFF); p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        let props: [CFString: Any]? = i == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] : nil
        st = VTCompressionSessionEncodeFrame(session, imageBuffer: pb,
                                             presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 60),
                                             duration: .invalid, frameProperties: props as CFDictionary?,
                                             infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample, let fd = CMSampleBufferGetFormatDescription(sample),
                  let bb = CMSampleBufferGetDataBuffer(sample) else { return }
            let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let key = !(atts?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
            var len = 0
            var ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len,
                                              dataPointerOut: &ptr) == kCMBlockBufferNoErr, let ptr else { return }
            let avcc = Data(bytes: ptr, count: len)
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
            let annexB = AnnexB.fromAVCC(avcc, lengthSize: Int(nalLen), prepend: params)
            lock.lock(); out.append((annexB, key)); lock.unlock()
        }
        guard st == noErr else { throw Err(what: "encode", st: st) }
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    return out
}

func videoTests() {
    section("Annex-B splitting: 3- and 4-byte start codes") {
        let s: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 3,          // 4-byte start code, SPS
                          0, 0, 1, 0x68, 4, 5,                 // 3-byte, PPS
                          0, 0, 0, 1, 0x65, 0, 0, 3, 0, 9,     // 4-byte, IDR containing an emulation-prevention sequence
                          0, 0, 1, 0x06, 7, 0, 0]              // 3-byte, SEI with trailing zero bytes
        let d = Data(s)
        let r = AnnexB.split(d)
        eq(r.count, 4, "NAL count")
        let nals = r.map { Data(d[$0]) }
        eq(nals[0], Data([0x67, 1, 2, 3]), "SPS (4-byte start code)")
        eq(nals[1], Data([0x68, 4, 5]), "PPS (3-byte start code; next start code's zero not included)")
        eq(nals[2], Data([0x65, 0, 0, 3, 0, 9]), "IDR keeps 00 00 03")
        eq(nals[3], Data([0x06, 7, 0, 0]), "last NAL runs to the end")

        let au = AnnexB.accessUnit(d)
        eq(au.sps, Data([0x67, 1, 2, 3]), "access unit SPS")
        eq(au.pps, Data([0x68, 4, 5]), "access unit PPS")
        eq(au.nalTypes, [7, 8, 5, 6], "NAL types")
        eq(hex(au.avcc), "00000006" + "650000030009" + "00000004" + "06070000", "AVCC payload (SPS/PPS removed)")

        // AUD dropped, and a leading 3-byte start code at offset 0.
        let withAud = Data([0, 0, 1, 0x09, 0xF0, 0, 0, 1, 0x41, 0xAA, 0xBB])
        let au2 = AnnexB.accessUnit(withAud)
        eq(au2.nalTypes, [9, 1], "AUD + slice")
        eq(hex(au2.avcc), "0000000341aabb", "AUD removed")
        eq(AnnexB.split(Data([1, 2, 3])).count, 0, "no start code → nothing")
        eq(AnnexB.split(Data()).count, 0, "empty")

        // AVCC → Annex-B → AVCC round trip.
        let back = AnnexB.accessUnit(AnnexB.fromAVCC(au.avcc, prepend: [au.sps!, au.pps!]))
        eq(back.avcc, au.avcc, "fromAVCC round trip payload")
        eq(back.sps, au.sps, "fromAVCC round trip SPS")
    }

    section("avcC and format description from a real SPS/PPS (1920×1080, High)") {
        let rec = AVCC.decoderConfigurationRecord(sps: TestData.hdSPS, pps: TestData.hdPPS)
        guard let fd = VideoFormat.make(sps: TestData.hdSPS, pps: TestData.hdPPS) else {
            check(false, "format description"); return
        }
        let dim = CMVideoFormatDescriptionGetDimensions(fd)
        eq(dim.width, 1920, "width")
        eq(dim.height, 1080, "height")
        eq(CMFormatDescriptionGetMediaSubType(fd), kCMVideoCodecType_H264, "codec")
        let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
        let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any]
        eq(atoms?["avcC"] as? Data, rec, "our avcC == CoreMedia's (same bytes as app.js)")
        eq(ext[kCVImageBufferColorPrimariesKey as String] as? String, kCVImageBufferColorPrimaries_ITU_R_709_2 as String, "primaries from VUI")
        eq(ext[kCVImageBufferTransferFunctionKey as String] as? String, kCVImageBufferTransferFunction_sRGB as String, "transfer from VUI (sRGB)")
        eq(ext[kCVImageBufferYCbCrMatrixKey as String] as? String, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String, "matrix from VUI")
        check(VideoFormat.make(sps: Data([0x67]), pps: TestData.hdPPS) == nil, "truncated SPS rejected")
    }

    section("VIDEO header") {
        let h = VideoHeader(flags: 3, stream: 0xBEEF, seq: 0x0102_0304, captureUs: 0x1122_3344_5566_7788)
        let b = h.bytes
        eq(hex(b), "0103beef010203041122334455667788", "big-endian layout")
        let p = b.withUnsafeBytes { VideoHeader($0) }
        eq(p, h, "parse")
        check(p?.isKey == true && p?.isRefresh == true, "flags")
        check(Data([2] + [UInt8](repeating: 0, count: 15)).withUnsafeBytes { VideoHeader($0) } == nil, "wrong kind")
        check(Data([1, 0, 0]).withUnsafeBytes { VideoHeader($0) } == nil, "short")
    }

    section("SPS chroma format") {
        eq(SPSInfo.chromaFormat(Data([0x67, 0xf4, 0x00, 0x33, 0x91, 0x85, 0x95, 0x00, 0x50, 0x01, 0x6b, 0x4d, 0x40, 0x43, 0x40, 0x41, 0xe9, 0x54])),
           3, "High 4:4:4 Predictive (the host's Vulkan encoder)")
        let aus = accessUnits(TestData.small128x72)
        if let sps = AnnexB.split(aus[0]).map({ aus[0][$0] }).first(where: { $0.first.map { $0 & 0x1F == 7 } ?? false }) {
            eq(SPSInfo.chromaFormat(Data(sps)), 1, "a 4:2:0 High SPS")
        } else { check(false, "SPS in the test stream") }
        eq(SPSInfo.chromaFormat(Data([0x67, 0x42, 0x00, 0x1e, 0x95])), 1, "Baseline: always 4:2:0")
        eq(SPSInfo.chromaFormat(Data([0x67])), 1, "truncated: 4:2:0")
    }

    section("VideoToolbox decode of a real stream (AUD, 128×72, no VUI colour → BT.709)") {
        let aus = accessUnits(TestData.small128x72)
        eq(aus.count, 3, "access units")
        let c = Collector()
        let dec = H264Decoder { c.add($0, $1, $2) }
        // A delta frame before any key frame is skipped (ack + wait), not fed to the decoder.
        let early = decode([videoMessage(aus[1], key: false, stream: 1, seq: 0)], into: dec)
        eq(early, [.skipped], "delta before key frame")
        let msgs = aus.enumerated().map { videoMessage($0.element, key: $0.offset == 0, stream: 1, seq: UInt32($0.offset + 1)) }
        let results = decode(msgs, into: dec)
        eq(results, [.submitted, .submitted, .submitted], "submitted")
        dec.invalidate()                               // waits for the asynchronous frames
        eq(c.frames.count, 3, "one output per frame")
        for (f, img, st, _) in c.frames {
            eq(st, noErr, "decode status seq \(f.seq)")
            guard let img else { check(false, "image for seq \(f.seq)"); continue }
            eq(CVPixelBufferGetWidth(img), 128, "decoded width")
            eq(CVPixelBufferGetHeight(img), 72, "decoded height")
            eq(CVPixelBufferGetPixelFormatType(img), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "420v output")
            check(CVPixelBufferGetIOSurface(img) != nil, "IOSurface-backed")
            let m = CVBufferCopyAttachment(img, kCVImageBufferYCbCrMatrixKey, nil) as? String
            eq(m, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String, "BT.709 matrix attached")
        }
        eq(c.frames.map { $0.0.seq }, [1, 2, 3], "output order == decode order")
    }

    section("VideoToolbox encode → Annex-B → decode round trip (640×360, 30 frames)") {
        let stream = try encodeTestStream(width: 640, height: 360, frames: 30)
        eq(stream.count, 30, "encoded frames")
        check(stream.first?.1 == true, "first frame is a key frame")
        let c = Collector()
        let dec = H264Decoder { c.add($0, $1, $2) }
        let msgs = stream.enumerated().map { videoMessage($0.element.0, key: $0.element.1, stream: 7, seq: UInt32($0.offset)) }
        let results = decode(msgs, into: dec)
        check(results.allSatisfy { $0 == .submitted }, "all submitted: \(results)")
        let hw = dec.isHardwareAccelerated
        dec.invalidate()
        eq(c.frames.count, 30, "outputs")
        check(c.frames.allSatisfy { $0.2 == noErr && $0.1 != nil }, "all decoded")
        eq(c.frames.map { $0.0.seq }, Array(0..<30).map(UInt32.init), "in order")
        let ms = c.frames.map { $0.3 - $0.0.submittedMs }
        print(String(format: "  decode latency: mean %.2f ms, max %.2f ms (%@ decoder)",
                     ms.reduce(0, +) / Double(ms.count), ms.max() ?? 0, hw ? "hardware" : "software"))

        // New SPS/PPS (resolution change) recreates the session.
        let small = accessUnits(TestData.small128x72)
        let c2 = Collector()
        let dec2 = H264Decoder { c2.add($0, $1, $2) }
        _ = decode([videoMessage(stream[0].0, key: true, stream: 1, seq: 0)], into: dec2)
        eq(dec2.dimensions?.width, 640, "first stream width")
        _ = decode([videoMessage(small[0], key: true, stream: 2, seq: 0)], into: dec2)
        eq(dec2.dimensions?.width, 128, "session recreated for the new SPS")
        dec2.invalidate()
        eq(c2.frames.count, 2, "both key frames decoded")
        check(c2.frames.allSatisfy { $0.2 == noErr }, "no errors across the switch")
    }

    section("decoder: corrupt data never stalls acks") {
        let aus = accessUnits(TestData.small128x72)
        let c = Collector()
        let dec = H264Decoder { c.add($0, $1, $2) }
        var garbage = aus[1]
        for i in stride(from: 12, to: garbage.count, by: 3) { garbage[i] ^= 0x5A }
        let r = decode([videoMessage(aus[0], key: true, stream: 1, seq: 0),
                        videoMessage(garbage, key: false, stream: 1, seq: 1),
                        videoMessage(aus[2], key: false, stream: 1, seq: 2)], into: dec)
        dec.invalidate()
        let submitted = r.filter { $0 == .submitted }.count
        // Every submitted frame produces exactly one output (decoded or error), so it gets acked.
        eq(c.frames.count, submitted, "one output per submitted frame")
        let bad = decode([videoMessage(Data([0, 0, 1, 0x65, 0xFF]), key: true, stream: 1, seq: 3)], into: dec)
        eq(bad, [.skipped], "key frame without SPS/PPS is skipped")
    }
    // Streams recorded from the host's encoders (linux/tools/fixtures): every picture must decode,
    // and the last one must match FFmpeg's decode of the same bytes (`<name>-last.png`). The
    // `.json` next to each gives the picture and non-reference counts.
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../linux/tools/fixtures").standardized
    for name in ["nonref-thin-line-640x360", "vulkan-640x360", "vulkan-444-2560x1440"] {
        section("VideoToolbox decode of the host fixture \(name)") {
            let stream = try Data(contentsOf: fixtures.appendingPathComponent("\(name).h264"))
            let info = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("\(name).json"))) as? [String: Any]
            let aus = pictures(stream)
            eq(aus.count, info?["frames"] as? Int ?? -1, "pictures in the fixture")
            let nonRef = aus.filter { au in AnnexB.split(au).contains { au[$0.lowerBound] & 0x1F == 1 && au[$0.lowerBound] & 0x60 == 0 } }.count
            eq(nonRef, (info?["nonref"] as? [Any])?.count ?? -1, "non-reference pictures")
            let c = Collector()
            let dec = H264Decoder { c.add($0, $1, $2) }
            let msgs = aus.enumerated().map { videoMessage($0.element, key: $0.offset == 0, stream: 2, seq: UInt32($0.offset)) }
            let results = decode(msgs, into: dec)
            check(results.allSatisfy { $0 == .submitted }, "all submitted")
            dec.invalidate()
            eq(c.frames.count, aus.count, "one output per picture")
            eq(c.frames.filter { $0.2 != noErr || $0.1 == nil }.count, 0, "no decode errors")
            // Full colour comes out as full colour (444v), everything else as 420v.
            let want = (info?["chroma"] as? Int) == 444 ? kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
                                                         : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            check(c.frames.allSatisfy { $0.1.map(CVPixelBufferGetPixelFormatType) == want }, "decoded pixel format")
            guard let last = c.frames.last?.1 else { return }
            let psnr = lumaPSNR(last, png: fixtures.appendingPathComponent("\(name)-last.png"))
            check(psnr > 30, "last picture matches FFmpeg's decode (luma PSNR \(String(format: "%.1f", psnr)) dB)")
        }
    }
}

/// Annex-B stream without AUDs → one access unit per slice, parameter sets kept with the next slice.
private func pictures(_ d: Data) -> [Data] {
    var out: [Data] = []
    var cur = Data()
    for r in AnnexB.split(d) {
        cur.append(contentsOf: [0, 0, 0, 1])
        cur.append(d[r])
        let t = d[r.lowerBound] & 0x1F
        if t == 1 || t == 5 { out.append(cur); cur = Data() }
    }
    return out
}

/// Luma PSNR of a decoded picture (420v or 444v) against an RGB PNG (converted with BT.709, video
/// range). A PNG smaller than the picture is its top-left corner.
private func lumaPSNR(_ img: CVImageBuffer, png: URL) -> Double {
    guard let src = CGImageSourceCreateWithURL(png as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return 0 }
    let w = cg.width, h = cg.height
    guard w <= CVPixelBufferGetWidth(img), h <= CVPixelBufferGetHeight(img) else { return 0 }
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    CVPixelBufferLockBaseAddress(img, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(img, .readOnly) }
    let y = CVPixelBufferGetBaseAddressOfPlane(img, 0)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(img, 0)
    var se = 0.0
    for row in 0..<h {
        for col in 0..<w {
            let p = (row * w + col) * 4
            let ref = 16 + 219 * (0.2126 * Double(rgba[p]) + 0.7152 * Double(rgba[p + 1]) + 0.0722 * Double(rgba[p + 2])) / 255
            let d = Double(y[row * stride + col]) - ref
            se += d * d
        }
    }
    let mse = se / Double(w * h)
    return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
}

