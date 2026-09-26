import Foundation

/// H.264 elementary-stream plumbing: the host sends Annex-B access units (start codes);
/// VideoToolbox wants AVCC (4-byte big-endian length before every NAL unit).
public enum NALType {
    public static let slice: UInt8 = 1
    public static let idr: UInt8 = 5
    public static let sei: UInt8 = 6
    public static let sps: UInt8 = 7
    public static let pps: UInt8 = 8
    public static let aud: UInt8 = 9
}

public enum AnnexB {
    /// NAL unit ranges in `b` (start codes excluded). Handles 3- and 4-byte start codes; the
    /// zero byte that belongs to a following 4-byte start code is not part of the NAL.
    /// Port of `splitNals` in linux/web/app.js.
    public static func split(_ b: UnsafeRawBufferPointer) -> [Range<Int>] {
        var out: [Range<Int>] = []
        out.reserveCapacity(8)
        let n = b.count
        var i = 0, start = -1
        while i + 2 < n {
            let c = b[i + 2]
            if c > 1 { i += 3; continue }          // cannot be inside a start code
            if c == 1 && b[i] == 0 && b[i + 1] == 0 {
                if start >= 0 {
                    var end = i
                    while end > start && b[end - 1] == 0 { end -= 1 }
                    if end > start { out.append(start..<end) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0 && start < n { out.append(start..<n) }
        return out
    }

    public static func split(_ d: Data) -> [Range<Int>] {
        d.withUnsafeBytes { split($0) }
    }

    /// One access unit, split and converted.
    public struct AccessUnit {
        public var sps: Data?
        public var pps: Data?
        /// Length-prefixed slice (and SEI) NAL units, SPS/PPS/AUD removed.
        public var avcc: Data
        public var nalTypes: [UInt8]
    }

    /// Splits an Annex-B access unit held in `b` into parameter sets and an AVCC payload.
    public static func accessUnit(_ b: UnsafeRawBufferPointer) -> AccessUnit {
        let nals = split(b)
        var size = 0
        var sps: Range<Int>?, pps: Range<Int>?
        var types: [UInt8] = []
        types.reserveCapacity(nals.count)
        for r in nals {
            let t = b[r.lowerBound] & 0x1F
            types.append(t)
            switch t {
            case NALType.sps: sps = r
            case NALType.pps: pps = r
            case NALType.aud: break
            default: size += 4 + r.count
            }
        }
        var avcc = Data(count: size)
        avcc.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            var o = 0
            for (k, r) in nals.enumerated() {
                let t = types[k]
                if t == NALType.sps || t == NALType.pps || t == NALType.aud { continue }
                let l = UInt32(r.count)
                dst[o] = UInt8(l >> 24); dst[o + 1] = UInt8((l >> 16) & 0xFF)
                dst[o + 2] = UInt8((l >> 8) & 0xFF); dst[o + 3] = UInt8(l & 0xFF)
                dst.baseAddress!.advanced(by: o + 4).copyMemory(from: b.baseAddress!.advanced(by: r.lowerBound),
                                                                 byteCount: r.count)
                o += 4 + r.count
            }
        }
        func copy(_ r: Range<Int>?) -> Data? {
            guard let r else { return nil }
            return Data(bytes: b.baseAddress!.advanced(by: r.lowerBound), count: r.count)
        }
        return AccessUnit(sps: copy(sps), pps: copy(pps), avcc: avcc, nalTypes: types)
    }

    public static func accessUnit(_ d: Data) -> AccessUnit {
        d.withUnsafeBytes { accessUnit($0) }
    }

    /// AVCC (length-prefixed, `lengthSize` bytes) → Annex-B with 4-byte start codes.
    /// Used by the test encoder; the app itself only goes the other way.
    public static func fromAVCC(_ d: Data, lengthSize: Int = 4, prepend: [Data] = []) -> Data {
        var out = Data()
        out.reserveCapacity(d.count + 16 * (prepend.count + 4))
        let sc: [UInt8] = [0, 0, 0, 1]
        for p in prepend { out.append(contentsOf: sc); out.append(p) }
        d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            var o = 0
            while o + lengthSize <= b.count {
                var l = 0
                for k in 0..<lengthSize { l = (l << 8) | Int(b[o + k]) }
                o += lengthSize
                guard l > 0, o + l <= b.count else { break }
                out.append(contentsOf: sc)
                out.append(UnsafeRawBufferPointer(rebasing: b[o..<(o + l)]).bindMemory(to: UInt8.self))
                o += l
            }
        }
        return out
    }
}

public enum AVCC {
    /// AVCDecoderConfigurationRecord ("avcC") for one SPS/PPS pair, 4-byte NAL lengths.
    /// Same layout as `avcC()` in linux/web/app.js (and as CoreMedia builds it).
    public static func decoderConfigurationRecord(sps: Data, pps: Data) -> Data {
        let s = [UInt8](sps), p = [UInt8](pps)
        guard s.count >= 4 else { return Data() }
        let high = [100, 110, 122, 144].contains(Int(s[1]))
        var b: [UInt8] = [1, s[1], s[2], s[3], 0xFF, 0xE1, UInt8(s.count >> 8), UInt8(s.count & 0xFF)]
        b += s
        b += [1, UInt8(p.count >> 8), UInt8(p.count & 0xFF)]
        b += p
        if high { b += [0xFD, 0xF8, 0xF8, 0] }        // 4:2:0, 8-bit, no SPS extensions
        return Data(b)
    }
}
