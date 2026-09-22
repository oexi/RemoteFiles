import FileProvider
import Foundation

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let profile: ConnectionProfile
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let codec: FileProviderPathCodec
    private let identityStore: FileProviderIdentityStore
    private var task: Task<Void, Never>?

    init(profile: ConnectionProfile, containerIdentifier: NSFileProviderItemIdentifier) {
        self.profile = profile
        self.containerIdentifier = containerIdentifier
        codec = FileProviderPathCodec(rootPath: profile.initialPath)
        identityStore = FileProviderIdentityStore(profileID: profile.id)
    }

    func invalidate() {
        task?.cancel()
        task = nil
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        task?.cancel()
        task = Task {
            do {
                let credential = try CredentialVault.shared.load(for: profile.id)
                let provider = try ProviderFactory.make(for: profile, credential: credential)
                try await provider.connect()
                defer { Task { await provider.disconnect() } }
                let path = try identityStore.path(for: containerIdentifier, codec: codec)
                let listedItems = try await provider.list(path: path)
                let remoteItems = listedItems.filter { codec.containsDirectChild($0.path, of: path) }
                try identityStore.register(
                    paths: remoteItems.map(\.path),
                    codec: codec
                )
                let items = try remoteItems.map {
                    try FileProviderItem(
                        remote: $0,
                        codec: codec,
                        identityStore: identityStore,
                        providerCapabilities: provider.capabilities
                    )
                }
                // A misbehaving server can list the same path twice; keep the
                // first entry instead of trapping the extension.
                let identifiers = Dictionary(
                    zip(remoteItems, items).map {
                        ($0.0.path, $0.1.itemIdentifier.rawValue)
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                _ = try await FileProviderSnapshotStore.shared.save(
                    profileID: profile.id,
                    containerIdentifier: containerIdentifier,
                    items: remoteItems,
                    identifiers: identifiers
                )
                guard !Task.isCancelled else { return }
                let pageSize = max(1, observer.suggestedPageSize ?? 200)
                var index = 0
                while index < items.count {
                    guard !Task.isCancelled else { return }
                    let end = min(items.count, index + pageSize)
                    observer.didEnumerate(Array(items[index..<end]))
                    index = end
                }
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(FileProviderErrorMapping.map(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            let snapshot = await FileProviderSnapshotStore.shared.load(
                profileID: profile.id,
                containerIdentifier: containerIdentifier
            )
            completionHandler(snapshot?.anchor)
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        task?.cancel()
        task = Task {
            do {
                guard let previous = await FileProviderSnapshotStore.shared.load(
                    profileID: profile.id,
                    containerIdentifier: containerIdentifier,
                    anchor: syncAnchor
                ) else {
                    throw NSFileProviderError(.syncAnchorExpired)
                }
                let credential = try CredentialVault.shared.load(for: profile.id)
                let provider = try ProviderFactory.make(for: profile, credential: credential)
                try await provider.connect()
                defer { Task { await provider.disconnect() } }

                let path = try identityStore.path(for: containerIdentifier, codec: codec)
                let listedItems = try await provider.list(path: path)
                let remoteItems = listedItems.filter { codec.containsDirectChild($0.path, of: path) }
                try identityStore.register(
                    paths: remoteItems.map(\.path),
                    codec: codec
                )
                let currentFingerprints = FileProviderSnapshotStore.fingerprints(for: remoteItems)
                let currentItems = try remoteItems.map {
                    try FileProviderItem(
                        remote: $0,
                        codec: codec,
                        identityStore: identityStore,
                        providerCapabilities: provider.capabilities
                    )
                }
                let currentIdentifiersByPath = Dictionary(
                    zip(remoteItems, currentItems).map {
                        ($0.0.path, $0.1.itemIdentifier.rawValue)
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                let currentIdentifiers = Set(currentIdentifiersByPath.values)

                let changedRemote = remoteItems.filter { item in
                    let previousIdentifier = previous.identifiers[item.path]
                        ?? codec.identifier(for: item.path).rawValue
                    return previous.fingerprints[item.path] != currentFingerprints[item.path]
                        || previousIdentifier != currentIdentifiersByPath[item.path]
                }
                if !changedRemote.isEmpty {
                    let changedItems = try changedRemote.map {
                        try FileProviderItem(
                            remote: $0,
                            codec: codec,
                            identityStore: identityStore,
                            providerCapabilities: provider.capabilities
                        )
                    }
                    let batchSize = max(1, observer.suggestedBatchSize ?? 200)
                    var index = 0
                    while index < changedItems.count {
                        guard !Task.isCancelled else { return }
                        let end = min(changedItems.count, index + batchSize)
                        observer.didUpdate(Array(changedItems[index..<end]))
                        index = end
                    }
                }

                // Keep old out-of-root keys here so a snapshot created before the
                // boundary fix can still remove stale items from the Files UI.
                let deleted = fileProviderDeletedItemIdentifiers(
                    previousFingerprints: previous.fingerprints,
                    previousIdentifiers: previous.identifiers,
                    currentIdentifiers: currentIdentifiers,
                    codec: codec
                )
                if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }

                let snapshot = try await FileProviderSnapshotStore.shared.save(
                    profileID: profile.id,
                    containerIdentifier: containerIdentifier,
                    items: remoteItems,
                    identifiers: currentIdentifiersByPath
                )
                guard !Task.isCancelled else { return }
                observer.finishEnumeratingChanges(upTo: snapshot.anchor, moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(FileProviderErrorMapping.map(error))
            }
        }
    }
}

/// Enumerates containers this provider does not materialize: the working set
/// (RemoteFiles does not track recently-used or tagged items across folders)
/// and the trash (deletes are permanent on every supported protocol). The
/// system still asks for these regularly, so answer with a stable empty set
/// instead of an "unknown identifier" error.
final class FileProviderEmptyEnumerator: NSObject, NSFileProviderEnumerator {
    private static let anchor = NSFileProviderSyncAnchor(rawValue: Data("empty".utf8))

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: Self.anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchor)
    }
}
