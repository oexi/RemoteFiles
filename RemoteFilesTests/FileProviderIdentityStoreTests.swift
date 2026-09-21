import FileProvider
import Foundation
import XCTest
@testable import RemoteFiles

final class FileProviderIdentityStoreTests: XCTestCase {
    func testLegacyPathIdentifierRemainsValidBeforeAnyMove() throws {
        let directory = try temporaryDirectory()
        let store = FileProviderIdentityStore(profileID: UUID(), directory: directory)
        let codec = FileProviderPathCodec(rootPath: "/root")
        let identifier = codec.identifier(for: "/root/document.txt")

        XCTAssertEqual(
            try store.path(for: identifier, codec: codec),
            "/root/document.txt"
        )
        XCTAssertEqual(
            try store.identifier(for: "/root/document.txt", codec: codec),
            identifier
        )
    }

    func testExtensionMoveKeepsIdentifierAndPersistsNewPath() throws {
        let directory = try temporaryDirectory()
        let profileID = UUID()
        let codec = FileProviderPathCodec(rootPath: "/root")
        let store = FileProviderIdentityStore(profileID: profileID, directory: directory)
        let identifier = try store.identifier(for: "/root/old.txt", codec: codec)

        try store.relocate(
            identifier: identifier,
            from: "/root/old.txt",
            to: "/root/new.txt",
            codec: codec
        )

        XCTAssertEqual(
            try store.identifier(for: "/root/new.txt", codec: codec),
            identifier
        )
        XCTAssertEqual(
            try store.path(for: identifier, codec: codec),
            "/root/new.txt"
        )

        let reloaded = FileProviderIdentityStore(profileID: profileID, directory: directory)
        XCTAssertEqual(
            try reloaded.path(for: identifier, codec: codec),
            "/root/new.txt"
        )
    }

    func testExternalItemAtOldPathCannotReuseMovedLegacyIdentifier() throws {
        let directory = try temporaryDirectory()
        let codec = FileProviderPathCodec(rootPath: "/root")
        let store = FileProviderIdentityStore(profileID: UUID(), directory: directory)
        let movedIdentifier = try store.identifier(for: "/root/old.txt", codec: codec)

        try store.relocate(
            identifier: movedIdentifier,
            from: "/root/old.txt",
            to: "/root/new.txt",
            codec: codec
        )

        let externalIdentifier = try store.identifier(for: "/root/old.txt", codec: codec)
        XCTAssertNotEqual(externalIdentifier, movedIdentifier)
        XCTAssertEqual(
            try store.path(for: externalIdentifier, codec: codec),
            "/root/old.txt"
        )
        XCTAssertEqual(
            try store.path(for: movedIdentifier, codec: codec),
            "/root/new.txt"
        )
    }

    func testDirectoryMoveRewritesKnownDescendantIdentities() throws {
        let directory = try temporaryDirectory()
        let codec = FileProviderPathCodec(rootPath: "/root")
        let store = FileProviderIdentityStore(profileID: UUID(), directory: directory)
        try store.register(
            paths: ["/root/folder", "/root/folder/child.txt"],
            codec: codec
        )
        let folderIdentifier = codec.identifier(for: "/root/folder")
        let childIdentifier = codec.identifier(for: "/root/folder/child.txt")

        try store.relocate(
            identifier: folderIdentifier,
            from: "/root/folder",
            to: "/root/renamed",
            codec: codec
        )

        XCTAssertEqual(
            try store.identifier(for: "/root/renamed/child.txt", codec: codec),
            childIdentifier
        )
        XCTAssertEqual(
            try store.path(for: childIdentifier, codec: codec),
            "/root/renamed/child.txt"
        )
    }

    func testDirectoryMovePreservesUnobservedDescendantLegacyIdentifier() throws {
        let directory = try temporaryDirectory()
        let codec = FileProviderPathCodec(rootPath: "/root")
        let store = FileProviderIdentityStore(profileID: UUID(), directory: directory)
        let folderIdentifier = codec.identifier(for: "/root/folder")
        try store.register(paths: ["/root/folder"], codec: codec)

        try store.relocate(
            identifier: folderIdentifier,
            from: "/root/folder",
            to: "/root/renamed",
            codec: codec
        )

        let childIdentifier = codec.identifier(for: "/root/folder/child.txt")
        XCTAssertEqual(
            try store.identifier(for: "/root/renamed/child.txt", codec: codec),
            childIdentifier
        )
        XCTAssertEqual(
            try store.path(for: childIdentifier, codec: codec),
            "/root/renamed/child.txt"
        )
    }

    func testNewItemAtDirectoryOldPathGetsFreshIdentifier() throws {
        let directory = try temporaryDirectory()
        let codec = FileProviderPathCodec(rootPath: "/root")
        let store = FileProviderIdentityStore(profileID: UUID(), directory: directory)
        let folderIdentifier = codec.identifier(for: "/root/folder")
        try store.register(paths: ["/root/folder"], codec: codec)

        try store.relocate(
            identifier: folderIdentifier,
            from: "/root/folder",
            to: "/root/renamed",
            codec: codec
        )

        let externalIdentifier = try store.identifier(
            for: "/root/folder/child.txt",
            codec: codec
        )
        let oldChildIdentifier = codec.identifier(for: "/root/folder/child.txt")
        XCTAssertNotEqual(externalIdentifier, oldChildIdentifier)
        XCTAssertTrue(externalIdentifier.rawValue.hasPrefix("item:"))
        XCTAssertEqual(
            try store.path(for: externalIdentifier, codec: codec),
            "/root/folder/child.txt"
        )
    }

    func testMovedIdentifierIsNotReportedAsDeletedFromOldSnapshot() throws {
        let codec = FileProviderPathCodec(rootPath: "/root")
        let movedIdentifier = codec.identifier(for: "/root/old.txt")

        let deleted = fileProviderDeletedItemIdentifiers(
            previousFingerprints: ["/root/old.txt": "old"],
            previousIdentifiers: [:],
            currentIdentifiers: [movedIdentifier.rawValue],
            codec: codec
        )

        XCTAssertTrue(deleted.isEmpty)
    }

    func testExternalRenameStillProducesOldDeletionWhenIdentifierChanges() throws {
        let codec = FileProviderPathCodec(rootPath: "/root")
        let oldIdentifier = codec.identifier(for: "/root/old.txt")
        let newIdentifier = codec.identifier(for: "/root/new.txt")

        let deleted = fileProviderDeletedItemIdentifiers(
            previousFingerprints: ["/root/old.txt": "old"],
            previousIdentifiers: [:],
            currentIdentifiers: [newIdentifier.rawValue],
            codec: codec
        )

        XCTAssertEqual(deleted.map(\.rawValue), [oldIdentifier.rawValue])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesFileProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
