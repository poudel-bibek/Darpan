import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// 16-byte big-endian header of a binary VIDEO message (PROTOCOL.md §3.2).
public struct VideoHeader: Equatable {
    public static let size = 16
    public static let kind: UInt8 = 0x01
    public static let flagKey: UInt8 = 0x01
    public static let flagRefresh: UInt8 = 0x02

    public var flags: UInt8
    public var stream: UInt16
    public var seq: UInt32
    public var captureUs: UInt64

    public var isKey: Bool { flags & Self.flagKey != 0 }
    public var isRefresh: Bool { flags & Self.flagRefresh != 0 }

    public init(flags: UInt8, stream: UInt16, seq: UInt32, captureUs: UInt64) {
        self.flags = flags; self.stream = stream; self.seq = seq; self.captureUs = captureUs
    }

    public init?(_ b: UnsafeRawBufferPointer) {
        guard b.count >= Self.size, b[0] == Self.kind else { return nil }
        func be(_ o: Int, _ n: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<n { v = (v << 8) | UInt64(b[o + k]) }
            return v
        }
        flags = b[1]
        stream = UInt16(be(2, 2))
        seq = UInt32(be(4, 4))
        captureUs = be(8, 8)
    }

    public var bytes: Data {
        var d = Data(count: Self.size)
        d[0] = Self.kind; d[1] = flags
        d[2] = UInt8(stream >> 8); d[3] = UInt8(stream & 0xFF)
        for k in 0..<4 { d[4 + k] = UInt8((seq >> (24 - 8 * UInt32(k))) & 0xFF) }
        for k in 0..<8 { d[8 + k] = UInt8((captureUs >> (56 - 8 * UInt64(k))) & 0xFF) }
        return d
    }
}

public enum VideoFormat {
    /// Format description for an SPS/PPS pair (NAL length 4). CoreMedia reads the colour
    /// description from the SPS VUI (the NVENC host sends BT.709 primaries + matrix, sRGB
    /// transfer); streams without one are tagged BT.709, as PROTOCOL.md §3.2 specifies, so
    /// the decoder's output buffers always carry colour attachments.
    public static func make(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        guard sps.count >= 4, !pps.isEmpty else { return nil }
        var fd: CMFormatDescription?
        let st: OSStatus = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let ptrs: [UnsafePointer<UInt8>] = [s.bindMemory(to: UInt8.self).baseAddress!,
                                                    p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        }
        guard st == noErr, let fd else { return nil }
        let ext = (CMFormatDescriptionGetExtensions(fd) as? [String: Any]) ?? [:]
        if ext[kCVImageBufferYCbCrMatrixKey as String] != nil { return fd }
        var merged = ext
        merged[kCVImageBufferYCbCrMatrixKey as String] = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        if merged[kCVImageBufferColorPrimariesKey as String] == nil {
            merged[kCVImageBufferColorPrimariesKey as String] = kCVImageBufferColorPrimaries_ITU_R_709_2
        }
        if merged[kCVImageBufferTransferFunctionKey as String] == nil {
            merged[kCVImageBufferTransferFunctionKey as String] = kCVImageBufferTransferFunction_ITU_R_709_2
        }
        let dim = CMVideoFormatDescriptionGetDimensions(fd)
        var tagged: CMVideoFormatDescription?
        let st2 = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                 codecType: kCMVideoCodecType_H264,
                                                 width: dim.width, height: dim.height,
                                                 extensions: merged as CFDictionary,
                                                 formatDescriptionOut: &tagged)
        return st2 == noErr ? (tagged ?? fd) : fd
    }

    /// Wraps one AVCC access unit (no copy: the block buffer retains `data`).
    public static func sampleBuffer(avcc data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        guard !data.isEmpty else { return nil }
        let ns = data as NSData                      // bridged, immutable: keeps the bytes alive
        var block: CMBlockBuffer?
        let retained = Unmanaged.passRetained(ns)
        var src = CMBlockBufferCustomBlockSource(
            version: kCMBlockBufferCustomBlockSourceVersion, AllocateBlock: nil,
            FreeBlock: { refCon, _, _ in
                if let refCon { Unmanaged<NSData>.fromOpaque(refCon).release() }
            },
            refCon: retained.toOpaque())
        var st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: UnsafeMutableRawPointer(mutating: ns.bytes),
            blockLength: ns.length, blockAllocator: kCFAllocatorNull, customBlockSource: &src,
            offsetToData: 0, dataLength: ns.length, flags: 0, blockBufferOut: &block)
        guard st == kCMBlockBufferNoErr, let block else {
            retained.release()
            return nil
        }
        var sb: CMSampleBuffer?
        var size = ns.length
        st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                       formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                       sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                       sampleSizeArray: &size, sampleBufferOut: &sb)
        return st == noErr ? sb : nil
    }
}

/// Reading an SPS: the chroma format (PROTOCOL.md §3.2 allows 4:2:0 and, with `h264-444`, 4:4:4).
public enum SPSInfo {
    /// chroma_format_idc: 1 (4:2:0) unless a High-family SPS says otherwise; 3 is 4:4:4.
    public static func chromaFormat(_ sps: Data) -> Int {
        var r = BitReader(unescaping: sps.dropFirst())            // after the NAL header byte
        guard let profile = r.bits(8) else { return 1 }
        _ = r.bits(16)                                           // constraint flags, level_idc
        _ = r.ue()                                               // seq_parameter_set_id
        let high: Set<Int> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
        guard high.contains(profile), let idc = r.ue() else { return 1 }
        return idc
    }

    /// Exp-Golomb and plain bits over an RBSP (emulation-prevention bytes removed).
    struct BitReader {
        private let bytes: [UInt8]
        private var pos = 0

        init<C: Collection>(unescaping d: C) where C.Element == UInt8 {
            var out: [UInt8] = []
            var zeros = 0
            for b in d {
                if zeros >= 2 && b == 3 { zeros = 0; continue }
                out.append(b)
                zeros = b == 0 ? zeros + 1 : 0
            }
            bytes = out
        }

        mutating func bits(_ n: Int) -> Int? {
            var v = 0
            for _ in 0..<n {
                guard pos < bytes.count * 8 else { return nil }
                v = v << 1 | Int(bytes[pos / 8] >> (7 - UInt8(pos % 8)) & 1)
                pos += 1
            }
            return v
        }

        mutating func ue() -> Int? {
            var zeros = 0
            while true {
                guard let b = bits(1) else { return nil }
                if b == 1 { break }
                zeros += 1
                if zeros > 31 { return nil }
            }
            guard let rest = bits(zeros) else { return nil }
            return (1 << zeros) - 1 + rest
        }
    }
}

/// What this Mac's decoder can take beyond the basics, for `auth.caps` (PROTOCOL.md §2).
public enum DecoderCaps {
    /// H.264 High 4:4:4 Predictive in hardware (probed once with a 2560×1440 SPS/PPS from the host's encoder).
    public static let fullColour: Bool = {
        let sps = Data([0x67, 0xf4, 0x00, 0x33, 0x91, 0x85, 0x95, 0x00, 0x50, 0x01, 0x6b, 0x4d, 0x40, 0x43, 0x40, 0x41, 0xe9, 0x54])
        let pps = Data([0x68, 0xce, 0x3c, 0xb0])
        guard let fd = VideoFormat.make(sps: sps, pps: pps) else { return false }
        let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: spec,
                                           imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &s) == noErr,
              let s else { return false }
        VTDecompressionSessionInvalidate(s)
        return true
    }()

    /// The `caps` this client sends.
    public static var list: [String] { fullColour ? ["h264-444"] : [] }
}
