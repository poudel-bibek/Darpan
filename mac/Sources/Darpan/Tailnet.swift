import CTailscale
import DarpanCore
import Foundation

/// The built-in tailnet connection: a Tailscale node inside the app (libtailscale / tsnet), so
/// no Tailscale app is needed on the Mac. Only Darpan's own WebSocket goes through it, via the
/// node's loopback SOCKS5 proxy: no system VPN, no DNS changes.
///
/// Keys live in ~/Library/Application Support/Darpan/tailscale (0700), so signing in happens
/// once. The node runs from the first use (or from launch once signed in) until the app quits;
/// status is only polled while something shows it.
final class Tailnet: ObservableObject {
    static let shared = Tailnet()

    enum Phase: Equatable {
        case off
        case starting
        /// Needs a browser sign-in. `url` appears a moment after starting. `again`: the device
        /// was signed in before (its key expired or was removed).
        case needsLogin(url: URL?, again: Bool)
        case running
        case failed(String)
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var account: String?
    @Published private(set) var deviceName: String?
    /// The loopback proxy, once the node is up.
    private(set) var proxy: SOCKSProxy?

    private let queue = DispatchQueue(label: "dev.darpan.Darpan.tailnet", qos: .userInitiated)
    private var handle: tailscale = -1                 // queue
    private var lockFD: Int32 = -1                     // queue
    private var pollers = 0
    private var timer: Timer?

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Darpan/tailscale", isDirectory: true)
    }

