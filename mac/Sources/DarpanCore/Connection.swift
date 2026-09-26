import Foundation
import Network

/// A SOCKS5 proxy with username/password authentication (the built-in tailnet node's loopback
/// server). The host name is handed to the proxy unresolved, so tailnet names resolve there.
public struct SOCKSProxy: Equatable {
    public let host: String
    public let port: UInt16
    public let username: String
    public let password: String

    public init(host: String, port: UInt16, username: String, password: String) {
        self.host = host; self.port = port; self.username = username; self.password = password
    }
}

/// One WebSocket to the host (Network.framework): TLS with the system's default certificate
/// validation, TCP_NODELAY, no Origin header, pings answered automatically.
///
/// Events are delivered on `queue`. `send` may be called from any thread (NWConnection is
/// thread-safe and keeps the order of sends). After `.closed` nothing else is delivered.
public final class WebSocket {
    public enum Event {
        case ready
        /// Not connected yet; Network.framework keeps retrying (e.g. when the path changes).
        case waiting(NWError)
        case text(Data)
        case binary(Data)
        /// `code` is the peer's close code (nil if the connection just ended or failed).
        case closed(code: UInt16?, error: NWError?)
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: (Event) -> Void
    private let textContext = NWConnection.ContentContext(
        identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
    private let binaryContext = NWConnection.ContentContext(
        identifier: "binary", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
    private let lock = NSLock()
    private var finished = false        // guarded by lock

    /// `proxy`: route this connection (and only it) through a SOCKS5 proxy. TLS still ends here,
    /// with the system's certificate validation; there's no fallback to a direct connection.
    public init(url: URL, userAgent: String, proxy: SOCKSProxy? = nil, queue: DispatchQueue,
                handler: @escaping (Event) -> Void) {
        self.queue = queue
        self.handler = handler
        let ws = NWProtocolWebSocket.Options(.version13)
        ws.autoReplyPing = true
        ws.maximumMessageSize = Msg.maxBinaryMessage
        ws.setAdditionalHeaders([("User-Agent", userAgent)])   // no Origin: we are not a browser
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let secure = url.scheme?.lowercased() == "wss"
        let params = NWParameters(tls: secure ? NWProtocolTLS.Options() : nil, tcp: tcp)
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.serviceClass = .interactiveVideo
        if let proxy, let port = NWEndpoint.Port(rawValue: proxy.port) {
            var config = ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(proxy.host), port: port))
            config.applyCredential(username: proxy.username, password: proxy.password)
            config.allowFailover = false
            let context = NWParameters.PrivacyContext(description: "Darpan tailnet")
            context.proxyConfigurations = [config]
            params.setPrivacyContext(context)
        } else {
            params.preferNoProxies = true           // tailnet addresses are only reachable directly
        }
        connection = NWConnection(to: .url(url), using: params)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.deliver(.ready)
                self.receive()
            case .waiting(let e):
                self.deliver(.waiting(e))
            case .failed(let e):
                self.finish(code: nil, error: e)
            case .cancelled:
                self.finish(code: nil, error: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(text: String) {
        guard !isFinished else { return }
        connection.send(content: Data(text.utf8), contentContext: textContext, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    public func send(binary: Data, completion: (() -> Void)? = nil) {
        guard !isFinished else { return }
        connection.send(content: binary, contentContext: binaryContext, isComplete: true,
                        completion: .contentProcessed { _ in completion?() })
    }

    /// Sends a close frame (so the host ends the session at once), then tears down.
    /// No `.closed` event follows a local close.
    public func close(code: UInt16 = 1000) {
        guard markFinished() else { return }
        connection.stateUpdateHandler = nil
        guard connection.state == .ready else {
            connection.cancel()
            return
        }
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = code >= 4000 ? .privateCode(code) : .protocolCode(.normalClosure)
        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        let c = connection
        c.send(content: nil, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
        queue.asyncAfter(deadline: .now() + 1) { c.cancel() }   // in case the send never completes
    }

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    private func markFinished() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }

    private func deliver(_ e: Event) {
        if !isFinished { handler(e) }
    }

    private func finish(code: UInt16?, error: NWError?) {
        guard markFinished() else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        handler(.closed(code: code, error: error))
    }

    private func receive() {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self, !self.isFinished else { return }
            if let error {
                self.finish(code: nil, error: error)
                return
            }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch meta?.opcode {
            case .text?:
                self.deliver(.text(content ?? Data()))
            case .binary?:
                self.deliver(.binary(content ?? Data()))
            case .close?:
                self.finish(code: Self.code(meta!.closeCode), error: nil)
                return
            default:
                if content == nil && isComplete && (context?.isFinal ?? true) {
                    self.finish(code: nil, error: nil)       // the stream ended without a close frame
                    return
                }
            }
            self.receive()
        }
    }

    private static func code(_ c: NWProtocolWebSocket.CloseCode) -> UInt16? {
        switch c {
        case .protocolCode(let d): return d.rawValue
        case .applicationCode(let v): return v
        case .privateCode(let v): return v
        @unknown default: return nil
        }
    }
}

extension NWError {
    /// The name does not resolve — with MagicDNS that almost always means Tailscale is off.
    public var isNameResolution: Bool {
        if case .dns = self { return true }
        return false
    }

    public var isTLS: Bool {
        if case .tls = self { return true }
        return false
    }

    public var isOffline: Bool {
        if case .posix(let c) = self { return c == .ENETDOWN || c == .ENETUNREACH || c == .EHOSTUNREACH }
        return false
    }

    public var isRefused: Bool {
        if case .posix(let c) = self { return c == .ECONNREFUSED }
        return false
    }
}
