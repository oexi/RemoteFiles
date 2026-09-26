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
        handle.seek(toFileOffset: ArchiveManager.maxLegacyCompressedBytes + 1)
        try handle.write(contentsOf: Data([0]))
        try handle.close()

        XCTAssertThrowsError(try ArchiveManager.list(archive, originalName: "oversized.gz")) { error in
            guard case let RemoteProviderError.invalidResponse(message) = error else {
                return XCTFail("Expected the legacy input limit error, got \(error)")
            }
            XCTAssertTrue(message.contains("input bytes"))
        }
    }

    func testExtractEntryFromTarWritesOnlySelectedFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesTarEntryTest-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("sample.tar")
        let destination = root.appendingPathComponent("preview", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeTarArchive(
            entries: [
                ("folder/first.txt", Data("first".utf8)),
                ("folder/second.txt", Data("second".utf8))
            ],
            to: archive
        )

        let extracted = try ArchiveManager.extractEntry(
            "folder/second.txt",
            from: archive,
            originalName: "sample.tar",
            to: destination
        )

        XCTAssertEqual(extracted, destination.appendingPathComponent("folder/second.txt"))
        XCTAssertEqual(try String(contentsOf: extracted, encoding: .utf8), "second")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("folder/first.txt").path
        ))
    }

    func testExtractEntryFromZip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesZipEntryTest-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("note.txt")
        let archive = root.appendingPathComponent("note.zip")
        let destination = root.appendingPathComponent("preview", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("zip entry".utf8).write(to: source)
        try ArchiveManager.createZIP(from: source, at: archive)

        let extracted = try ArchiveManager.extractEntry(
            "note.txt",
            from: archive,
            originalName: "note.zip",
            to: destination
        )

        XCTAssertEqual(try String(contentsOf: extracted, encoding: .utf8), "zip entry")
    }

    func testExtractEntryRejectsMissingTarEntry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesTarMissingEntryTest-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("sample.tar")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeTarArchive(entries: [("a.txt", Data("a".utf8))], to: archive)

        XCTAssertThrowsError(try ArchiveManager.extractEntry(
            "b.txt",
            from: archive,
            originalName: "sample.tar",
            to: root.appendingPathComponent("preview", isDirectory: true)
        ))
    }

    func testSevenZipWithLZMA2ListsAndExtracts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesSevenZipTest-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("sample.7z")
        let destination = root.appendingPathComponent("extracted", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try SevenZipFixtures.lzma2.write(to: archive)

        let entries = try ArchiveManager.list(archive, originalName: "sample.7z")
        XCTAssertEqual(
            Set(entries.filter { $0.kind == .file }.map(\.path)),
            ["b.txt", "folder/a.txt", "folder/empty.txt"]
        )
        XCTAssertEqual(entries.first { $0.path == "folder" }?.kind, .directory)

        var reported: [Double] = []
        try ArchiveManager.extract(archive, originalName: "sample.7z", to: destination) { reported.append($0) }

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("folder/a.txt"), encoding: .utf8),
            "hello 7z"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("b.txt"), encoding: .utf8),
            "top level"
        )
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("folder/empty.txt")), Data())
        XCTAssertEqual(reported.last, 1)
        XCTAssertEqual(reported, reported.sorted())

        let preview = try ArchiveManager.extractEntry(
            "folder/a.txt",
            from: archive,
            originalName: "sample.7z",
            to: root.appendingPathComponent("preview", isDirectory: true)
        )
        XCTAssertEqual(try String(contentsOf: preview, encoding: .utf8), "hello 7z")
    }

    func testSevenZipMethodWithoutSWCompressionSupportUsesLibArchive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesSevenZipPPMdTest-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("ppmd.7z")
        let destination = root.appendingPathComponent("extracted", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try SevenZipFixtures.ppmd.write(to: archive)

        let entries = try ArchiveManager.list(archive, originalName: "ppmd.7z")
        XCTAssertEqual(
            Set(entries.filter { $0.kind == .file }.map(\.path)),
            ["b.txt", "folder/a.txt", "folder/empty.txt"]
        )
        try ArchiveManager.extract(archive, originalName: "ppmd.7z", to: destination)

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("folder/a.txt"), encoding: .utf8),
            "hello 7z"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("b.txt"), encoding: .utf8),
            "top level"
        )
    }

    func testZipExtractionReportsProgressUpToCompletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesZipProgressTest-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("payload", isDirectory: true)
        let archive = root.appendingPathComponent("payload.zip")
        let destination = root.appendingPathComponent("extracted", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 200_000).write(to: source.appendingPathComponent("a.txt"))
        try Data(repeating: 0x62, count: 100_000).write(to: source.appendingPathComponent("b.txt"))
        try ArchiveManager.createZIP(from: source, at: archive)

        var reported: [Double] = []
        try ArchiveManager.extract(archive, originalName: "payload.zip", to: destination) { reported.append($0) }

        XCTAssertGreaterThan(reported.count, 2)
        XCTAssertEqual(reported.last, 1)
        XCTAssertEqual(reported, reported.sorted())
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("payload/a.txt")).count,
            200_000
        )
    }

    func testByteProgressReporterReportsAtMostOncePerPercent() {
        var reported: [Double] = []
        let reporter = ByteProgressReporter(totalBytes: 1_000) { reported.append($0) }
        for _ in 0..<1_000 {
            reporter.advance(by: 1)
        }
        reporter.finish()

        XCTAssertEqual(reported.first, 0.001)
        XCTAssertEqual(reported.last, 1)
        XCTAssertLessThanOrEqual(reported.count, 101)
        XCTAssertEqual(reported, reported.sorted())
    }

    func testExtractionFolderNameIsNumberedWhenTaken() {
        XCTAssertEqual(ArchiveManager.extractionFolderName(for: "photos.zip", taken: []), "photos")
        XCTAssertEqual(
            ArchiveManager.extractionFolderName(for: "photos.zip", taken: ["Photos", "photos 2"]),
            "photos 3"
        )
    }

    func testSuggestedFolderNameStripsArchiveExtensions() {
        XCTAssertEqual(ArchiveManager.suggestedFolderName(for: "photos.zip"), "photos")
        XCTAssertEqual(ArchiveManager.suggestedFolderName(for: "src-1.2.tar.gz"), "src-1.2")
        XCTAssertEqual(ArchiveManager.suggestedFolderName(for: "backup.TAR.XZ"), "backup")
        XCTAssertEqual(ArchiveManager.suggestedFolderName(for: "data.tbz2"), "data")
        XCTAssertEqual(ArchiveManager.suggestedFolderName(for: "资料.7z"), "资料")
        XCTAssertEqual(ArchiveManager.suggestedFolderName(for: ".zip"), ".zip folder")
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

/// Archives made with the `7z` command-line tool. Both hold `folder/a.txt` ("hello 7z"),
/// an empty `folder/empty.txt` and `b.txt` ("top level").
enum SevenZipFixtures {
    /// 7-Zip's default output: LZMA2 data and an LZMA-compressed header, which the bundled
    /// libarchive (built without liblzma) cannot read.
    static let lzma2 = Data(base64Encoded:
        "N3q8ryccAARU99VdkgAAAAAAAAAhAAAAAAAAAIJMVAUBABB0b3AgbGV2ZWxoZWxsbyA3egAAAIEzB64Pz0tvjAfIQ39Bsfr9" +
        "5GF56W089iChtzmlbPsyF8NNC7G2toBMD06ol0eGhYWZJxcEiu/mAHNUvjgtDUv+OQZ73pVK6yD1i1PI4TtHTbeIPqz6l/VS" +
        "Hg4qSJfcmdM6/RTbrA56Kq/WYBUR7aiHHJOTxi1H8AAAABcGFQEJfQAHCwEAASMDAQEFXQAQAAAMgMYKAXRMfGYAAA=="
    )!

    /// PPMd data with a plain header (`-m0=PPMd -mhc=off`). SWCompression has no PPMd decoder,
    /// so libarchive reads this one.
    static let ppmd = Data(base64Encoded:
        "N3q8ryccAARCd1K0FAAAAAAAAADWAAAAAAAAAPx+xMAAc/lUU70jOPPzTFY9TxYTdHUQAAEEBgABCRQABwsBAAEjAwQBBQYA" +
        "AAEADBEACA0CCQkKAXPagfXry4nnAAAFBA4BwA8BQBkIAAAAAAAAAAARVwBmAG8AbABkAGUAcgAAAGYAbwBsAGQAZQByAC8A" +
        "ZQBtAHAAdAB5AC4AdAB4AHQAAABiAC4AdAB4AHQAAABmAG8AbABkAGUAcgAvAGEALgB0AHgAdAAAABkEAAAAABQiAQDjph5f" +
        "gk3dAeOmHl+CTd0B46YeX4JN3QHjph5fgk3dARUSAQAQgP1BIIC0gSCAtIEggLSBAAA="
    )!
}
