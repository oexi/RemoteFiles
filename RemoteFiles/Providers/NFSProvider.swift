import Foundation
import NFSKit

final class NFSProvider: RemoteFileProvider, RemoteChunkReadableProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write, .createDirectory, .delete, .move, .randomRead, .randomWrite, .resume, .permissions, .symbolicLinks])
    let client: NFSClient
    var connected = false

    init(profile: ConnectionProfile) throws {
        self.profile = profile
        guard let url = URL(string: "nfs://\(profile.host):\(profile.port)"),
              let client = try NFSClient(url: url) else {
            throw RemoteProviderError.invalidConfiguration("Invalid NFS host or port.")
        }
        self.client = client
    }

    func connect() async throws {
        guard !profile.nfsExport.isEmpty else {
            throw RemoteProviderError.invalidConfiguration("NFS requires an export path.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.connect(export: profile.nfsExport) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        connected = true
    }

    func disconnect() async {
        guard connected else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            client.disconnect(export: profile.nfsExport, gracefully: true) { _ in continuation.resume() }
        }
        connected = false
    }

    func list(path: String) async throws -> [RemoteItem] {
        try await ensureConnected()
        let rows = try await client.contentsOfDirectory(atPath: nfsPath(path)).get()
        return rows.compactMap { row in
            guard let name = row[.nameKey] as? String, name != ".", name != ".." else { return nil }
            let isDirectory = (row[.isDirectoryKey] as? NSNumber)?.boolValue ?? false
            let isLink = (row[.isSymbolicLinkKey] as? NSNumber)?.boolValue ?? false
            let size = (row[.fileSizeKey] as? NSNumber)?.int64Value
            let modified = row[.contentModificationDateKey] as? Date
            return RemoteItem(
                name: name,
                path: RemotePath.join(path, name),
                kind: isDirectory ? .directory : (isLink ? .symbolicLink : .file),
                size: isDirectory ? nil : size,
                modifiedAt: modified,
                createdAt: row[.creationDateKey] as? Date,
                isHidden: name.hasPrefix("."),
                revision: .init(modifiedAt: modified, size: size, opaqueIdentifier: (row[.documentIdentifierKey] as? NSNumber)?.stringValue)
            )
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func readChunk(path: String, offset: UInt64, length: Int) async throws -> Data {
        try await ensureConnected()
        let lower = Int64(clamping: offset)
        let upper = lower.addingReportingOverflow(Int64(length))
        let end = upper.overflow ? Int64.max : upper.partialValue
        return try await client.contents(atPath: nfsPath(path), range: lower..<end, progress: nil).get()
    }

    func ensureConnected() async throws {
        if !connected { try await connect() }
    }

    func nfsPath(_ path: String) -> String { RemotePath.normalize(path) }
}

