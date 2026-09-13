import Foundation
import XCTest
@testable import RemoteFiles

final class RemoteArchiveServiceTests: XCTestCase {
    func testExistingDirectoryIsReusedAndUploadsDoNotOverwrite() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }

        let provider = ArchiveTestProvider(archiveData: fixture.archiveData)
        provider.seedDirectory("/payload")
        provider.failDirectoryCreation(at: "/payload", with: .directoryCreationFailed)

        try await RemoteArchiveService.extractHere(item: fixture.item, provider: provider)

        XCTAssertEqual(provider.createdDirectoryPaths, ["/payload/nested"])
        XCTAssertEqual(provider.uploadedPaths, ["/payload/nested/note.txt"])
        XCTAssertEqual(provider.uploadOverwriteValues, [false])
    }

    func testExistingDirectoriesDoNotRequireCreateDirectoryCapability() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }

        let provider = ArchiveTestProvider(
            archiveData: fixture.archiveData,
            capabilities: ProviderCapabilities([.list, .read, .write])
        )
        provider.seedDirectory("/payload")
        provider.seedDirectory("/payload/nested")

        try await RemoteArchiveService.extractHere(item: fixture.item, provider: provider)

        XCTAssertTrue(provider.createdDirectoryPaths.isEmpty)
        XCTAssertEqual(provider.uploadedPaths, ["/payload/nested/note.txt"])
        XCTAssertEqual(provider.uploadOverwriteValues, [false])
    }

    func testExistingFileIsRejectedBeforeAnyWrite() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }

        let provider = ArchiveTestProvider(archiveData: fixture.archiveData)
        provider.seedDirectory("/payload")
        provider.seedDirectory("/payload/nested")
        provider.seedFile("/payload/nested/note.txt")

        do {
            try await RemoteArchiveService.extractHere(item: fixture.item, provider: provider)
            XCTFail("Expected a destination conflict")
        } catch let error as RemoteProviderError {
            guard case .conflict = error else {
                XCTFail("Expected a conflict, got \(error)")
                return
            }
        }

        XCTAssertTrue(provider.createdDirectoryPaths.isEmpty)
        XCTAssertTrue(provider.uploadedPaths.isEmpty)
    }

    func testListingFailureIsNotTreatedAsMissing() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }

        let provider = ArchiveTestProvider(archiveData: fixture.archiveData)
        provider.failListing(at: "/", with: .listingFailed)

        do {
            try await RemoteArchiveService.extractHere(item: fixture.item, provider: provider)
            XCTFail("Expected the listing error")
        } catch let error as ArchiveProviderError {
            XCTAssertEqual(error, .listingFailed)
        }

        XCTAssertTrue(provider.createdDirectoryPaths.isEmpty)
        XCTAssertTrue(provider.uploadedPaths.isEmpty)
    }

    func testDirectoryCreationFailureIsPropagated() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }

        let provider = ArchiveTestProvider(archiveData: fixture.archiveData)
        provider.failDirectoryCreation(at: "/payload", with: .directoryCreationFailed)

        do {
            try await RemoteArchiveService.extractHere(item: fixture.item, provider: provider)
            XCTFail("Expected the directory creation error")
        } catch let error as ArchiveProviderError {
            XCTAssertEqual(error, .directoryCreationFailed)
        }

        XCTAssertEqual(provider.createdDirectoryPaths, ["/payload"])
        XCTAssertTrue(provider.uploadedPaths.isEmpty)
    }
}

private final class ArchiveFixture {
    let root: URL
    let archiveData: Data
    let item: RemoteItem

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesRemoteArchiveTest-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("payload", isDirectory: true)
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        let archive = root.appendingPathComponent("payload.zip")

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("archive content".utf8).write(to: nested.appendingPathComponent("note.txt"))
        try ArchiveManager.createZIP(from: source, at: archive)

        archiveData = try Data(contentsOf: archive)
        item = RemoteItem(
            name: "payload.zip",
            path: "/payload.zip",
            kind: .file,
            revision: RemoteRevision(opaqueIdentifier: UUID().uuidString)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum ArchiveProviderError: Error, Equatable {
    case listingFailed
    case directoryCreationFailed
}

private final class ArchiveTestProvider: RemoteFileProvider, @unchecked Sendable {
    let profile = ConnectionProfile.empty(for: .sftp)
    let capabilities: ProviderCapabilities

    private let archiveData: Data
    private var items: [String: RemoteItemKind] = [:]
    private var listingErrors: [String: ArchiveProviderError] = [:]
    private var directoryErrors: [String: ArchiveProviderError] = [:]

    private(set) var createdDirectoryPaths: [String] = []
    private(set) var uploadedPaths: [String] = []
    private(set) var uploadOverwriteValues: [Bool] = []

    init(archiveData: Data, capabilities: ProviderCapabilities = .basicReadWrite) {
        self.archiveData = archiveData
        self.capabilities = capabilities
    }

    func seedDirectory(_ path: String) {
        items[RemotePath.normalize(path)] = .directory
    }

    func seedFile(_ path: String) {
        items[RemotePath.normalize(path)] = .file
    }

    func failListing(at path: String, with error: ArchiveProviderError) {
        listingErrors[RemotePath.normalize(path)] = error
    }

    func failDirectoryCreation(at path: String, with error: ArchiveProviderError) {
        directoryErrors[RemotePath.normalize(path)] = error
    }

    func connect() async throws { }

    func list(path: String) async throws -> [RemoteItem] {
        let normalized = RemotePath.normalize(path)
        if let error = listingErrors[normalized] { throw error }
        return items.keys.sorted().compactMap { childPath in
            guard RemotePath.parent(childPath) == normalized,
                  let kind = items[childPath] else { return nil }
            return RemoteItem(
                name: (childPath as NSString).lastPathComponent,
                path: childPath,
                kind: kind
            )
        }
    }

    func download(path: String, to localURL: URL) async throws {
        try archiveData.write(to: localURL)
    }

    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws {
        let normalized = RemotePath.normalize(path)
        if !overwrite, items[normalized] != nil {
            throw RemoteProviderError.conflict("An item already exists at \(normalized).")
        }
        uploadedPaths.append(normalized)
        uploadOverwriteValues.append(overwrite)
        items[normalized] = .file
    }

    func createDirectory(path: String) async throws {
        let normalized = RemotePath.normalize(path)
        createdDirectoryPaths.append(normalized)
        if let error = directoryErrors[normalized] { throw error }
        if let existing = items[normalized] {
            guard existing == .directory else {
                throw RemoteProviderError.conflict("An item already exists at \(normalized).")
            }
            return
        }
        items[normalized] = .directory
    }
}
