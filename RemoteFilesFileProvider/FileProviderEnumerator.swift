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
                guard !Task.isCancelled else { return }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }
}
