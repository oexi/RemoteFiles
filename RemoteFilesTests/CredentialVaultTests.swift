import Foundation
import Security
import XCTest
@testable import RemoteFiles

final class CredentialVaultTests: XCTestCase {
    func testSaveUsesUpdateForExistingItemAndReadsLatestPayload() throws {
        let keychain = InMemoryCredentialKeychain()
        let vault = makeVault(keychain)
        let profileID = UUID()

        try vault.save(Credential(username: "old-user", password: "old-password"), for: profileID)
        try vault.save(
            Credential(
                username: "new-user",
                password: "new-password",
                privateKey: Data("private-key".utf8),
                privateKeyName: "id_ed25519",
                privateKeyPassphrase: "passphrase"
            ),
            for: profileID
        )

        let loaded = try XCTUnwrap(try vault.load(for: profileID))
        XCTAssertEqual(loaded.username, "new-user")
        XCTAssertEqual(loaded.password, "new-password")
        XCTAssertEqual(loaded.privateKey, Data("private-key".utf8))
        XCTAssertEqual(loaded.privateKeyName, "id_ed25519")
        XCTAssertEqual(loaded.privateKeyPassphrase, "passphrase")
        XCTAssertEqual(keychain.updateCallCount, 2)
        XCTAssertEqual(keychain.addCallCount, 1)
    }

    func testMissingItemFallsBackToAdd() throws {
        let keychain = InMemoryCredentialKeychain()
        let vault = makeVault(keychain)
        let profileID = UUID()

        try vault.save(Credential(username: "user", password: "password"), for: profileID)

        XCTAssertEqual(keychain.updateCallCount, 1)
        XCTAssertEqual(keychain.addCallCount, 1)
        XCTAssertEqual(try vault.load(for: profileID)?.username, "user")
    }

    func testDuplicateAddRetriesUpdate() throws {
        let keychain = InMemoryCredentialKeychain()
        keychain.nextAddStatuses = [errSecDuplicateItem]
        let vault = makeVault(keychain)
        let profileID = UUID()

        try vault.save(Credential(username: "user", password: "password"), for: profileID)

        XCTAssertEqual(keychain.updateCallCount, 2)
        XCTAssertEqual(keychain.addCallCount, 1)
        XCTAssertEqual(try vault.load(for: profileID)?.password, "password")
    }

    func testUpdateFailureLeavesExistingValueUntouched() throws {
        let keychain = InMemoryCredentialKeychain()
        let vault = makeVault(keychain)
        let profileID = UUID()

        try vault.save(Credential(username: "old-user", password: "old-password"), for: profileID)
        keychain.nextUpdateStatuses = [-1]

        XCTAssertThrowsError(
            try vault.save(Credential(username: "new-user", password: "new-password"), for: profileID)
        )
        let loaded = try XCTUnwrap(try vault.load(for: profileID))
        XCTAssertEqual(loaded.username, "old-user")
        XCTAssertEqual(loaded.password, "old-password")
    }

    private func makeVault(_ keychain: InMemoryCredentialKeychain) -> CredentialVault {
        CredentialVault(
            service: "com.oexi.RemoteFiles.tests.\(UUID().uuidString)",
            keychain: keychain.operations
        )
    }
}

private final class InMemoryCredentialKeychain {
    private var values: [String: Data] = [:]
    private(set) var updateCallCount = 0
    private(set) var addCallCount = 0
    var nextUpdateStatuses: [OSStatus] = []
    var nextAddStatuses: [OSStatus] = []

    var operations: CredentialVault.KeychainOperations {
        CredentialVault.KeychainOperations(
            update: { [weak self] query, attributes in
                self?.update(query: query, attributes: attributes) ?? -1
            },
            add: { [weak self] query in
                self?.add(query: query) ?? -1
            },
            copyMatching: { [weak self] query in
                self?.copyMatching(query: query) ?? (-1, nil)
            },
            delete: { [weak self] query in
                self?.delete(query: query) ?? -1
            }
        )
    }

    private func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updateCallCount += 1
        if !nextUpdateStatuses.isEmpty {
            return nextUpdateStatuses.removeFirst()
        }
        let key = key(for: query)
        guard values[key] != nil else { return errSecItemNotFound }
        guard let data = attributes[kSecValueData as String] as? Data else { return -1 }
        values[key] = data
        return errSecSuccess
    }

    private func add(query: [String: Any]) -> OSStatus {
        addCallCount += 1
        let key = key(for: query)
        if !nextAddStatuses.isEmpty {
            let status = nextAddStatuses.removeFirst()
            if status == errSecDuplicateItem, values[key] == nil {
                values[key] = Data("concurrent-value".utf8)
            }
            return status
        }
        guard values[key] == nil else { return errSecDuplicateItem }
        guard let data = query[kSecValueData as String] as? Data else { return -1 }
        values[key] = data
        return errSecSuccess
    }

    private func copyMatching(query: [String: Any]) -> (status: OSStatus, data: Data?) {
        guard let data = values[key(for: query)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    private func delete(query: [String: Any]) -> OSStatus {
        values.removeValue(forKey: key(for: query))
        return errSecSuccess
    }

    private func key(for query: [String: Any]) -> String {
        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String ?? ""
        return "\(service)::\(account)"
    }
}
