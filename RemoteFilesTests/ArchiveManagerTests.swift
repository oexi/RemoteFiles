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

    func testSingleZipFileExtractionCreatesMissingDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesSingleArchiveEntryTest-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.txt")
        let archive = root.appendingPathComponent("source.zip")
        let destination = root.appendingPathComponent("nested/output.txt")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("single entry".utf8).write(to: source)
        try ArchiveManager.createZIP(from: source, at: archive)

        try ArchiveManager.extract(entryPath: "source.txt", from: archive, to: destination)

        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "single entry"
        )
    }

    func testSingleArchiveEntryExtractionRejectsDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesSingleArchiveDirectoryTest-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("folder", isDirectory: true)
        let archive = root.appendingPathComponent("folder.zip")
        let destination = root.appendingPathComponent("output")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: source.appendingPathComponent("file.txt"))
        try ArchiveManager.createZIP(from: source, at: archive)
        let directoryPath = try XCTUnwrap(
            try ArchiveManager.list(archive, originalName: "folder.zip")
                .first(where: { $0.kind == .directory })?.path
        )

        XCTAssertThrowsError(
            try ArchiveManager.extract(entryPath: directoryPath, from: archive, to: destination)
        )
    }

    func testTarRoundTripUsesStreamingLibArchivePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesTarArchiveTest-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("sample.tar")
        let destination = root.appendingPathComponent("extracted", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeTarArchive(
            entries: [("folder/hello.txt", Data("hello from tar\n".utf8))],
            to: archive
        )

        let entries = try ArchiveManager.list(archive, originalName: "sample.tar")
        XCTAssertEqual(entries.map(\.path), ["folder/hello.txt"])
        XCTAssertEqual(entries.first?.uncompressedSize, 15)

        try ArchiveManager.extract(archive, originalName: "sample.tar", to: destination)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("folder/hello.txt"), encoding: .utf8),
            "hello from tar\n"
        )
    }

    func testLibArchiveRejectsUnsafeTarPathBeforeWriting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesUnsafeTarArchiveTest-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("unsafe.tar")
        let destination = root.appendingPathComponent("extracted", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeTarArchive(entries: [("../escaped.txt", Data("blocked".utf8))], to: archive)

        XCTAssertThrowsError(try ArchiveManager.extract(archive, originalName: "unsafe.tar", to: destination)) { error in
            guard case let RemoteProviderError.invalidResponse(message) = error else {
                return XCTFail("Expected an unsafe archive path error, got \(error)")
            }
            XCTAssertTrue(message.contains("unsafe archive path"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escaped.txt").path))
    }

    func testLibArchiveEntryCountLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesArchiveEntryLimitTest-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("many.tar")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = (0...ArchiveManager.maxArchiveEntryCount).map { index in
            ("entry-\(index).txt", Data())
        }
        try writeTarArchive(entries: entries, to: archive)

        XCTAssertThrowsError(try ArchiveManager.list(archive, originalName: "many.tar")) { error in
            guard case let RemoteProviderError.invalidResponse(message) = error else {
                return XCTFail("Expected the entry count limit error, got \(error)")
            }
            XCTAssertTrue(message.contains("too many entries"))
        }
    }

    func testLegacyCompressedInputLimitIsEnforcedBeforeDecode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesLegacyArchiveLimitTest-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("oversized.gz")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: archive.path, contents: nil)
        let handle = try FileHandle(forWritingTo: archive)
        try handle.seek(toFileOffset: ArchiveManager.maxLegacyCompressedBytes + 1)
        try handle.write(contentsOf: Data([0]))
        try handle.close()

        XCTAssertThrowsError(try ArchiveManager.list(archive, originalName: "oversized.gz")) { error in
            guard case let RemoteProviderError.invalidResponse(message) = error else {
                return XCTFail("Expected the legacy input limit error, got \(error)")
            }
            XCTAssertTrue(message.contains("input bytes"))
        }
    }

    private func writeTarArchive(
        entries: [(path: String, data: Data)],
        to url: URL
    ) throws {
        var archive = Data(capacity: entries.count * 1_024 + 1_024)
        for entry in entries {
            var header = Data(repeating: 0, count: 512)
            writeTarString(entry.path, to: &header, offset: 0, length: 100)
            writeTarOctal(0o644, to: &header, offset: 100, length: 8)
            writeTarOctal(0, to: &header, offset: 108, length: 8)
            writeTarOctal(0, to: &header, offset: 116, length: 8)
            writeTarOctal(Int64(entry.data.count), to: &header, offset: 124, length: 12)
            writeTarOctal(0, to: &header, offset: 136, length: 12)
            for index in 148..<156 { header[index] = 0x20 }
            header[156] = 0x30
            writeTarString("ustar", to: &header, offset: 257, length: 6)
            writeTarString("00", to: &header, offset: 263, length: 2)
            let checksum = header.reduce(0) { $0 + UInt64($1) }
            let checksumString = String(checksum, radix: 8)
            let checksumField = String(repeating: "0", count: 6 - checksumString.count)
                + checksumString + "\0 "
            header.replaceSubrange(148..<156, with: checksumField.utf8)

            archive.append(header)
            archive.append(entry.data)
            let padding = (512 - (entry.data.count % 512)) % 512
            archive.append(Data(repeating: 0, count: padding))
        }
        archive.append(Data(repeating: 0, count: 1_024))
        try archive.write(to: url, options: .atomic)
    }

    private func writeTarString(
        _ value: String,
        to header: inout Data,
        offset: Int,
        length: Int
    ) {
        let bytes = Array(value.utf8.prefix(length - 1))
        header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    private func writeTarOctal(
        _ value: Int64,
        to header: inout Data,
        offset: Int,
        length: Int
    ) {
        let octal = String(value, radix: 8)
        let field = String(repeating: "0", count: max(0, length - 1 - octal.count)) + octal + "\0"
        header.replaceSubrange(offset..<(offset + length), with: field.utf8)
    }
}
