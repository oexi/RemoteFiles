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
        case .sevenZip, .rar, .tar, .tarGzip:
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

    static func extract(_ archiveURL: URL, originalName: String, to destination: URL) throws {
        guard let format = format(for: originalName) else {
            throw RemoteProviderError.unsupported("Unsupported archive format.")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        switch format {
        case .zip:
            let entries = try zipEntries(at: archiveURL)
            try preflight(entries: entries, destination: destination)
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
                    _ = try archive.extract(entry, to: target)
                }
            }
        case .sevenZip, .rar, .tar, .tarGzip:
            let entries = try libArchiveEntries(at: archiveURL)
            try preflight(entries: entries, destination: destination)
            try extractLibArchive(at: archiveURL, entries: entries, to: destination)
        case .tarBzip2, .tarXz:
            let tarData = try decodedTarData(at: archiveURL, format: format)
            let entries = try legacyTarEntries(from: tarData)
            try preflight(entries: entries, destination: destination)
            let tarEntries = try TarContainer.open(container: tarData)
            try extract(entries: tarEntries.map { ($0.info.name, remoteKind($0.info.type), $0.data) }, to: destination)
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
        var destinationIsDirectory = false
        guard !FileManager.default.fileExists(
            atPath: destination.path,
            isDirectory: &destinationIsDirectory
        ) || !destinationIsDirectory else {
            throw RemoteProviderError.conflict("The archive destination is a directory.")
        }
        try preflight(entries: [info], destination: parent)
        _ = try archive.extract(entry, to: destination)
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
        try ArchiveReader().readDataBlocks(
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
        }
        try preflight(entries: result)
        return result
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
        to destination: URL
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

        try ArchiveReader().readDataBlocks(
            in: archiveURL,
            selecting: { entry in
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
                guard let handle = outputHandle, let stagingURL, let outputTarget else {
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
                if FileManager.default.fileExists(atPath: outputTarget.path) {
                    _ = try FileManager.default.replaceItemAt(outputTarget, withItemAt: stagingURL)
                } else {
                    try FileManager.default.moveItem(at: stagingURL, to: outputTarget)
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
            return .continueReading
        }
    }

    private static func extract(entries: [(String, RemoteItemKind, Data?)], to destination: URL) throws {
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
