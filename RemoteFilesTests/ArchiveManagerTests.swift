import XCTest
@testable import RemoteFiles

final class ArchiveManagerTests: XCTestCase {
    func testSupportedArchiveNames() {
        for name in [
            "a.zip", "a.7z", "a.rar", "a.tar", "a.tgz", "a.tar.gz",
            "a.tbz2", "a.tar.bz2", "a.txz", "a.tar.xz", "a.gz", "a.bz2", "a.xz"
        ] {
            XCTAssertTrue(ArchiveManager.canOpen(fileName: name), name)
        }
        XCTAssertFalse(ArchiveManager.canOpen(fileName: "not-an-archive.txt"))
    }

    func testZipRoundTripExtraction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesArchiveTest-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.txt")
        let archive = root.appendingPathComponent("source.zip")
        let destination = root.appendingPathComponent("extracted", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source)
        try ArchiveManager.createZIP(from: source, at: archive)
        try ArchiveManager.extract(archive, originalName: "source.zip", to: destination)

        let extracted = destination.appendingPathComponent("source.txt")
        XCTAssertEqual(try String(contentsOf: extracted, encoding: .utf8), "hello")
    }

    func testZipDirectoryRoundTripExtraction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesArchiveDirectoryTest-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("uu-plugin-backup", isDirectory: true)
        let nested = source.appendingPathComponent("files/usr/bin", isDirectory: true)
        let sourceFile = nested.appendingPathComponent("helper")
        let archive = root.appendingPathComponent("uu-plugin-backup.zip")
        let destination = root.appendingPathComponent("extracted", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: sourceFile)
        try ArchiveManager.createZIP(from: source, at: archive)
        try ArchiveManager.extract(archive, originalName: "uu-plugin-backup.zip", to: destination)

        let extracted = destination
            .appendingPathComponent("uu-plugin-backup/files/usr/bin/helper")
        XCTAssertEqual(try String(contentsOf: extracted, encoding: .utf8), "#!/bin/sh\necho ok\n")
    }
}
