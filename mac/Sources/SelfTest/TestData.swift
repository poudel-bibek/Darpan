import Foundation

/// Test vectors. Generated on the Mac with ffmpeg/libx264 (not needed at build time).
enum TestData {
    /// 128×72 H.264 High profile, 3 access units (IDR + 2 P, no B-frames), each starting with an
    /// access unit delimiter; no colour description in the VUI. ffmpeg/libx264 test pattern
    /// with the SEI removed.
    static let small128x72 = Data(base64Encoded: [
    "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",
    "44KDuqHC2u1SWev1A15bork8G08=",
    ].joined())!

    /// 1920×1080 High profile SPS/PPS as the NVENC host sends them: VUI with BT.709 primaries,
    /// sRGB transfer (13), BT.709 matrix, limited range.
    static let hdSPS = hex("6764002aacb403c0113f2e02d4043405000003000100000300788f1832a0")
    static let hdPPS = hex("68ef0f2c8b")

    static func hex(_ s: String) -> Data {
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }
}
