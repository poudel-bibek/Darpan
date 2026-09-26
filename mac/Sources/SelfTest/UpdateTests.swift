import CryptoKit
import DarpanCore
import Foundation

func updateTests() {
    section("update manifest") {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation
        let repo = "someone/Darpan"
        let sha = String(repeating: "ab", count: 32)
        func manifest(_ version: String = "1.3.0", build: String = "4", url: String? = nil, minOS: String = "14.0") -> Data {
            let u = url ?? "https://github.com/\(repo)/releases/download/v\(version)/Darpan.dmg"
            return Data(#"{"version":"\#(version)","build":"\#(build)","url":"\#(u)","sha256":"\#(sha)","min_macos":"\#(minOS)"}"#.utf8 + [0x0a])
        }
        func sign(_ d: Data, with k: Curve25519.Signing.PrivateKey = key) -> Data { Data(try! k.signature(for: d).base64EncodedString().utf8) }
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
        func run(_ json: Data, _ sig: Data? = nil, version: String = "1.2.0", build: Int = 3,
                 os: OperatingSystemVersion = sonoma) -> Result<UpdateManifest, UpdateManifest.Problem> {
            Result { try UpdateManifest.verify(json: json, signature: sig ?? sign(json), publicKey: pub, repo: repo,
                                               currentVersion: version, currentBuild: build, macOS: os) }
                .mapError { $0 as! UpdateManifest.Problem }
        }

        let ok = try run(manifest()).get()
        eq(ok.version, "1.3.0", "newer version accepted")
        eq(ok.build, 4, "build parsed")
        eq(ok.sha256, sha, "sha256 parsed")
        eq(run(manifest(), sign(manifest(), with: Curve25519.Signing.PrivateKey())).failure, .signature, "other key refused")
        var tampered = manifest(); tampered[12] ^= 1
        eq(run(tampered, sign(manifest())).failure, .signature, "changed bytes refused")
        eq(run(manifest(), Data("not base64".utf8)).failure, .signature, "garbage signature refused")
        eq(run(manifest("1.2.0", build: "3")).failure, .notNewer, "same version and build refused")
        eq(run(manifest("1.1.9", build: "9")).failure, .notNewer, "older version refused (no rollback)")
        eq((try? run(manifest("1.2.0", build: "4")).get())?.build, 4, "same version, newer build accepted")
        eq((try? run(manifest("1.10.0")).get())?.version, "1.10.0", "versions compare by number")
        eq(run(manifest(url: "http://github.com/\(repo)/releases/download/v1.3.0/Darpan.dmg")).failure, .url, "http refused")
        eq(run(manifest(url: "https://example.com/\(repo)/releases/download/v1.3.0/Darpan.dmg")).failure, .url, "other host refused")
        eq(run(manifest(url: "https://github.com/other/Darpan/releases/download/v1.3.0/Darpan.dmg")).failure, .url, "other repository refused")
        eq(run(manifest(url: "https://github.com/\(repo)/releases/download/v1.3.0/Other.dmg")).failure, .url, "other file refused")
        eq(run(manifest(minOS: "15.0")).failure, .macOS, "needs a newer macOS")
        eq(run(manifest("1.3"), nil).failure, .format, "malformed version refused")
        eq(run(Data("[]".utf8)).failure, .format, "not an object refused")

        let f = FileManager.default.temporaryDirectory.appendingPathComponent("darpan-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: f)
        eq(try UpdateManifest.sha256(of: f), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "file SHA-256")
        try? FileManager.default.removeItem(at: f)
    }
}

extension Result {
    var failure: Failure? { if case .failure(let e) = self { return e } else { return nil } }
}
