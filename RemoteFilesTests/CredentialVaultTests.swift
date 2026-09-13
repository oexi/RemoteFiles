import Foundation
import XCTest
@testable import RemoteFiles

final class CredentialVaultTests: XCTestCase {
    func testSavingSameProfileReplacesCredential() throws {
        let vault = CredentialVault(service: "com.oexi.RemoteFiles.tests.\(UUID().uuidString)")
        let profileID = UUID()
        defer { vault.remove(for: profileID) }

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
    }
}
