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
    struct KeychainOperations {
        let update: (_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
        let add: (_ query: [String: Any]) -> OSStatus
        let copyMatching: (_ query: [String: Any]) -> (status: OSStatus, data: Data?)
        let delete: (_ query: [String: Any]) -> OSStatus

        init(
            update: @escaping (_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus,
            add: @escaping (_ query: [String: Any]) -> OSStatus,
            copyMatching: @escaping (_ query: [String: Any]) -> (status: OSStatus, data: Data?),
            delete: @escaping (_ query: [String: Any]) -> OSStatus
        ) {
            self.update = update
            self.add = add
            self.copyMatching = copyMatching
            self.delete = delete
        }

        static let live = Self(
            update: { query, attributes in
                SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            },
            add: { query in
                SecItemAdd(query as CFDictionary, nil)
            },
            copyMatching: { query in
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                return (status, result as? Data)
            },
            delete: { query in
                SecItemDelete(query as CFDictionary)
            }
        )
    }

    static let shared = CredentialVault()
    private let service: String
    private let keychain: KeychainOperations

    init(
        service: String = "com.oexi.RemoteFiles.credentials",
        keychain: KeychainOperations = .live
    ) {
        self.service = service
        self.keychain = keychain
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
        let updateStatus = keychain.update(base, attributes)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw VaultError.status(updateStatus)
        }

        var addQuery = base
        addQuery[kSecValueData as String] = payload
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = keychain.add(addQuery)
        if addStatus == errSecSuccess {
            return
        }

        // Another save may have inserted the item after the update missed it.
        // Update that item instead of treating the duplicate as a failed save.
        guard addStatus == errSecDuplicateItem else {
            throw VaultError.status(addStatus)
        }
        let retryStatus = keychain.update(base, attributes)
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
        let result = keychain.copyMatching(query)
        let status = result.status
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result.data else { throw VaultError.status(status) }
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
        _ = keychain.delete(query)
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
