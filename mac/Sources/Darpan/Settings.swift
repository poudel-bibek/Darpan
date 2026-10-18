import Combine
import DarpanCore
import Foundation
import Security

enum AppInfo {
    static let name = "Darpan"
    static let bundleID = Bundle.main.bundleIdentifier ?? "dev.darpan.Darpan"
}

enum NetworkMode: String, CaseIterable {
    case builtIn
    case system
}

/// One computer's viewer settings (Quality, Scaling, Sound, the keys…), shared by its windows and panels.
/// A change is kept for that computer only: with several open, each window's choices stay its own.
final class ComputerSettings: ObservableObject {
    @Published var prefs: ViewerPrefs { didSet { if prefs != oldValue { store(prefs.plist) } } }
    private let store: ([String: Any]) -> Void

    fileprivate init(_ prefs: ViewerPrefs, store: @escaping ([String: Any]) -> Void) {
        self.prefs = prefs
        self.store = store
    }
}

/// Viewer preferences (UserDefaults) and the list of computers connected to before.
final class Settings: ObservableObject {
    static let shared = Settings()

    /// The four quality choices, by name (`ViewerPrefs.qualities`).
    static let qualities: [(name: String, kbps: Int)] =
        Array(zip(["Faster Speed", "Balanced", "Higher Quality", "Max"], ViewerPrefs.qualities))
    static let frameRates = ViewerPrefs.frameRates

    private let d = UserDefaults.standard
    /// Each computer's settings, made on first use (one object per computer, whatever opens it).
    private var computers: [String: ComputerSettings] = [:]

    /// Computers (origins) whose desktop doesn't fit the window: a resolution was picked for them. Every
    /// other one that can make its desktop any size makes it exactly its window's size (the sharpest).
    @Published private(set) var fitOff: Set<String> { didSet { d.set(Array(fitOff).sorted(), forKey: "fitOff") } }
    /// The scale (%) chosen for each computer's fitted desktop; none: by this Mac's screen (200 % on Retina).
    @Published private(set) var fitScales: [String: Int] { didSet { d.set(fitScales, forKey: "fitScales") } }
    /// Where the toolbar sits: its centre as a fraction of the window width, its top as a fraction
    /// of the height. Top right by default, clear of the notch and of the remote's window buttons.
    @Published var toolbarX: Double { didSet { d.set(toolbarX, forKey: "toolbarX") } }
    @Published var toolbarY: Double { didSet { d.set(toolbarY, forKey: "toolbarY") } }
    @Published var remember: Bool { didSet { d.set(remember, forKey: "remember") } }
    /// The welcome screen has been through its "Get started".
    @Published var welcomed: Bool { didSet { d.set(welcomed, forKey: "welcomed") } }
    /// The first-connection tip about the toolbar has been closed.
    @Published var toolbarTipSeen: Bool { didSet { d.set(toolbarTipSeen, forKey: "toolbarTipSeen") } }
    /// How to reach the tailnet: the node built into the app, or whatever this Mac provides
    /// (the Tailscale app, another VPN, a LAN).
    @Published var network: NetworkMode { didSet { d.set(network.rawValue, forKey: "network") } }
    /// Look for a new version once a day (GitHub releases), while the app runs.
    @Published var checkUpdates: Bool { didSet { d.set(checkUpdates, forKey: "checkUpdates"); Updater.shared.start() } }
    /// Origins, most recent first.
    @Published private(set) var hosts: [String] { didSet { d.set(hosts, forKey: "hosts") } }
    /// Names and emoji given to computers here (origin → value). Only this Mac shows them.
    @Published private(set) var names: [String: String] { didSet { d.set(names, forKey: "names") } }
    @Published private(set) var emoji: [String: String] { didSet { d.set(emoji, forKey: "emoji") } }

