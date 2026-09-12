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

    static func canOpen(fileName: String) -> Bool {
        format(for: fileName) != nil
    }

    static func list(_ archiveURL: URL, originalName: String) throws -> [ArchiveEntryInfo] {
        guard let format = format(for: originalName) else {
            throw RemoteProviderError.unsupported("Unsupported archive format.")
        }
        switch format {
        case .zip:
            let archive = try Archive(url: archiveURL, accessMode: .read)
            return archive.map { entry in
                ArchiveEntryInfo(
                    path: entry.path,
                    kind: entry.type == .directory ? .directory : (entry.type == .symlink ? .symbolicLink : .file),
                    uncompressedSize: entry.uncompressedSize,
                    compressedSize: entry.compressedSize
                )
            }
        case .sevenZip:
            return try SevenZipContainer.info(container: Data(contentsOf: archiveURL)).map { info in
                ArchiveEntryInfo(
                    path: info.name,
                    kind: remoteKind(info.type),
                    uncompressedSize: UInt64(max(0, info.size ?? 0)),
                    compressedSize: 0
                )
            }
        case .rar:
            return try ArchiveReader().entries(at: archiveURL).map { entry in
                ArchiveEntryInfo(
                    path: entry.path,
                    kind: remoteKind(entry.fileType),
                    uncompressedSize: UInt64(max(0, entry.size)),
                    compressedSize: 0
                )
            }
        case .tar, .tarGzip, .tarBzip2, .tarXz:
            let tarData = try decodedTarData(at: archiveURL, format: format)
            return try TarContainer.info(container: tarData).map { info in
                ArchiveEntryInfo(
                    path: info.name,
                    kind: remoteKind(info.type),
                    uncompressedSize: UInt64(max(0, info.size ?? 0)),
                    compressedSize: 0
                )
            }
        case .gzip, .bzip2, .xz:
            let data = try decodeSingleFile(at: archiveURL, format: format)
            return [ArchiveEntryInfo(
                path: outputName(for: originalName),
                kind: .file,
                uncompressedSize: UInt64(data.count),
                compressedSize: UInt64((try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            )]
        }
    }

    static func extract(_ archiveURL: URL, originalName: String, to destination: URL) throws {
        guard let format = format(for: originalName) else {
            throw RemoteProviderError.unsupported("Unsupported archive format.")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        switch format {
        case .zip:
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
        case .sevenZip:
            let entries = try SevenZipContainer.open(container: Data(contentsOf: archiveURL))
            try extract(entries: entries.map { ($0.info.name, remoteKind($0.info.type), $0.data) }, to: destination)
        case .rar:
            try ArchiveReader().extract(archiveURL, to: destination, options: [.safeWrites])
        case .tar, .tarGzip, .tarBzip2, .tarXz:
            let entries = try TarContainer.open(container: decodedTarData(at: archiveURL, format: format))
            try extract(entries: entries.map { ($0.info.name, remoteKind($0.info.type), $0.data) }, to: destination)
        case .gzip, .bzip2, .xz:
            let relativePath = try validatedRelativePath(outputName(for: originalName))
            let output = destination.appendingPathComponent(relativePath)
            try decodeSingleFile(at: archiveURL, format: format).write(to: output, options: .atomic)
        }
    }

    static func extract(entryPath: String, from archiveURL: URL, to destination: URL) throws {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        guard let entry = archive[entryPath] else {
            throw RemoteProviderError.invalidResponse("Archive entry does not exist.")
        }
        _ = try validatedRelativePath(entry.path)
        _ = try archive.extract(entry, to: destination)
    }

    static func createZIP(from source: URL, at destination: URL) throws {
        try FileManager.default.zipItem(at: source, to: destination, shouldKeepParent: source.hasDirectoryPath)
    }

    private enum Format {
        case zip, sevenZip, rar, tar, tarGzip, tarBzip2, tarXz, gzip, bzip2, xz
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
        let data = try Data(contentsOf: url)
        switch format {
        case .tar: return data
        case .tarGzip: return try GzipArchive.unarchive(archive: data)
        case .tarBzip2: return try BZip2.decompress(data: data)
        case .tarXz: return try XZArchive.unarchive(archive: data)
        default: throw RemoteProviderError.invalidConfiguration("Not a TAR-based format.")
        }
    }

    private static func decodeSingleFile(at url: URL, format: Format) throws -> Data {
        let data = try Data(contentsOf: url)
        switch format {
        case .gzip: return try GzipArchive.unarchive(archive: data)
        case .bzip2: return try BZip2.decompress(data: data)
        case .xz: return try XZArchive.unarchive(archive: data)
        default: throw RemoteProviderError.invalidConfiguration("Not a single-file compressed format.")
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
        case .directory: return .directory
        case .symbolicLink, .hardLink: return .symbolicLink
        default: return .file
        }
    }

    private static func remoteKind(_ type: ArchiveEntry.FileType) -> RemoteItemKind {
        switch type {
        case .directory: return .directory
        case .symbolicLink, .hardLink: return .symbolicLink
        default: return .file
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
            case .file, .unknown:
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let data else { continue }
                try data.write(to: target, options: .atomic)
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

