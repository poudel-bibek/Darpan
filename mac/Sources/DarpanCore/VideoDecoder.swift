import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 decoding of the host's access units with VideoToolbox.
///
/// `decode` is called on one serial queue. Frames decode asynchronously; `output` runs on a
/// VideoToolbox thread exactly once per submitted frame (success, error or drop), which is
/// where the caller acks and displays. SPS/PPS changes (new resolution) recreate the session.
public final class H264Decoder {
    public struct Frame {
        public let stream: UInt16
        public let seq: UInt32
        public let captureUs: UInt64
        public let isKey: Bool
        public let isRefresh: Bool
        public let submittedMs: Double
    }

    public enum Result: Equatable {
        case submitted
        /// Not decodable yet (waiting for a key frame, or nothing to decode): ack it and move on.
        case skipped
        /// The decoder refused the frame; ask for a key frame.
        case failed(OSStatus)
    }

    public typealias Output = (_ frame: Frame, _ image: CVImageBuffer?, _ status: OSStatus) -> Void

    public private(set) var needKey = true
    public private(set) var dimensions: CMVideoDimensions?
    public var isHardwareAccelerated: Bool {
        guard let session else { return false }
        var v: CFBoolean?
        let st = withUnsafeMutablePointer(to: &v) {
            VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                  allocator: nil, valueOut: $0)
        }
        return st == noErr && v == kCFBooleanTrue
    }

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private let output: Output

    public init(output: @escaping Output) { self.output = output }

    deinit { invalidate() }

    /// Drop delta frames until the next key frame (new stream, or after an error).
    public func requireKeyFrame() { needKey = true }

    public func decode(_ header: VideoHeader, payload: UnsafeRawBufferPointer) -> Result {
        if needKey && !header.isKey { return .skipped }
        let au = AnnexB.accessUnit(payload)
        if header.isKey {
            guard let s = au.sps, let p = au.pps else { return .skipped }
            if session == nil || s != sps || p != pps {
                invalidate()
                let st = makeSession(sps: s, pps: p)
                if st != noErr { return .failed(st) }
            }
        }
        guard let session, let format, !au.avcc.isEmpty,
              let sample = VideoFormat.sampleBuffer(avcc: au.avcc, format: format) else { return .skipped }
        let frame = Frame(stream: header.stream, seq: header.seq, captureUs: header.captureUs,
                          isKey: header.isKey, isRefresh: header.isRefresh, submittedMs: Clock.nowMs())
        let output = self.output
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                                                   flags: [._EnableAsynchronousDecompression],
                                                   infoFlagsOut: nil) { status, _, image, _, _ in
            output(frame, image, status)
        }
        if st != noErr {
            needKey = true
            if st == kVTInvalidSessionErr { invalidate() }
            return .failed(st)
        }
        needKey = false
        return .submitted
    }

    /// Finishes frames in flight (their outputs run first), then tears the session down.
    public func invalidate() {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        format = nil
        sps = nil
        pps = nil
        dimensions = nil
        needKey = true
    }

    private func makeSession(sps s: Data, pps p: Data) -> OSStatus {
        guard let fd = VideoFormat.make(sps: s, pps: p) else { return kVTParameterErr }
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var out: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fd,
                                              decoderSpecification: spec as CFDictionary,
                                              imageBufferAttributes: attrs as CFDictionary,
                                              outputCallback: nil, decompressionSessionOut: &out)
        guard st == noErr, let out else { return st == noErr ? kVTParameterErr : st }
        VTSessionSetProperty(out, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = out
        format = fd
        sps = s
        pps = p
        dimensions = CMVideoFormatDescriptionGetDimensions(fd)
        return noErr
    }
}
