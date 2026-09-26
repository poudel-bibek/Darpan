import Combine
import DarpanCore
import Foundation
import Network

/// The computers the connect window offers: Darpan hosts found on the tailnet (each online peer
/// is asked for `/api/info` through the built-in node), plus the ones connected to before.
/// Works only while the connect window is visible; nothing runs otherwise.
final class Discovery: ObservableObject {
    struct Computer: Identifiable, Equatable {
        let origin: String                  // https://name.tailnet.ts.net
        let name: String
        let online: Bool
        var id: String { origin }
    }

    @Published private(set) var computers: [Computer] = []
    /// A scan has finished at least once since the window opened.
    @Published private(set) var scanned = false

    private let net = Tailnet.shared
    private let settings = Settings.shared
    private var found: [String: String] = [:]       // origin → name, Darpan answered
    private var timer: Timer?
    private var session: URLSession?
    private var phaseWatch: AnyCancellable?

    func start() {
        guard timer == nil else { return }
        // Scan as soon as the node is up (it's usually still starting when the window appears).
        phaseWatch = net.$phase.removeDuplicates().sink { [weak self] p in
            if p == .running { DispatchQueue.main.async { self?.scan() } }
        }
        scan()
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.scan() }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        phaseWatch = nil
    }

    private func scan() {
        guard settings.network == .builtIn, net.phase == .running, let proxy = net.proxy else {
            publish(peers: [])
            return
        }
        if session == nil {
            let cfg = URLSessionConfiguration.ephemeral
            if let port = NWEndpoint.Port(rawValue: proxy.port) {
                var p = ProxyConfiguration(socksv5Proxy: .hostPort(host: .init(proxy.host), port: port))
                p.applyCredential(username: proxy.username, password: proxy.password)
                p.allowFailover = false
                cfg.proxyConfigurations = [p]
            }
            cfg.timeoutIntervalForRequest = 3
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            session = URLSession(configuration: cfg)
        }
        net.refresh { [weak self] status in
            guard let self, let status else { return }
            let peers = status.peers.filter { !$0.dnsName.isEmpty }
            self.publish(peers: peers)
            let group = DispatchGroup()
            for p in peers where p.online {
                let host = p.dnsName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard let url = URL(string: "https://\(host)/api/info") else { continue }
                group.enter()
                self.session?.dataTask(with: url) { data, _, _ in
                    defer { group.leave() }
                    guard let data, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          o["app"] as? String == "darpan" else { return }
                    DispatchQueue.main.async { self.found["https://\(host)"] = (o["host"] as? String) ?? p.hostName }
                }.resume()
            }
            group.notify(queue: .main) {
                self.scanned = true
                self.publish(peers: peers)
            }
        }
    }

    /// Found hosts first (online), then remembered ones; each origin once.
    private func publish(peers: [Tailnet.Status.Peer]) {
        let online = Set(peers.filter(\.online).map { "https://" + $0.dnsName.trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        var list: [Computer] = []
        for (origin, name) in found.sorted(by: { $0.value < $1.value }) {
            list.append(Computer(origin: origin, name: name, online: online.contains(origin)))
        }
        for origin in settings.hosts where !list.contains(where: { $0.origin == origin }) {
            guard let a = try? HostAddress(parsing: origin), !HostAddress.isLoopback(a.host) else { continue }
            let name = a.shortName
            list.append(Computer(origin: origin, name: name, online: online.contains(origin)))
        }
        if list != computers { computers = list }
    }
}