    /// Signed in on an earlier launch: start at launch so the first connect is quick.
    static var hasState: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("tailscaled.state").path)
    }

    /// `darpan-studio-mac` for "Studio Mac".
    static var hostname: String {
        let name = (Host.current().localizedName ?? "mac").lowercased()
            .replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
        let slug = name.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return "darpan-" + String((slug.isEmpty ? "mac" : slug).prefix(50))
    }

    /// Starts the node (idempotent). Completion runs on main once the proxy exists or starting failed.
    func start(_ done: ((SOCKSProxy?) -> Void)? = nil) {
        if let proxy { done?(proxy); return }
        if phase == .off { phase = .starting }
        queue.async {
            let result = self.startOnQueue()
            DispatchQueue.main.async {
                switch result {
                case .success(let p):
                    self.proxy = p
                    self.refresh()
                    done?(p)
                case .failure(let e):
                    self.phase = .failed(e.message)
                    done?(nil)
                }
            }
        }
    }

    /// Calls back once the backend has settled (NeedsLogin, Running or an error), polling every
    /// 100 ms for up to `timeout`: right after starting, a node with saved keys is still Starting.
    func settle(timeout: TimeInterval = 15, _ done: @escaping (Phase) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            refresh { [weak self] _ in
                guard let self else { return }
                switch self.phase {
                case .starting, .off:
                    if Date() < deadline {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: check)
                    } else {
                        done(self.phase)
                    }
                default:
                    done(self.phase)
                }
            }
        }
        check()
    }

    /// On quit: leaves the tailnet cleanly (the device stays signed in).
    func stop() {
        queue.sync {
            if handle >= 0 { tailscale_close(handle) }
            handle = -1
        }
    }

    /// Poll the status while a view shows it (connect window, sign-in). Balanced with `unwatch`.
    func watch() {
        pollers += 1
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func unwatch() {
        pollers = max(0, pollers - 1)
        if pollers == 0 { timer?.invalidate(); timer = nil }
    }

    /// Reads the node's status once (in memory, no network).
    func refresh(_ done: ((Status?) -> Void)? = nil) {
        queue.async {
            let s = self.statusOnQueue()
            DispatchQueue.main.async {
                if let s { self.apply(s) }
                done?(s)
            }
        }
    }

    /// How the connection to `host` travels: "direct 203.0.113.5:41641" or "relay ord". Nil if unknown.
    func path(to host: String, _ done: @escaping (String?) -> Void) {
        refresh { s in
            let h = host.lowercased()
            let peer = s?.peers.first { $0.dnsName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == h }
            if let p = peer {
                if !p.curAddr.isEmpty { done("direct \(p.curAddr)") } else if !p.relay.isEmpty { done("relay \(p.relay)") } else { done(nil) }
            } else {
                done(nil)
            }
        }
    }

    // MARK: - queue

    private struct CError: Error { let message: String }

    private func startOnQueue() -> Result<SOCKSProxy, CError> {
        if handle < 0 {
            let dir = Self.directory
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            } catch {
                return .failure(CError(message: "Can’t create \(dir.path): \(error.localizedDescription)"))
            }
            // One node per state directory: a second Darpan process running the same node key
            // would take over its WireGuard path and stall the first one's session.
            if lockFD < 0 {
                let fd = open(dir.appendingPathComponent("darpan.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
                guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                    if fd >= 0 { close(fd) }
                    return .failure(CError(message: "Another copy of Darpan is using the private network. "
                                           + "Quit it, or switch this one to “This Mac’s”."))
                }
                lockFD = fd                                  // held until the process exits
            }
            let h = tailscale_new()
            guard h >= 0 else { return .failure(CError(message: "Couldn’t create the network node.")) }
            tailscale_set_dir(h, dir.path)
            tailscale_set_hostname(h, Self.hostname)
            tailscale_set_logfd(h, -1)
            guard tailscale_start(h) == 0 else { return .failure(error(h)) }
            handle = h
        }
        var addr = [CChar](repeating: 0, count: 64)
        var proxyCred = [CChar](repeating: 0, count: 33)
        var apiCred = [CChar](repeating: 0, count: 33)
        guard tailscale_loopback(handle, &addr, addr.count, &proxyCred, &apiCred) == 0 else { return .failure(error(handle)) }
        let a = String(cString: addr)
        guard let colon = a.lastIndex(of: ":"), let port = UInt16(a[a.index(after: colon)...]) else {
            return .failure(CError(message: "Unexpected proxy address \(a)"))
        }
        let host = String(a[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return .success(SOCKSProxy(host: host, port: port, username: "tsnet", password: String(cString: proxyCred)))
    }

    private func error(_ h: tailscale) -> CError {
        var buf = [CChar](repeating: 0, count: 512)
        tailscale_errmsg(h, &buf, buf.count)
        let m = String(cString: buf)
        return CError(message: m.isEmpty ? "The network node didn’t start." : m)
    }

    struct Status {
        struct Peer { let dnsName: String; let curAddr: String; let relay: String }
        let backendState: String
        let authURL: URL?
        let account: String?
        let dnsName: String?
        let peers: [Peer]
    }

    private func statusOnQueue() -> Status? {
        guard handle >= 0 else { return nil }
        var out: UnsafeMutablePointer<CChar>?
        guard tailscale_status_json(handle, &out) == 0, let out else { return nil }
        defer { free(out) }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes: out, count: strlen(out))) as? [String: Any] else { return nil }
        let me = obj["Self"] as? [String: Any]
        var account: String?
        if let uid = me?["UserID"] as? NSNumber, let users = obj["User"] as? [String: Any],
           let u = users[uid.stringValue] as? [String: Any] {
            account = u["LoginName"] as? String
        }
        let peers = ((obj["Peer"] as? [String: Any]) ?? [:]).values.compactMap { $0 as? [String: Any] }.map {
            Status.Peer(dnsName: $0["DNSName"] as? String ?? "", curAddr: $0["CurAddr"] as? String ?? "",
                        relay: $0["Relay"] as? String ?? "")
        }
        let url = (obj["AuthURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        return Status(backendState: obj["BackendState"] as? String ?? "", authURL: url, account: account,
                      dnsName: (me?["DNSName"] as? String).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) },
                      peers: peers)
    }

    private func apply(_ s: Status) {
        switch s.backendState {
        case "Running":
            phase = .running
            UserDefaults.standard.set(true, forKey: "tailnetSignedIn")
        case "NeedsLogin", "NeedsMachineAuth":
            phase = .needsLogin(url: s.authURL, again: UserDefaults.standard.bool(forKey: "tailnetSignedIn"))
        case "Starting", "NoState", "":
            if phase != .running { phase = .starting }
        default:
            break
        }
        account = s.account
        deviceName = s.dnsName
    }
}
