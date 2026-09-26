import CommonCrypto
import CryptoKit
import Foundation

/// Challenge–response sign-in (PROTOCOL.md §2). The password never leaves this Mac: only
/// PBKDF2(password, salt) is kept (in the Keychain) and each session proves knowledge of it
/// by HMAC-ing the host's fresh nonce.
public enum Auth {
    public static let label = Array("darpan-auth-v1".utf8)
    public static let keyLength = 32
    /// A host asking for fewer iterations would make an overheard proof cheap to brute-force.
    public static let iterationRange = 100_000...10_000_000

    public enum Failure: Error, Equatable {
        case badParameters
        case derivationFailed(Int32)
    }

    /// PBKDF2-HMAC-SHA256 over the NFC-normalised UTF-8 password.
    public static func deriveKey(password: String, salt: Data, iterations: Int) throws -> Data {
        guard iterationRange.contains(iterations), !salt.isEmpty, salt.count <= 1024 else {
            throw Failure.badParameters
        }
        let pw = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var key = [UInt8](repeating: 0, count: keyLength)
        let rc: Int32 = pw.withUnsafeBytes { p in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     p.baseAddress?.assumingMemoryBound(to: CChar.self), pw.count,
                                     s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     &key, keyLength)
            }
        }
        guard rc == Int32(kCCSuccess) else { throw Failure.derivationFailed(rc) }
        return Data(key)
    }

    /// HMAC-SHA256(key, "darpan-auth-v1" || nonce).
    public static func proof(key: Data, nonce: Data) -> Data {
        var msg = Data(label)
        msg.append(nonce)
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
    }

    /// `auth.client` — shown in the host's session list.
    public static func clientName(version: String = DarpanVersion.string) -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
                                    : "\(v.majorVersion).\(v.minorVersion)"
        return "Darpan for Mac \(version) on macOS \(os)"
    }
}

public enum DarpanVersion {
    public static let string = "1.0.0"
    public static let proto = 1
}
