import FileProvider
import Foundation

actor FileProviderSnapshotStore {
    struct Snapshot: Codable {
        let anchorData: Data
        let fingerprints: [String: String]

        var anchor: NSFileProviderSyncAnchor { NSFileProviderSyncAnchor(anchorData) }
    }

    static let shared = FileProviderSnapshotStore()

    private let root: URL

    private init() {
        let fileManager = FileManager.default
        let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: FileProviderProfileStore.appGroupIdentifier)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = base.appendingPathComponent("FileProviderSnapshots", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func load(profileID: UUID, containerIdentifier: NSFileProviderItemIdentifier) -> Snapshot? {
        let url = fileURL(profileID: profileID, containerIdentifier: containerIdentifier)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    @discardableResult
    func save(
        profileID: UUID,
        containerIdentifier: NSFileProviderItemIdentifier,
        items: [RemoteItem]
    ) throws -> Snapshot {
        let snapshot = Snapshot(
            anchorData: Data(UUID().uuidString.utf8),
            fingerprints: Dictionary(uniqueKeysWithValues: items.map { ($0.path, Self.fingerprint($0)) })
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL(profileID: profileID, containerIdentifier: containerIdentifier), options: .atomic)
        return snapshot
    }

    private func fileURL(profileID: UUID, containerIdentifier: NSFileProviderItemIdentifier) -> URL {
        let raw = "\(profileID.uuidString)|\(containerIdentifier.rawValue)"
        let safe = Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return root.appendingPathComponent(safe).appendingPathExtension("json")
    }

    private static func fingerprint(_ item: RemoteItem) -> String {
        [
            item.name,
            item.kind.rawValue,
            item.size.map(String.init) ?? "",
            item.modifiedAt.map { String($0.timeIntervalSince1970) } ?? "",
            item.createdAt.map { String($0.timeIntervalSince1970) } ?? "",
            item.revision.eTag ?? "",
            item.revision.opaqueIdentifier ?? ""
        ].joined(separator: "|")
    }
}
