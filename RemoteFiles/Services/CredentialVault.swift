import Foundation
import Security

struct Credential: Sendable {
    let username: String
    let password: String
    let privateKey: Data?
    let privateKeyName: String?
    let privateKeyPassphrase: String?

    init(
        username: String,
        password: String,
        privateKey: Data? = nil,
        privateKeyName: String? = nil,
        privateKeyPassphrase: String? = nil
    ) {
        self.username = username
        self.password = password
        self.privateKey = privateKey
        self.privateKeyName = privateKeyName
        self.privateKeyPassphrase = privateKeyPassphrase
    }
}

final class CredentialVault: @unchecked Sendable {
    static let shared = CredentialVault()
    private let service: String

    init(service: String = "com.oexi.RemoteFiles.credentials") {
        self.service = service
    }

    func save(_ credential: Credential, for profileID: UUID) throws {
        let account = profileID.uuidString
        let payload = try JSONEncoder().encode(Payload(
            username: credential.username,
            password: credential.password,
            privateKey: credential.privateKey,
            privateKeyName: credential.privateKeyName,
            privateKeyPassphrase: credential.privateKeyPassphrase
        ))
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: payload]
        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw VaultError.status(updateStatus)
        }

        var addQuery = base
        addQuery[kSecValueData as String] = payload
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }

        // Another save may have inserted the item after the update missed it.
        // Update that item instead of treating the duplicate as a failed save.
        guard addStatus == errSecDuplicateItem else {
            throw VaultError.status(addStatus)
        }
        let retryStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        guard retryStatus == errSecSuccess else {
            throw VaultError.status(retryStatus)
        }
    }

    func load(for profileID: UUID) throws -> Credential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw VaultError.status(status) }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return Credential(
            username: payload.username,
            password: payload.password,
            privateKey: payload.privateKey,
            privateKeyName: payload.privateKeyName,
            privateKeyPassphrase: payload.privateKeyPassphrase
        )
    }

    func remove(for profileID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }

    private struct Payload: Codable {
        let username: String
        let password: String
        let privateKey: Data?
        let privateKeyName: String?
        let privateKeyPassphrase: String?
    }

    enum VaultError: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? {
            switch self {
            case .status(let status): "Keychain error: \(status)"
            }
        }
    }
}
