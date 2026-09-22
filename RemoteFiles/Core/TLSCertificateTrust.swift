import CryptoKit
import Foundation
import Security

enum TLSCertificateTrustError: LocalizedError {
    case changed(host: String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .changed(let host):
            "The TLS certificate for \(host) changed since it was first trusted. The connection was blocked to protect against a possible man-in-the-middle attack."
        case .keychain(let status):
            "Unable to access the TLS certificate store (Keychain status \(status))."
        }
    }
}

/// Trust-on-first-use pins for servers whose certificate the system does not
/// trust (typically a self-signed NAS certificate). Only used when the user
/// turns off certificate verification for a connection.
struct TLSCertificatePinStore: Sendable {
    private let service = "com.oexi.RemoteFiles.tls-pins"

    func load(host: String, port: Int) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(host: host, port: port, returnData: true) as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw TLSCertificateTrustError.keychain(status)
        }
        return value
    }

    func save(_ fingerprint: String, host: String, port: Int) throws {
        let base = query(host: host, port: port, returnData: false)
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(fingerprint.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw TLSCertificateTrustError.keychain(status) }
    }

    func remove(host: String, port: Int) {
        SecItemDelete(query(host: host, port: port, returnData: false) as CFDictionary)
    }

    private func query(host: String, port: Int, returnData: Bool) -> [String: Any] {
        var value: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(host.lowercased()):\(port)"
        ]
        if returnData {
            value[kSecReturnData as String] = true
            value[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return value
    }
}

enum TLSCertificateTrust {
    enum Decision: Equatable {
        case trusted
        case pinnedFirstUse(String)
        case rejected
    }

    /// SHA-256 of the leaf certificate's DER encoding, as lowercase hex.
    static func leafFingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Pure pin comparison so the policy can be tested without a live TLS handshake.
    static func decision(presented: String?, pinned: String?) -> Decision {
        guard let presented else { return .rejected }
        guard let pinned else { return .pinnedFirstUse(presented) }
        return pinned == presented ? .trusted : .rejected
    }

    /// Evaluates a server-trust challenge for a connection that allows
    /// untrusted certificates. The first certificate seen is pinned; a later
    /// different certificate is rejected until the user forgets the pin.
    static func evaluatePinned(_ trust: SecTrust, host: String, port: Int, store: TLSCertificatePinStore = .init()) -> Bool {
        let presented = leafFingerprint(of: trust)
        let pinned: String?
        do {
            pinned = try store.load(host: host, port: port)
        } catch {
            return false
        }
        switch decision(presented: presented, pinned: pinned) {
        case .trusted:
            return true
        case .pinnedFirstUse(let fingerprint):
            do {
                try store.save(fingerprint, host: host, port: port)
                return true
            } catch {
                return false
            }
        case .rejected:
            return false
        }
    }
}
