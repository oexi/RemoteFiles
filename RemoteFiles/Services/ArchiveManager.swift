import Foundation
import ZIPFoundation

struct ArchiveEntryInfo: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let kind: RemoteItemKind
    let uncompressedSize: UInt64
    let compressedSize: UInt64
}

enum ArchiveManager {
    static let supportedExtensions: Set<String> = ["zip"]

    static func canOpen(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func list(_ archiveURL: URL) throws -> [ArchiveEntryInfo] {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        return archive.map { entry in
            ArchiveEntryInfo(
                path: entry.path,
                kind: entry.type == .directory ? .directory : (entry.type == .symlink ? .symbolicLink : .file),
                uncompressedSize: entry.uncompressedSize,
                compressedSize: entry.compressedSize
            )
        }
    }

    static func extract(_ archiveURL: URL, to destination: URL) throws {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        try validatePaths(in: archive, destination: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: archiveURL, to: destination)
    }

    static func extract(entryPath: String, from archiveURL: URL, to destination: URL) throws {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        guard let entry = archive[entryPath] else {
            throw RemoteProviderError.invalidResponse("Archive entry does not exist.")
        }
        try validate(entry: entry, destination: destination.deletingLastPathComponent())
        try archive.extract(entry, to: destination)
    }

    static func createZIP(from source: URL, at destination: URL) throws {
        try FileManager.default.zipItem(at: source, to: destination, shouldKeepParent: source.hasDirectoryPath)
    }

    private static func validatePaths(in archive: Archive, destination: URL) throws {
        for entry in archive { try validate(entry: entry, destination: destination) }
    }

    private static func validate(entry: Entry, destination: URL) throws {
        let root = destination.standardizedFileURL.path
        let target = destination.appendingPathComponent(entry.path).standardizedFileURL.path
        guard target == root || target.hasPrefix(root + "/") else {
            throw RemoteProviderError.invalidResponse("Blocked an unsafe archive path: \(entry.path)")
        }
    }
}

