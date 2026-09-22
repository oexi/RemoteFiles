import SwiftUI

/// Browses folders on a connection so the user can choose where copied items
/// go, instead of always using the connection's initial path.
struct RemoteFolderPickerView: View {
    @StateObject private var model: RemoteFolderPickerModel
    let onChoose: (String) -> Void

    init(profile: ConnectionProfile, onChoose: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: RemoteFolderPickerModel(profile: profile))
        self.onChoose = onChoose
    }

    var body: some View {
        List {
            Section {
                Label(model.path, systemImage: "folder")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Section {
                if model.path != "/" {
                    Button {
                        Task { await model.open(RemotePath.parent(model.path)) }
                    } label: {
                        Label("Parent Folder", systemImage: "arrow.turn.left.up")
                    }
                }
                ForEach(model.folders) { folder in
                    Button {
                        Task { await model.open(folder.path) }
                    } label: {
                        Label(folder.name, systemImage: "folder.fill")
                    }
                }
            }
        }
        .overlay {
            if model.loading && model.folders.isEmpty {
                ProgressView()
            } else if let error = model.errorMessage {
                ContentUnavailableView("Folder Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            }
        }
        .navigationTitle(model.profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Copy Here") { onChoose(model.path) }
                    .disabled(model.loading || model.errorMessage != nil)
            }
        }
        .task { await model.open(model.path) }
    }
}

@MainActor
final class RemoteFolderPickerModel: ObservableObject {
    let profile: ConnectionProfile
    @Published private(set) var path: String
    @Published private(set) var folders: [RemoteItem] = []
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?

    private var provider: (any RemoteFileProvider)?
    private var generation = 0

    init(profile: ConnectionProfile) {
        self.profile = profile
        path = RemotePath.normalize(profile.initialPath)
    }

    func open(_ newPath: String) async {
        generation += 1
        let current = generation
        path = RemotePath.normalize(newPath)
        folders = []
        errorMessage = nil
        loading = true
        defer { if current == generation { loading = false } }
        do {
            let provider = try await connectedProvider()
            let items = try await provider.list(path: path)
            guard current == generation else { return }
            folders = items.filter(\.isDirectory)
        } catch {
            guard current == generation, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func connectedProvider() async throws -> any RemoteFileProvider {
        if let provider { return provider }
        let created = try ProviderFactory.make(for: profile)
        try await created.connect()
        provider = created
        return created
    }
}
