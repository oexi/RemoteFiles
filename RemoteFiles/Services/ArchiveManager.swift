import Foundation
import LibArchive
import SWCompression
import ZIPFoundation

struct ArchiveEntryInfo: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let kind: RemoteItemKind
    let uncompressedSize: UInt64
    let compressedSize: UInt64
}

enum ArchiveManager {
    static let supportedExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "tgz", "tbz2", "txz", "gz", "bz2", "xz"
    ]

    // These limits apply before any archive payload is written. The libarchive
    // path is streamed, while SWCompression still needs a bounded input and
    // output buffer for formats it cannot stream on this platform.
    static let maxArchiveEntryCount = 10_000
    static let maxSingleFileBytes: UInt64 = 512 * 1024 * 1024
    static let maxTotalUncompressedBytes: UInt64 = 2 * 1024 * 1024 * 1024
    static let maxLegacyCompressedBytes: UInt64 = 64 * 1024 * 1024
    static let maxLegacyDecodedBytes: UInt64 = 256 * 1024 * 1024
    static let minimumFreeSpaceReserveBytes: UInt64 = 16 * 1024 * 1024

    static func canOpen(fileName: String) -> Bool {
        format(for: fileName) != nil
    }

    static func list(_ archiveURL: URL, originalName: String) throws -> [ArchiveEntryInfo] {
        guard let format = format(for: originalName) else {
            throw RemoteProviderError.unsupported("Unsupported archive format.")
        }
        switch format {
        case .zip:
            return try zipEntries(at: archiveURL)
        case .sevenZip:
            guard let sevenZipEntries = try decodedSevenZipEntries(at: archiveURL) else {
                return try libArchiveEntries(at: archiveURL)
            }
            let entries = sevenZipEntries.map(sevenZipEntryInfo)
            try preflight(entries: entries)
            return entries
        case .rar, .tar, .tarGzip:
            return try libArchiveEntries(at: archiveURL)
        case .tarBzip2, .tarXz:
            return try legacyTarEntries(at: archiveURL, format: format)
        case .gzip, .bzip2, .xz:
            let data = try decodeSingleFile(at: archiveURL, format: format)
            let entries = [ArchiveEntryInfo(
                path: outputName(for: originalName),
                kind: .file,
                uncompressedSize: UInt64(data.count),
                compressedSize: try archiveFileSize(at: archiveURL)
            )]
            try preflight(entries: entries)
            return entries
        }
    }

    /// Extracts the whole archive below `destination`. `progress` receives the fraction of
    /// uncompressed bytes written so far, at most about once per percent.
    static func extract(
        _ archiveURL: URL,
        originalName: String,
        to destination: URL,
        progress: ((Double) -> Void)? = nil
    ) throws {
        guard let format = format(for: originalName) else {
            throw RemoteProviderError.unsupported("Unsupported archive format.")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        switch format {
        case .zip:
            let entries = try zipEntries(at: archiveURL)
            try preflight(entries: entries, destination: destination)
            let reporter = progressReporter(for: entries, progress)
            let archive = try Archive(url: archiveURL, accessMode: .read)
            for entry in archive {
                let relativePath = try validatedRelativePath(entry.path)
                guard !relativePath.isEmpty else { continue }
                let target = destination.appendingPathComponent(relativePath)
                switch entry.type {
                case .directory:
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                case .symlink:
                    // Never materialize links from untrusted archives. A valid-looking entry path can
                    // still point outside the extraction root through the link target.
                    continue
                case .file:
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try extractZipFile(entry, from: archive, to: target, reporter: reporter)
                }
            }
        case .sevenZip:
            if let sevenZipEntries = try decodedSevenZipEntries(at: archiveURL) {
                let entries = sevenZipEntries.map(sevenZipEntryInfo)
                try preflight(entries: entries, destination: destination)
                try extract(
                    entries: sevenZipEntries.map { ($0.info.name, remoteKind($0.info.type), $0.data) },
                    to: destination,
                    reporter: progressReporter(for: entries, progress)
                )
            } else {
                let entries = try libArchiveEntries(at: archiveURL)
                try preflight(entries: entries, destination: destination)
                try extractLibArchive(
                    at: archiveURL,
                    entries: entries,
                    to: destination,
                    reporter: progressReporter(for: entries, progress)
                )
            }
        case .rar, .tar, .tarGzip:
            let entries = try libArchiveEntries(at: archiveURL)
            try preflight(entries: entries, destination: destination)
            try extractLibArchive(
                at: archiveURL,
                entries: entries,
                to: destination,
                reporter: progressReporter(for: entries, progress)
            )
        case .tarBzip2, .tarXz:
            let tarData = try decodedTarData(at: archiveURL, format: format)
            let entries = try legacyTarEntries(from: tarData)
            try preflight(entries: entries, destination: destination)
            let tarEntries = try TarContainer.open(container: tarData)
            try extract(
                entries: tarEntries.map { ($0.info.name, remoteKind($0.info.type), $0.data) },
                to: destination,
                reporter: progressReporter(for: entries, progress)
            )
        case .gzip, .bzip2, .xz:
            let relativePath = try validatedRelativePath(outputName(for: originalName))
            let data = try decodeSingleFile(at: archiveURL, format: format)
            let entries = [ArchiveEntryInfo(
                path: relativePath,
                kind: .file,
                uncompressedSize: UInt64(data.count),
                compressedSize: try archiveFileSize(at: archiveURL)
            )]
            try preflight(entries: entries, destination: destination)
            let output = destination.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: output, options: .atomic)
        }
        progress?(1)
    }

    static func extract(entryPath: String, from archiveURL: URL, to destination: URL) throws {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        guard let entry = archive[entryPath] else {
            throw RemoteProviderError.invalidResponse("Archive entry does not exist.")
        }
        guard entry.type == .file else {
            throw RemoteProviderError.invalidResponse("Only regular archive files can be extracted.")
        }
        let relativePath = try validatedRelativePath(entry.path)
        guard !relativePath.isEmpty else {
            throw RemoteProviderError.invalidResponse("Archive entry has an empty path.")
        }
        guard entry.uncompressedSize <= maxSingleFileBytes else {
            throw RemoteProviderError.invalidResponse(
                "Archive entry exceeds the \(maxSingleFileBytes)-byte file limit."
            )
        }
        let info = ArchiveEntryInfo(
            path: relativePath,
            kind: .file,
            uncompressedSize: entry.uncompressedSize,
            compressedSize: entry.compressedSize
        )
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var destinationIsDirectory = ObjCBool(false)
        guard !FileManager.default.fileExists(
            atPath: destination.path,
            isDirectory: &destinationIsDirectory
        ) || !destinationIsDirectory.boolValue else {
            throw RemoteProviderError.conflict("The archive destination is a directory.")
        }
        try preflight(entries: [info], destination: parent)
        _ = try archive.extract(entry, to: destination)
    }

    /// Extracts one regular-file entry of any supported format below `destination`
    /// and returns the extracted file's URL. Used to preview a single archive member.
    static func extractEntry(
        _ entryPath: String,
        from archiveURL: URL,
        originalName: String,
        to destination: URL
    ) throws -> URL {
        guard let format = format(for: originalName) else {
            throw RemoteProviderError.unsupported("Unsupported archive format.")
        }
        let relativePath = try validatedRelativePath(entryPath)
        guard !relativePath.isEmpty else {
            throw RemoteProviderError.invalidResponse("Archive entry has an empty path.")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent(relativePath)
        switch format {
        case .zip:
            try extract(entryPath: entryPath, from: archiveURL, to: target)
        case .sevenZip:
            if let sevenZipEntries = try decodedSevenZipEntries(at: archiveURL) {
                guard let match = sevenZipEntries.first(where: {
                    $0.info.name == entryPath && remoteKind($0.info.type) == .file
                }) else {
                    throw RemoteProviderError.invalidResponse("Archive entry does not exist.")
                }
                try preflight(entries: [sevenZipEntryInfo(match)], destination: destination)
                try extract(entries: [(match.info.name, .file, match.data)], to: destination)
            } else {
                try extractLibArchiveEntry(entryPath, from: archiveURL, to: destination)
            }
        case .rar, .tar, .tarGzip:
            try extractLibArchiveEntry(entryPath, from: archiveURL, to: destination)
        case .tarBzip2, .tarXz:
            let tarEntries = try TarContainer.open(container: decodedTarData(at: archiveURL, format: format))
            guard let match = tarEntries.first(where: {
                $0.info.name == entryPath && remoteKind($0.info.type) == .file
            }) else {
                throw RemoteProviderError.invalidResponse("Archive entry does not exist.")
            }
            try preflight(entries: [ArchiveEntryInfo(
                path: entryPath,
                kind: .file,
                uncompressedSize: UInt64(match.data?.count ?? 0),
                compressedSize: 0
            )], destination: destination)
            try extract(entries: [(match.info.name, .file, match.data)], to: destination)
        case .gzip, .bzip2, .xz:
            try extract(archiveURL, originalName: originalName, to: destination)
        }
        return target
    }

    /// The folder name to extract into: the archive name without its archive extension.
    static func suggestedFolderName(for archiveName: String) -> String {
        let lower = archiveName.lowercased()
        let suffixes = [
            ".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".txz",
            ".tar", ".zip", ".7z", ".rar", ".gz", ".bz2", ".xz"
        ]
        for suffix in suffixes where lower.hasSuffix(suffix) {
            let stem = String(archiveName.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespaces)
            return stem.isEmpty ? archiveName + " folder" : stem
        }
        return archiveName + " folder"
    }

    /// `suggestedFolderName(for:)`, numbered ("name 2", "name 3", …) when a name in
    /// `taken` already uses it, compared case-insensitively.
    static func extractionFolderName(for archiveName: String, taken: [String]) -> String {
        let takenNames = Set(taken.map { $0.lowercased() })
        let baseName = suggestedFolderName(for: archiveName)
        var folderName = baseName
        var suffix = 2
        while takenNames.contains(folderName.lowercased()) {
            folderName = "\(baseName) \(suffix)"
            suffix += 1
        }
        return folderName
    }

    static func createZIP(from source: URL, at destination: URL) throws {
        try FileManager.default.zipItem(at: source, to: destination, shouldKeepParent: source.hasDirectoryPath)
    }

    private enum Format {
        case zip, sevenZip, rar, tar, tarGzip, tarBzip2, tarXz, gzip, bzip2, xz
    }

    private static func zipEntries(at url: URL) throws -> [ArchiveEntryInfo] {
        let archive = try Archive(url: url, accessMode: .read)
        var result: [ArchiveEntryInfo] = []
        for entry in archive {
            guard result.count < maxArchiveEntryCount else {
                throw RemoteProviderError.invalidResponse("Archive contains too many entries.")
            }
            result.append(ArchiveEntryInfo(
                path: entry.path,
                kind: entry.type == .directory ? .directory : (entry.type == .symlink ? .symbolicLink : .file),
                uncompressedSize: entry.uncompressedSize,
                compressedSize: entry.compressedSize
            ))
        }
        try preflight(entries: result)
        return result
    }

    private static func libArchiveEntries(at url: URL) throws -> [ArchiveEntryInfo] {
        var result: [ArchiveEntryInfo] = []
        var normalizedPaths = Set<String>()
        var totalBytes: UInt64 = 0
        try withLibArchiveErrors { try ArchiveReader().readDataBlocks(
            in: url,
            selecting: { entry in
                guard result.count < maxArchiveEntryCount else {
                    throw RemoteProviderError.invalidResponse("Archive contains too many entries.")
                }
                let info = try archiveEntryInfo(entry)
                let relativePath = try validatedRelativePath(info.path)
                guard normalizedPaths.insert(relativePath).inserted else {
                    throw RemoteProviderError.invalidResponse("Archive contains duplicate entry paths.")
                }
                if info.kind == .file {
                    guard info.uncompressedSize <= maxSingleFileBytes else {
                        throw RemoteProviderError.invalidResponse(
                            "Archive entry exceeds the \(maxSingleFileBytes)-byte file limit."
                        )
                    }
                    let (updatedTotal, overflow) = totalBytes.addingReportingOverflow(info.uncompressedSize)
                    guard !overflow, updatedTotal <= maxTotalUncompressedBytes else {
                        throw RemoteProviderError.invalidResponse(
                            "Archive exceeds the \(maxTotalUncompressedBytes)-byte extraction limit."
                        )
                    }
                    totalBytes = updatedTotal
                }
                result.append(info)
                return .skip
            }
        ) { _, _ in
            .continueReading
        } }
        try preflight(entries: result)
        return result
    }

    private static func sevenZipEntryInfo(_ entry: SevenZipEntry) -> ArchiveEntryInfo {
        ArchiveEntryInfo(
            path: entry.info.name,
            kind: remoteKind(entry.info.type),
            uncompressedSize: UInt64(entry.data?.count ?? 0),
            compressedSize: 0
        )
    }

    /// The bundled libarchive is built without liblzma, so it cannot decode LZMA or LZMA2,
    /// which 7-Zip uses by default (usually for the archive header as well). SWCompression
    /// decodes those in memory. This returns nil when the archive is too large to decode in
    /// memory or uses a method SWCompression lacks (PPMd, BCJ filters); libarchive streams
    /// those instead.
    private static func decodedSevenZipEntries(at url: URL) throws -> [SevenZipEntry]? {
        guard try archiveFileSize(at: url) <= maxLegacyCompressedBytes else { return nil }
        let entries: [SevenZipEntry]
        do {
            entries = try SevenZipContainer.open(container: boundedLegacyInput(at: url))
        } catch SevenZipError.compressionNotSupported, SevenZipError.multiStreamNotSupported {
            return nil
        } catch SevenZipError.encryptionNotSupported {
            throw RemoteProviderError.unsupported("Encrypted 7-Zip archives are not supported.")
        } catch let error as SevenZipError {
            throw RemoteProviderError.invalidResponse("Unable to read the 7-Zip archive (\(error)).")
        }
        guard entries.count <= maxArchiveEntryCount else {
            throw RemoteProviderError.invalidResponse("Archive contains too many entries.")
        }
        var decodedBytes: UInt64 = 0
        for entry in entries {
            decodedBytes += UInt64(entry.data?.count ?? 0)
            guard decodedBytes <= maxLegacyDecodedBytes else {
                throw RemoteProviderError.invalidResponse(
                    "This compressed format is limited to \(maxLegacyDecodedBytes) decoded bytes."
                )
            }
        }
        // Anti-items only mark deletions for an update of an existing archive.
        return entries.filter { !$0.info.isAnti }
    }

    /// libarchive-swift's errors reach the UI as "LibArchive.ArchiveError error N", which
    /// hides the reason. Rethrow them with libarchive's own message.
    private static func withLibArchiveErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ArchiveError {
            switch error {
            case .readFailed(let message), .writeFailed(let message):
                throw RemoteProviderError.invalidResponse(message)
            case .cannotOpenArchive(_, let message), .cannotCreateDirectory(_, let message):
                throw RemoteProviderError.invalidResponse(message)
            case .unsafeEntryPath(let path), .unsafeLinkPath(let path, _):
                throw RemoteProviderError.invalidResponse("Blocked an unsafe archive path: \(path)")
            default:
                throw RemoteProviderError.invalidResponse("The archive could not be read: \(error).")
            }
        }
    }

    private static func archiveEntryInfo(_ entry: ArchiveEntry) throws -> ArchiveEntryInfo {
        guard entry.size >= 0 else {
            throw RemoteProviderError.invalidResponse("Archive entry has an invalid size.")
        }
        return ArchiveEntryInfo(
            path: entry.path,
            kind: remoteKind(entry.fileType),
            uncompressedSize: UInt64(entry.size),
            compressedSize: 0
        )
    }

    private static func legacyTarEntries(at url: URL, format: Format) throws -> [ArchiveEntryInfo] {
        let entries = try legacyTarEntries(from: decodedTarData(at: url, format: format))
        try preflight(entries: entries)
        return entries
    }

    private static func legacyTarEntries(from data: Data) throws -> [ArchiveEntryInfo] {
        let infos = try TarContainer.info(container: data)
        guard infos.count <= maxArchiveEntryCount else {
            throw RemoteProviderError.invalidResponse("Archive contains too many entries.")
        }
        return try infos.map { info in
            let size: UInt64
            if let rawSize = info.size {
                guard rawSize >= 0 else {
                    throw RemoteProviderError.invalidResponse("Archive entry has an invalid size.")
                }
                size = UInt64(rawSize)
            } else if info.type == .directory || info.type == .symbolicLink || info.type == .hardLink {
                size = 0
            } else {
                throw RemoteProviderError.invalidResponse("Archive entry size is unavailable.")
            }
            return ArchiveEntryInfo(
                path: info.name,
                kind: remoteKind(info.type),
                uncompressedSize: size,
                compressedSize: 0
            )
        }
    }

    private static func preflight(
        entries: [ArchiveEntryInfo],
        destination: URL? = nil
    ) throws {
        guard entries.count <= maxArchiveEntryCount else {
            throw RemoteProviderError.invalidResponse("Archive contains too many entries.")
        }

        var totalBytes: UInt64 = 0
        var normalizedPaths = Set<String>()
        for entry in entries {
            let relativePath = try validatedRelativePath(entry.path)
            guard normalizedPaths.insert(relativePath).inserted else {
                throw RemoteProviderError.invalidResponse("Archive contains duplicate entry paths.")
            }
            guard entry.kind == .file else { continue }
            guard entry.uncompressedSize <= maxSingleFileBytes else {
                throw RemoteProviderError.invalidResponse(
                    "Archive entry exceeds the \(maxSingleFileBytes)-byte file limit."
                )
            }
            let (updatedTotal, overflow) = totalBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, updatedTotal <= maxTotalUncompressedBytes else {
                throw RemoteProviderError.invalidResponse(
                    "Archive exceeds the \(maxTotalUncompressedBytes)-byte extraction limit."
                )
            }
            totalBytes = updatedTotal
        }

        guard let destination else { return }
        let (requiredBytes, overflow) = totalBytes.addingReportingOverflow(minimumFreeSpaceReserveBytes)
        guard !overflow else {
            throw RemoteProviderError.invalidResponse("Archive extraction size is too large.")
        }
        let availableBytes = try availableDiskSpace(at: destination)
        guard availableBytes >= requiredBytes else {
            throw RemoteProviderError.invalidResponse(
                "Not enough free space is available to extract this archive."
            )
        }
    }

    private static func availableDiskSpace(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        guard let freeSize = attributes[.systemFreeSize] as? NSNumber,
              freeSize.int64Value >= 0 else {
            throw RemoteProviderError.invalidResponse("Unable to determine available disk space.")
        }
        return UInt64(freeSize.int64Value)
    }

    private static func archiveFileSize(at url: URL) throws -> UInt64 {
        guard let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize >= 0 else {
            throw RemoteProviderError.invalidResponse("Unable to determine archive input size.")
        }
        return UInt64(fileSize)
    }

    private static func format(for fileName: String) -> Format? {
        let name = fileName.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGzip }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") { return .tarBzip2 }
        if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { return .tarXz }
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".7z") { return .sevenZip }
        if name.hasSuffix(".rar") { return .rar }
        if name.hasSuffix(".tar") { return .tar }
        if name.hasSuffix(".gz") { return .gzip }
        if name.hasSuffix(".bz2") { return .bzip2 }
        if name.hasSuffix(".xz") { return .xz }
        return nil
    }

    private static func decodedTarData(at url: URL, format: Format) throws -> Data {
        let data = try boundedLegacyInput(at: url)
        let decoded: Data
        switch format {
        case .tar: decoded = data
        case .tarGzip: decoded = try GzipArchive.unarchive(archive: data)
        case .tarBzip2: decoded = try BZip2.decompress(data: data)
        case .tarXz: decoded = try XZArchive.unarchive(archive: data)
        default: throw RemoteProviderError.invalidConfiguration("Not a TAR-based format.")
        }
        try enforceLegacyDecodedSize(decoded)
        return decoded
    }

    private static func decodeSingleFile(at url: URL, format: Format) throws -> Data {
        let data = try boundedLegacyInput(at: url)
        let decoded: Data
        switch format {
        case .gzip: decoded = try GzipArchive.unarchive(archive: data)
        case .bzip2: decoded = try BZip2.decompress(data: data)
        case .xz: decoded = try XZArchive.unarchive(archive: data)
        default: throw RemoteProviderError.invalidConfiguration("Not a single-file compressed format.")
        }
        try enforceLegacyDecodedSize(decoded)
        return decoded
    }

    private static func boundedLegacyInput(at url: URL) throws -> Data {
        let fileSize = try archiveFileSize(at: url)
        guard fileSize <= maxLegacyCompressedBytes else {
            throw RemoteProviderError.invalidResponse(
                "This compressed format is limited to \(maxLegacyCompressedBytes) input bytes."
            )
        }
        let data = try Data(contentsOf: url)
        guard UInt64(data.count) <= maxLegacyCompressedBytes else {
            throw RemoteProviderError.invalidResponse(
                "This compressed format is limited to \(maxLegacyCompressedBytes) input bytes."
            )
        }
        return data
    }

    private static func enforceLegacyDecodedSize(_ data: Data) throws {
        guard UInt64(data.count) <= maxLegacyDecodedBytes else {
            throw RemoteProviderError.invalidResponse(
                "This compressed format is limited to \(maxLegacyDecodedBytes) decoded bytes."
            )
        }
    }

    private static func outputName(for originalName: String) -> String {
        let lower = originalName.lowercased()
        for suffix in [".gz", ".bz2", ".xz"] where lower.hasSuffix(suffix) {
            return String(originalName.dropLast(suffix.count))
        }
        return originalName + ".out"
    }

    private static func remoteKind(_ type: ContainerEntryType) -> RemoteItemKind {
        switch type {
        case .regular: return .file
        case .directory: return .directory
        case .symbolicLink, .hardLink: return .symbolicLink
        default: return .unknown
        }
    }

    private static func remoteKind(_ type: ArchiveEntry.FileType) -> RemoteItemKind {
        switch type {
        case .regular: return .file
        case .directory: return .directory
        case .symbolicLink, .hardLink: return .symbolicLink
        default: return .unknown
        }
    }

    private static func extractLibArchive(
        at archiveURL: URL,
        entries: [ArchiveEntryInfo],
        to destination: URL,
        selectedPath: String? = nil,
        reporter: ByteProgressReporter? = nil
    ) throws {
        var plannedEntriesByPath: [String: ArchiveEntryInfo] = [:]
        for entry in entries {
            guard plannedEntriesByPath.updateValue(entry, forKey: entry.path) == nil else {
                throw RemoteProviderError.invalidResponse("Archive contains duplicate entry paths.")
            }
        }
        var outputHandle: FileHandle?
        var stagingURL: URL?
        var outputTarget: URL?
        var outputBytes: UInt64 = 0
        var streamedTotalBytes: UInt64 = 0
        defer {
            try? outputHandle?.close()
            if let stagingURL {
                try? FileManager.default.removeItem(at: stagingURL)
            }
        }

        try withLibArchiveErrors { try ArchiveReader().readDataBlocks(
            in: archiveURL,
            selecting: { entry in
                if let selectedPath, entry.path != selectedPath { return .skip }
                let relativePath = try validatedRelativePath(entry.path)
                guard !relativePath.isEmpty else { return .skip }
                guard let plannedEntry = plannedEntriesByPath[entry.path],
                      entry.size >= 0,
                      UInt64(entry.size) == plannedEntry.uncompressedSize else {
                    throw RemoteProviderError.invalidResponse("Archive entry metadata changed during extraction.")
                }

                switch entry.fileType {
                case .directory:
                    try FileManager.default.createDirectory(
                        at: destination.appendingPathComponent(relativePath),
                        withIntermediateDirectories: true
                    )
                    return .skip
                case .symbolicLink, .hardLink:
                    // Never materialize links from an untrusted archive. A link
                    // target can escape the extraction root even when the entry
                    // name itself is safe.
                    return .skip
                case .regular:
                    let target = destination.appendingPathComponent(relativePath)
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let staging = target.deletingLastPathComponent()
                        .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).partial")
                    guard FileManager.default.createFile(atPath: staging.path, contents: nil) else {
                        throw RemoteProviderError.invalidResponse("Unable to create archive entry staging file.")
                    }
                    outputHandle = try FileHandle(forWritingTo: staging)
                    stagingURL = staging
                    outputTarget = target
                    outputBytes = 0
                    guard plannedEntry.kind == .file else {
                        throw RemoteProviderError.invalidResponse("Archive entry type changed during extraction.")
                    }
                    let (updatedTotal, overflow) = streamedTotalBytes.addingReportingOverflow(plannedEntry.uncompressedSize)
                    guard !overflow, updatedTotal <= maxTotalUncompressedBytes else {
                        throw RemoteProviderError.invalidResponse("Archive extraction exceeded its total size limit.")
                    }
                    streamedTotalBytes = updatedTotal
                    return .read
                default:
                    return .skip
                }
            },
            didFinishEntry: { entry, _ in
                guard entry.fileType == .regular else { return }
                guard let handle = outputHandle,
                      let staging = stagingURL,
                      let target = outputTarget else {
                    throw RemoteProviderError.invalidResponse("Archive entry output was not opened.")
                }
                guard entry.size >= 0,
                      UInt64(entry.size) <= maxSingleFileBytes,
                      outputBytes <= UInt64(entry.size) else {
                    throw RemoteProviderError.invalidResponse("Archive entry exceeded its declared size.")
                }
                try handle.truncate(atOffset: UInt64(entry.size))
                try handle.close()
                outputHandle = nil
                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
                } else {
                    try FileManager.default.moveItem(at: staging, to: target)
                }
                stagingURL = nil
                outputTarget = nil
                outputBytes = 0
            }
        ) { entry, block in
            guard entry.fileType == .regular,
                  let outputHandle else {
                return .finishEntry
            }
            guard block.offset >= 0 else {
                throw RemoteProviderError.invalidResponse("Archive entry data has an invalid offset.")
            }
            let (endOffset, overflow) = block.offset.addingReportingOverflow(Int64(block.data.count))
            guard !overflow, endOffset >= 0,
                  entry.size >= 0,
                  endOffset <= entry.size,
                  UInt64(endOffset) <= maxSingleFileBytes else {
                throw RemoteProviderError.invalidResponse("Archive entry exceeded its declared size.")
            }
            try outputHandle.seek(toFileOffset: UInt64(block.offset))
            try outputHandle.write(contentsOf: block.data)
            outputBytes = max(outputBytes, UInt64(endOffset))
            reporter?.advance(by: UInt64(block.data.count))
            return .continueReading
        } }
    }

    private static func extractLibArchiveEntry(_ entryPath: String, from archiveURL: URL, to destination: URL) throws {
        let entries = try libArchiveEntries(at: archiveURL).filter {
            $0.path == entryPath && $0.kind == .file
        }
        guard entries.count == 1 else {
            throw RemoteProviderError.invalidResponse("Archive entry does not exist.")
        }
        try preflight(entries: entries, destination: destination)
        try extractLibArchive(at: archiveURL, entries: entries, to: destination, selectedPath: entryPath)
    }

    /// Streams one ZIP file entry to `target`, reporting every decompressed chunk.
    private static func extractZipFile(
        _ entry: ZIPFoundation.Entry,
        from archive: ZIPFoundation.Archive,
        to target: URL,
        reporter: ByteProgressReporter?
    ) throws {
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw RemoteProviderError.invalidResponse("Unable to create \(target.lastPathComponent).")
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        _ = try archive.extract(entry) { chunk in
            try handle.write(contentsOf: chunk)
            reporter?.advance(by: UInt64(chunk.count))
        }
    }

    private static func progressReporter(
        for entries: [ArchiveEntryInfo],
        _ progress: ((Double) -> Void)?
    ) -> ByteProgressReporter? {
        guard let progress else { return nil }
        // preflight has already bounded the total, so this cannot overflow.
        let totalBytes = entries.lazy.filter { $0.kind == .file }.reduce(0) { $0 + $1.uncompressedSize }
        return ByteProgressReporter(totalBytes: totalBytes, report: progress)
    }

    private static func extract(
        entries: [(String, RemoteItemKind, Data?)],
        to destination: URL,
        reporter: ByteProgressReporter? = nil
    ) throws {
        for (path, kind, data) in entries {
            let relativePath = try validatedRelativePath(path)
            guard !relativePath.isEmpty else { continue }
            let target = destination.appendingPathComponent(relativePath)
            switch kind {
            case .directory:
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            case .symbolicLink:
                // Do not materialize links from untrusted archives; links can escape the extraction root.
                continue
            case .file:
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let data else { continue }
                try data.write(to: target, options: .atomic)
                reporter?.advance(by: UInt64(data.count))
            case .unknown:
                continue
            }
        }
    }

    /// Converts an archive member name to a safe relative path. This deliberately validates the
    /// archive name itself instead of comparing absolute temporary-directory paths, which can differ
    /// on iOS because of path canonicalisation and container aliases.
    private static func validatedRelativePath(_ path: String) throws -> String {
        guard !path.contains("\0") else {
            throw RemoteProviderError.invalidResponse("Blocked an unsafe archive path: \(path)")
        }

        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/") else {
            throw RemoteProviderError.invalidResponse("Blocked an unsafe archive path: \(path)")
        }

        let rawComponents = normalized.split(separator: "/", omittingEmptySubsequences: false)
        var components: [Substring] = []
        for component in rawComponents {
            if component.isEmpty || component == "." { continue }
            guard component != ".." else {
                throw RemoteProviderError.invalidResponse("Blocked an unsafe archive path: \(path)")
            }
            if components.isEmpty,
               component.count == 2,
               component.last == ":",
               component.first?.isLetter == true {
                throw RemoteProviderError.invalidResponse("Blocked an unsafe archive path: \(path)")
            }
            components.append(component)
        }
        return components.joined(separator: "/")
    }
}

/// Turns completed byte counts into a fraction for a progress bar. It reports only when the
/// fraction moves by at least a percent (and once at completion), so every report can
/// afford a hop to the main actor.
final class ByteProgressReporter {
    private let totalBytes: UInt64
    private let report: (Double) -> Void
    private var completedBytes: UInt64 = 0
    private var lastReported: Double?

    init(totalBytes: UInt64, report: @escaping (Double) -> Void) {
        self.totalBytes = totalBytes
        self.report = report
    }

    func advance(by bytes: UInt64) {
        let (sum, overflow) = completedBytes.addingReportingOverflow(bytes)
        update(completedBytes: overflow ? totalBytes : sum)
    }

    func update(completedBytes bytes: UInt64) {
        completedBytes = min(bytes, totalBytes)
        send(totalBytes == 0 ? 0 : Double(completedBytes) / Double(totalBytes))
    }

    func finish() {
        send(1)
    }

    private func send(_ fraction: Double) {
        if let lastReported {
            if lastReported >= 1 { return }
            if fraction < 1, fraction - lastReported < 0.01 { return }
        }
        lastReported = fraction
        report(fraction)
    }
}