    private init() {
        d.register(defaults: ["toolbarX": 0.84, "toolbarY": 0.05, "remember": true, "checkUpdates": true])
        fitOff = Set(d.stringArray(forKey: "fitOff") ?? [])
        fitScales = d.dictionary(forKey: "fitScales") as? [String: Int] ?? [:]
        toolbarX = min(1, max(0, d.double(forKey: "toolbarX")))
        toolbarY = min(1, max(0, d.double(forKey: "toolbarY")))
        remember = d.bool(forKey: "remember")
        welcomed = d.bool(forKey: "welcomed")
        toolbarTipSeen = d.bool(forKey: "toolbarTipSeen")
        network = NetworkMode(rawValue: d.string(forKey: "network") ?? "") ?? .builtIn
        checkUpdates = d.bool(forKey: "checkUpdates")
        hosts = (d.stringArray(forKey: "hosts") ?? []).filter { (try? HostAddress(parsing: $0)) != nil }
        names = d.dictionary(forKey: "names") as? [String: String] ?? [:]
        emoji = d.dictionary(forKey: "emoji") as? [String: String] ?? [:]
        if d.object(forKey: "computers") == nil {   // up to 1.4.3 one set for all: it goes to every computer known
            var global: [String: Any] = [:]
            for k in ViewerPrefs.keys { global[k] = d.object(forKey: k) }
            let known = Set(hosts).union(names.keys).union(emoji.keys).union(fitOff).union(fitScales.keys)
            d.set(ViewerPrefs.migrate(global: global, to: known), forKey: "computers")
        }
    }

    /// A computer's own settings; one it has none for starts from the defaults.
    func computer(_ origin: String) -> ComputerSettings {
        if let c = computers[origin] { return c }
        let stored = (d.dictionary(forKey: "computers")?[origin] as? [String: Any]) ?? [:]
        let c = ComputerSettings(ViewerPrefs(plist: stored)) { [weak self] values in self?.store(origin, values) }
        computers[origin] = c
        return c
    }

    private func store(_ origin: String, _ values: [String: Any]?) {
        var all = d.dictionary(forKey: "computers") ?? [:]
        all[origin] = values
        d.set(all, forKey: "computers")
    }

    func noteHost(_ origin: String) {
        hosts = [origin] + hosts.filter { $0 != origin }.prefix(9)
    }

    func forgetHost(_ origin: String) {
        hosts.removeAll { $0 == origin }
        label(origin, name: nil, emoji: nil)
        fitOff.remove(origin)
        fitScales[origin] = nil
        computers[origin] = nil
        store(origin, nil)
    }

    /// Whether a computer's desktop fits its window, when the computer can do that.
    func fits(_ origin: String) -> Bool { !fitOff.contains(origin) }

    func setFits(_ origin: String, _ on: Bool) {
        if on { fitOff.remove(origin) } else { fitOff.insert(origin) }
    }

    /// The scale chosen for a computer's fitted desktop, in %; 0: by this Mac's screen.
    func fitScale(_ origin: String) -> Int { fitScales[origin] ?? 0 }

    func setFitScale(_ origin: String, _ scale: Int) {
        if fitScales[origin] != scale { fitScales[origin] = scale }
    }

    /// Gives a computer a name and an emoji on this Mac; nil for either brings back none.
    func label(_ origin: String, name: String?, emoji e: String?) {
        if names[origin] != name { names[origin] = name }
        if emoji[origin] != e { emoji[origin] = e }
    }

    /// The emoji and the name to show for a computer: the ones given here, else its own name.
    func title(_ origin: String, original: String) -> String {
        ComputerLabel.title(name: names[origin], emoji: emoji[origin], original: original)
    }
}

/// Saved sign-ins: the PBKDF2 key (never the password) with its salt and iteration count, one
/// generic-password item per host origin, readable only while this Mac is unlocked and never
/// synced or migrated to another device.
enum Keychain {
    private static var service: String { AppInfo.bundleID }

    static func load(_ origin: String) -> SavedKey? {
        var q = query(origin)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let key = try? JSONDecoder().decode(SavedKey.self, from: data) else { return nil }
        return key
    }

    /// Whether a sign-in is saved, without reading it (no Keychain access prompt).
    static func contains(_ origin: String) -> Bool {
        SecItemCopyMatching(query(origin) as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func save(_ key: SavedKey, for origin: String) -> Bool {
        guard let data = try? JSONEncoder().encode(key) else { return false }
        let attrs: [CFString: Any] = [kSecValueData: data,
                                      kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var st = SecItemUpdate(query(origin) as CFDictionary, attrs as CFDictionary)
        if st == errSecItemNotFound {
            var add = query(origin).merging(attrs) { $1 }
            add[kSecAttrLabel] = "\(AppInfo.name) sign-in (\(origin))"
            st = SecItemAdd(add as CFDictionary, nil)
        }
        return st == errSecSuccess
    }

    static func delete(_ origin: String) {
        SecItemDelete(query(origin) as CFDictionary)
    }

    private static func query(_ origin: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: origin]
    }
}
