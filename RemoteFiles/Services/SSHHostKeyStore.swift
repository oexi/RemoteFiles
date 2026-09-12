import Foundation
import NIOCore
import NIOSSH
import Security

enum SSHHostKeyError: LocalizedError {
    case changed(host: String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .changed(let host):
            "The SSH host key for \(host) changed. The connection was blocked to protect against a possible man-in-the-middle attack."
        case .keychain(let status):
            "Unable to access the SSH host-key store (Keychain status \(status))."
        }
    }
}

final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let store = SSHHostKeyStore()

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let serialized = String(openSSHPublicKey: hostKey)
        do {
            if let known = try store.load(host: host, port: port) {
                guard known == serialized else {
                    validationCompletePromise.fail(SSHHostKeyError.changed(host: "\(host):\(port)"))
                    return
                }
            } else {
                try store.save(serialized, host: host, port: port)
            }
            validationCompletePromise.succeed(())
        } catch {
            validationCompletePromise.fail(error)
        }
    }
}

struct SSHHostKeyStore: Sendable {
    private let service = "com.example.RemoteFiles.ssh-hostkeys"

    func load(host: String, port: Int) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(host: host, port: port, returnData: true) as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SSHHostKeyError.keychain(status)
        }
        return value
    }

    func save(_ key: String, host: String, port: Int) throws {
        let base = query(host: host, port: port, returnData: false)
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw SSHHostKeyError.keychain(status) }
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

