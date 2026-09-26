import Foundation

/// The address the user types (`https://<machine>.<tailnet>.ts.net`, with or without scheme)
/// normalised to an origin and the `/ws` WebSocket URL. Plain `ws://`/`http://` is only
/// accepted to this Mac itself — everything else must be TLS.
public struct HostAddress: Hashable, CustomStringConvertible {
    /// `https://host[:port]` (or `http://localhost…`) — also the Keychain account.
    public let origin: String
    public let webSocketURL: URL
    public let host: String
    public let port: Int?
    public let secure: Bool

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case empty
        case invalid
        case insecure
        case credentials

        public var description: String {
            switch self {
            case .empty: return "Enter the address of the remote computer."
            case .invalid: return "That doesn’t look like an address. Use https://<machine>.<tailnet>.ts.net"
            case .insecure: return "Use the https:// address. Unencrypted connections are only allowed to this Mac (localhost)."
            case .credentials: return "Remove the user name or password from the address."
            }
        }
    }

    public init(parsing input: String) throws {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw Problem.empty }
        if !s.contains("://") { s = "https://" + s }
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased() else { throw Problem.invalid }
        guard c.user == nil, c.password == nil else { throw Problem.credentials }
        guard var host = c.host?.lowercased(), !host.isEmpty else { throw Problem.invalid }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard host.range(of: #"^[a-z0-9.\-:%_]+$"#, options: .regularExpression) != nil else { throw Problem.invalid }
        let secure: Bool
        switch scheme {
        case "https", "wss": secure = true
        case "http", "ws": secure = false
        default: throw Problem.invalid
        }
        if !secure && !Self.isLoopback(host) { throw Problem.insecure }
        if let p = c.port, !(1...65535).contains(p) { throw Problem.invalid }
        let port = c.port == (secure ? 443 : 80) ? nil : c.port
        let hostPart = host.contains(":") ? "[\(host)]" : host
        let authority = hostPart + (port.map { ":\($0)" } ?? "")
        guard let url = URL(string: (secure ? "wss://" : "ws://") + authority + "/ws") else { throw Problem.invalid }
        self.host = host
        self.port = port
        self.secure = secure
        self.origin = (secure ? "https://" : "http://") + authority
        self.webSocketURL = url
    }

    public var description: String { origin }

    /// `workstation` for `workstation.example.ts.net`.
    public var shortName: String {
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        return String(host.split(separator: ".").first ?? Substring(host))
    }

    public static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") || h == "::1" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }
}

/// Monotonic clock in milliseconds (mach absolute time, the same base as CoreAnimation and
/// CoreVideo host time).
public enum Clock {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(tb.denom))
    }()

    public static func nowMs() -> Double {
        Double(mach_absolute_time()) * Double(timebase.numer) / Double(timebase.denom) / 1e6
    }
}

/// Round-trip time and host clock offset from ping/pong (PROTOCOL.md §3.4), smoothed like the
/// web client: RTT is an EWMA; the offset comes from the tightest sample and is refreshed after 30 s.
public struct ClockSync {
    public private(set) var rtt: Double?
    /// Host monotonic µs − local ms × 1000.
    public private(set) var offsetUs: Double?
    private var rttMin = Double.infinity
    private var rttMinAt = 0.0

    public init() {}

    public mutating func pong(c: Double, s: Double, now: Double) {
        let r = now - c
        guard r >= 0, r < 60_000, s.isFinite else { return }
        rtt = rtt.map { $0 * 0.7 + r * 0.3 } ?? r
        if r <= rttMin || now - rttMinAt > 30_000 {
            rttMin = r
            rttMinAt = now
            offsetUs = s - (c + r / 2) * 1000
        }
    }

    /// Capture (host µs) → `now` (local ms), in ms.
    public func latency(captureUs: UInt64, now: Double) -> Double? {
        guard let o = offsetUs else { return nil }
        return (now * 1000 + o - Double(captureUs)) / 1000
    }
}
