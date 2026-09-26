import Combine
import DarpanCore
import Foundation
import Security

enum AppInfo {
    static let name = "Darpan"
    static let bundleID = Bundle.main.bundleIdentifier ?? "dev.darpan.Darpan"
    static let website = URL(string: "https://github.com/OWNER/darpan")!
}

/// Viewer preferences (UserDefaults) and the list of computers connected to before.
final class Settings: ObservableObject {
    static let shared = Settings()

    static let qualities: [(name: String, kbps: Int)] =
        [("Auto", 0), ("Low", 3000), ("Balanced", 10000), ("High", 20000), ("Max", 50000)]
    static let frameRates = [30, 60, 120]

    private let d = UserDefaults.standard

    @Published var scale: ScaleMode { didSet { d.set(scale.rawValue, forKey: "scale") } }
    /// Maximum bitrate in kbit/s, 0 = adaptive.
    @Published var quality: Int { didSet { d.set(quality, forKey: "quality") } }
    @Published var fps: Int { didSet { d.set(fps, forKey: "fps") } }
    @Published var command: CommandKey { didSet { d.set(command.rawValue, forKey: "command") } }
    @Published var scrollSpeed: Double { didSet { d.set(scrollSpeed, forKey: "scrollSpeed") } }
    @Published var invertScroll: Bool { didSet { d.set(invertScroll, forKey: "invertScroll") } }
    @Published var showStats: Bool { didSet { d.set(showStats, forKey: "showStats") } }
    /// ⌘Tab, ⌘Space, Mission Control… go to the remote too (needs Accessibility permission).
    @Published var captureSystemKeys: Bool { didSet { d.set(captureSystemKeys, forKey: "captureSystemKeys") } }
    /// Horizontal position of the toolbar pill, as a fraction of the window width.
    @Published var pillX: Double { didSet { d.set(pillX, forKey: "pillX") } }
    @Published var remember: Bool { didSet { d.set(remember, forKey: "remember") } }
    /// Origins, most recent first.
    @Published private(set) var hosts: [String] { didSet { d.set(hosts, forKey: "hosts") } }

    private init() {
        d.register(defaults: ["quality": 0, "fps": 60, "scrollSpeed": 1.0, "pillX": 0.5, "remember": true])
        scale = ScaleMode(rawValue: d.string(forKey: "scale") ?? "") ?? .fit
        let q = d.integer(forKey: "quality")
        quality = Self.qualities.contains { $0.kbps == q } ? q : 0
        let f = d.integer(forKey: "fps")
        fps = Self.frameRates.contains(f) ? f : 60
        command = CommandKey(rawValue: d.string(forKey: "command") ?? "") ?? .ctrl
        scrollSpeed = min(3, max(0.25, d.double(forKey: "scrollSpeed")))
        invertScroll = d.bool(forKey: "invertScroll")
        showStats = d.bool(forKey: "showStats")
        captureSystemKeys = d.bool(forKey: "captureSystemKeys")
        pillX = min(0.95, max(0.05, d.double(forKey: "pillX")))
        remember = d.bool(forKey: "remember")
        hosts = (d.stringArray(forKey: "hosts") ?? []).filter { (try? HostAddress(parsing: $0)) != nil }
    }

    func noteHost(_ origin: String) {
        hosts = [origin] + hosts.filter { $0 != origin }.prefix(9)
    }

    func forgetHost(_ origin: String) {
        hosts.removeAll { $0 == origin }
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
