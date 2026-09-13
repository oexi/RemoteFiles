import FileProvider
import Foundation

actor FileProviderSnapshotStore {
    struct Snapshot: Codable {
        let anchorData: Data
        let fingerprints: [String: String]

        var anchor: NSFileProviderSyncAnchor { NSFileProviderSyncAnchor(anchorData) }
    }

    private struct State: Codable {
        var snapshots: [Snapshot]
    }

    static let shared = FileProviderSnapshotStore()

    private let root: URL
    private let historyLimit = 16

    private init() {
        let fileManager = FileManager.default
        let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: FileProviderProfileStore.appGroupIdentifier)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = base.appendingPathComponent("FileProviderSnapshots", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func load(profileID: UUID, containerIdentifier: NSFileProviderItemIdentifier) -> Snapshot? {
        loadState(profileID: profileID, containerIdentifier: containerIdentifier)?.snapshots.last
    }

    func load(
        profileID: UUID,
        containerIdentifier: NSFileProviderItemIdentifier,
        anchor: NSFileProviderSyncAnchor
    ) -> Snapshot? {
        loadState(profileID: profileID, containerIdentifier: containerIdentifier)?
            .snapshots
            .last(where: { $0.anchorData == anchor.rawValue })
    }

    @discardableResult
    func save(
        profileID: UUID,
        containerIdentifier: NSFileProviderItemIdentifier,
        items: [RemoteItem]
    ) throws -> Snapshot {
        let snapshot = Snapshot(
            anchorData: Data(UUID().uuidString.utf8),
            fingerprints: Self.fingerprints(for: items)
        )
        var state = loadState(profileID: profileID, containerIdentifier: containerIdentifier)
            ?? State(snapshots: [])
        state.snapshots.append(snapshot)
        if state.snapshots.count > historyLimit {
            state.snapshots.removeFirst(state.snapshots.count - historyLimit)
        }
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL(profileID: profileID, containerIdentifier: containerIdentifier), options: .atomic)
        return snapshot
    }

    static func fingerprints(for items: [RemoteItem]) -> [String: String] {
        Dictionary(items.map { ($0.path, fingerprint($0)) }, uniquingKeysWith: { _, newest in newest })
    }

    private func loadState(profileID: UUID, containerIdentifier: NSFileProviderItemIdentifier) -> State? {
        let url = fileURL(profileID: profileID, containerIdentifier: containerIdentifier)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let state = try? JSONDecoder().decode(State.self, from: data) {
            return state
        }
        if let legacy = try? JSONDecoder().decode(Snapshot.self, from: data) {
            return State(snapshots: [legacy])
        }
        return nil
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
