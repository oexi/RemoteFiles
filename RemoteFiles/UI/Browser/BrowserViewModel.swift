import Foundation
import Combine

@MainActor
final class BrowserViewModel: ObservableObject {
    let profile: ConnectionProfile
    @Published private(set) var items: [RemoteItem] = []
    @Published private(set) var currentPath: String
    @Published private(set) var loading = false
    @Published var errorMessage: String?

    private(set) var provider: (any RemoteFileProvider)?

    init(profile: ConnectionProfile) {
        self.profile = profile
        currentPath = RemotePath.normalize(profile.initialPath)
    }

    var capabilities: ProviderCapabilities { provider?.capabilities ?? .readOnly }
    var canGoUp: Bool { currentPath != "/" }

    func start() async {
        guard provider == nil else { return }
        loading = true
        defer { loading = false }
        do {
            let provider = try ProviderFactory.make(for: profile)
            try await provider.connect()
            self.provider = provider
            try await refreshImpl()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        do { try await refreshImpl() }
        catch { errorMessage = error.localizedDescription }
    }

    func enter(_ item: RemoteItem) async {
        guard item.isDirectory else { return }
        currentPath = item.path
        await refresh()
    }

    func goUp() async {
        guard canGoUp else { return }
        currentPath = RemotePath.parent(currentPath)
        await refresh()
    }

    func createFolder(name: String) async {
        guard let provider, !name.isEmpty else { return }
        do {
            try await provider.createDirectory(path: RemotePath.join(currentPath, name))
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ item: RemoteItem) async {
        guard let provider else { return }
        do {
            try await provider.remove(path: item.path, isDirectory: item.isDirectory)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func upload(localURLs: [URL]) async {
        guard let provider else { return }
        do {
            for url in localURLs {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try await provider.upload(from: url, to: RemotePath.join(currentPath, url.lastPathComponent), overwrite: false)
            }
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func stop() async {
        await provider?.disconnect()
    }

    private func refreshImpl() async throws {
        guard let provider else { throw RemoteProviderError.notConnected }
        items = try await provider.list(path: currentPath)
    }
}

