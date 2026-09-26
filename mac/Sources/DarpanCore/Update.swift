import CryptoKit
import Foundation

/// A release's update manifest, `darpan-mac.json` (scripts/mac-manifest.sh), accepted only when its
/// Ed25519 signature checks out and it is newer than this app.
public struct UpdateManifest: Equatable {
    public var version: String
    public var build: Int
    public var url: URL
    public var sha256: String            // of the DMG, lowercase hex
    public var minMacOS: String

    public init(version: String, build: Int, url: URL, sha256: String, minMacOS: String) {
        self.version = version; self.build = build; self.url = url; self.sha256 = sha256; self.minMacOS = minMacOS
    }

    public enum Problem: Error, Equatable {
        case signature, format, notNewer, url, macOS
    }

    /// `json`: the exact bytes fetched; `signature`: the base64 text of `darpan-mac.json.sig`.
    /// `repo`: "owner/name" of the GitHub repository the DMG must come from (GitHub names ignore
    /// case, and so does this). The signature is
    /// checked before anything is parsed.
    public static func verify(json: Data, signature: Data, publicKey: Data, repo: String,
                              currentVersion: String, currentBuild: Int, macOS: OperatingSystemVersion) throws -> UpdateManifest {
        guard let text = String(data: signature, encoding: .utf8),
              let sig = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(sig, for: json) else { throw Problem.signature }
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let version = o["version"] as? String, let v = Self.parts(version), v.count == 3,
              let build = (o["build"] as? String).flatMap(Int.init) ?? (o["build"] as? Int),
              let url = (o["url"] as? String).flatMap(URL.init(string:)),
              let sha = o["sha256"] as? String, sha.count == 64, sha.allSatisfy(\.isHexDigit),
              let minOS = o["min_macos"] as? String, let m = Self.parts(minOS) else { throw Problem.format }
        guard url.scheme == "https", url.host == "github.com", url.query == nil,
              url.path.lowercased().hasPrefix("/\(repo.lowercased())/releases/download/"), url.lastPathComponent == "Darpan.dmg" else { throw Problem.url }
        let current = Self.parts(currentVersion) ?? [0, 0, 0]
        guard v.lexicographicallyPrecedes(current) == false,
              v != current || build > currentBuild else { throw Problem.notNewer }
        let os = [macOS.majorVersion, macOS.minorVersion, macOS.patchVersion]
        guard !os.lexicographicallyPrecedes(m + Array(repeating: 0, count: max(0, 3 - m.count))) else { throw Problem.macOS }
        return UpdateManifest(version: version, build: build, url: url, sha256: sha.lowercased(), minMacOS: minOS)
    }

    private static func parts(_ s: String) -> [Int]? {
        let p = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return p.map { $0! }
    }

    /// SHA-256 of a file, lowercase hex, read in 1 MiB pieces.
    public static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hash = SHA256()
        while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { hash.update(data: d) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
