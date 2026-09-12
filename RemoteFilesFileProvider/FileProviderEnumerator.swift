import FileProvider
import Foundation

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let profile: ConnectionProfile
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let codec: FileProviderPathCodec
    private var task: Task<Void, Never>?

    init(profile: ConnectionProfile, containerIdentifier: NSFileProviderItemIdentifier) {
        self.profile = profile
        self.containerIdentifier = containerIdentifier
        codec = FileProviderPathCodec(rootPath: profile.initialPath)
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
                let path = try codec.path(for: containerIdentifier)
                let remoteItems = try await provider.list(path: path)
                let items = remoteItems.map { FileProviderItem(remote: $0, codec: codec, providerCapabilities: provider.capabilities) }
                _ = try await FileProviderSnapshotStore.shared.save(
                    profileID: profile.id,
                    containerIdentifier: containerIdentifier,
                    items: remoteItems
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
                observer.finishEnumeratingWithError(error)
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
                let previous = await FileProviderSnapshotStore.shared.load(
                    profileID: profile.id,
                    containerIdentifier: containerIdentifier
                )
                let credential = try CredentialVault.shared.load(for: profile.id)
                let provider = try ProviderFactory.make(for: profile, credential: credential)
                try await provider.connect()
                defer { Task { await provider.disconnect() } }

                let path = try codec.path(for: containerIdentifier)
                let remoteItems = try await provider.list(path: path)
                let currentFingerprints = Dictionary(uniqueKeysWithValues: remoteItems.map { item in
                    let fingerprint = [
                        item.name,
                        item.kind.rawValue,
                        item.size.map(String.init) ?? "",
                        item.modifiedAt.map { String($0.timeIntervalSince1970) } ?? "",
                        item.createdAt.map { String($0.timeIntervalSince1970) } ?? "",
                        item.revision.eTag ?? "",
                        item.revision.opaqueIdentifier ?? ""
                    ].joined(separator: "|")
                    return (item.path, fingerprint)
                })

                let changedRemote = remoteItems.filter { item in
                    previous?.fingerprints[item.path] != currentFingerprints[item.path]
                }
                if !changedRemote.isEmpty {
                    let changedItems = changedRemote.map {
                        FileProviderItem(remote: $0, codec: codec, providerCapabilities: provider.capabilities)
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

                if let previous {
                    let deleted = previous.fingerprints.keys
                        .filter { currentFingerprints[$0] == nil }
                        .map(codec.identifier(for:))
                    if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
                }

                let snapshot = try await FileProviderSnapshotStore.shared.save(
                    profileID: profile.id,
                    containerIdentifier: containerIdentifier,
                    items: remoteItems
                )
                guard !Task.isCancelled else { return }
                observer.finishEnumeratingChanges(upTo: snapshot.anchor, moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }
}
