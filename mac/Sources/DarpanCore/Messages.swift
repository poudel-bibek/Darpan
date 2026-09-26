import Foundation

/// Client → host text messages (PROTOCOL.md). The per-event ones (mm, mb, wh, key, ack) are
/// formatted directly — they only contain numbers and key names from our own table; anything
/// carrying user text goes through JSONSerialization.
public enum Msg {
    public static func mm(_ x: Int, _ y: Int) -> String { #"{"t":"mm","x":\#(x),"y":\#(y)}"# }

    public static func mb(_ b: Int, _ down: Bool, x: Int? = nil, y: Int? = nil) -> String {
        if let x, let y { return #"{"t":"mb","b":\#(b),"d":\#(down),"x":\#(x),"y":\#(y)}"# }
        return #"{"t":"mb","b":\#(b),"d":\#(down)}"#
    }

    public static func wh(dx: Int, dy: Int) -> String { #"{"t":"wh","dx":\#(dx),"dy":\#(dy)}"# }

    /// `code` must be a W3C code from the key table (ASCII letters and digits only).
    public static func key(_ code: String, _ down: Bool, cmd: Bool = false) -> String {
        cmd ? #"{"t":"key","c":"\#(code)","d":\#(down),"cmd":true}"# : #"{"t":"key","c":"\#(code)","d":\#(down)}"#
    }

    public static func ack(stream: UInt16, seq: UInt32) -> String { #"{"t":"ack","id":\#(stream),"n":\#(seq)}"# }

    public static func ping(_ clientMs: Double) -> String { #"{"t":"ping","c":\#(String(format: "%.3f", clientMs))}"# }

    /// `fullGPU`: the host may use more of its GPU's memory for sharper, faster video
    /// (`"gpu":"full"`, NVENC through CUDA); otherwise `"lean"` (PROTOCOL.md §4).
    public static func start(fps: Int, bitrate: Int, fullGPU: Bool = false) -> String {
        #"{"t":"start","codec":"h264","fps":\#(fps),"bitrate":\#(bitrate),"gpu":"\#(fullGPU ? "full" : "lean")"}"#
    }

    public static func cfg(fps: Int? = nil, bitrate: Int? = nil, fullGPU: Bool? = nil) -> String {
        var parts = [#""t":"cfg""#]
        if let fps { parts.append(#""fps":\#(fps)"#) }
        if let bitrate { parts.append(#""bitrate":\#(bitrate)"#) }
        if let fullGPU { parts.append(#""gpu":"\#(fullGPU ? "full" : "lean")""#) }
        return "{" + parts.joined(separator: ",") + "}"
    }

    public static func res(w: Int, h: Int) -> String { #"{"t":"res","w":\#(w),"h":\#(h)}"# }
    public static let resNative = #"{"t":"res","native":true}"#
    public static let modes = #"{"t":"modes"}"#
    public static let rel = #"{"t":"rel"}"#
    public static let kf = #"{"t":"kf"}"#
    public static let stop = #"{"t":"stop"}"#
    public static let fs = #"{"t":"fs"}"#
    public static func audio(on: Bool) -> String { #"{"t":"audio","on":\#(on)}"# }

    public static func auth(proof: Data, client: String) -> String? {
        json(["t": "auth", "proof": proof.base64EncodedString(), "client": client, "ver": DarpanVersion.string])
    }

    public static func txt(_ s: String) -> String? { json(["t": "txt", "s": s]) }
    public static func clip(_ text: String) -> String? { json(["t": "clip", "text": text]) }
    public static func fput(id: UInt32, name: String, size: Int64) -> String? {
        json(["t": "fput", "id": id, "name": name, "size": size])
    }
    public static func fabort(id: UInt32) -> String { #"{"t":"fabort","id":\#(id)}"# }

    public static func json(_ obj: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Limits from PROTOCOL.md §1/§6.
    public static let maxClipboardBytes = 1 << 20
    public static let maxTextMessage = 2 << 20
    public static let maxBinaryMessage = 8 << 20
    public static let maxTypedText = 4096     // the host types at most this many characters per `txt`
}

/// FILE_CHUNK binary message: `[0x02][uint32 id BE][data]` (PROTOCOL.md §7).
public enum FileChunk {
    public static let kind: UInt8 = 0x02
    public static let headerSize = 5
    public static let maxData = 256 * 1024
    /// Bytes allowed in flight without a `fack` (the protocol allows 1 MiB; the web client uses 512 KiB).
    public static let window = 512 * 1024

    public static func message(id: UInt32, data: Data) -> Data {
        var m = Data(capacity: headerSize + data.count)
        m.append(kind)
        m.append(UInt8(id >> 24)); m.append(UInt8((id >> 16) & 0xFF))
        m.append(UInt8((id >> 8) & 0xFF)); m.append(UInt8(id & 0xFF))
        m.append(data)
        return m
    }
}

/// A decoded host → client text message. Accessors never trap on unexpected types:
/// unknown or malformed fields read as nil (PROTOCOL.md: ignore what you don't understand).
public struct Incoming {
    public let type: String
    public let fields: [String: Any]

    public init?(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any], let t = dict["t"] as? String else { return nil }
        type = t
        fields = dict
    }

    public init(type: String, fields: [String: Any]) {
        self.type = type
        self.fields = fields
    }

    public subscript(_ key: String) -> Any? { fields[key] }

    public func string(_ key: String) -> String? { fields[key] as? String }

    public func double(_ key: String) -> Double? {
        guard let n = fields[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue
        return v.isFinite ? v : nil
    }

    public func int(_ key: String) -> Int? {
        // Double(Int.max) rounds up to 2^63, which Int(_:) can't hold: compare with `<`.
        guard let v = double(key), v >= Double(Int.min), v < Double(Int.max) else { return nil }
        return Int(v)
    }

    public func bool(_ key: String) -> Bool? {
        guard let n = fields[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    public func object(_ key: String) -> Incoming? {
        guard let d = fields[key] as? [String: Any] else { return nil }
        return Incoming(type: "", fields: d)
    }

    public func data(_ key: String) -> Data? {
        guard let s = fields[key] as? String else { return nil }
        return Data(base64Encoded: s)
    }

    /// `[w, h]` pairs, e.g. `modes.current`.
    public func mode(_ key: String) -> DisplayMode? { Self.mode(fields[key]) }

    public func modes(_ key: String) -> [DisplayMode] {
        (fields[key] as? [Any])?.compactMap(Self.mode) ?? []
    }

    static func mode(_ any: Any?) -> DisplayMode? {
        guard let a = any as? [Any], a.count >= 2,
              let w = (a[0] as? NSNumber)?.intValue, let h = (a[1] as? NSNumber)?.intValue,
              w > 0, h > 0, w < 1 << 16, h < 1 << 16 else { return nil }
        return DisplayMode(w, h)
    }
}
