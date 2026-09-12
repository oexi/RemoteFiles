import SwiftUI

struct RemoteEditorView: View {
    let provider: any RemoteFileProvider
    let item: RemoteItem

    @State private var text = ""
    @State private var localURL: URL?
    @State private var baseRevision: RemoteRevision?
    @State private var loading = true
    @State private var saving = false
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var showConflict = false

    var body: some View {
        Group {
            if loading {
                ProgressView("Loading \(item.name)…")
            } else if let loadError {
                ContentUnavailableView(
                    "Text preview unavailable",
                    systemImage: "doc.questionmark",
                    description: Text(loadError)
                )
            } else {
                RunestoneEditor(text: $text, fileName: item.name)
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { Task { await save(force: false) } }
                    .disabled(loading || saving || loadError != nil)
            }
        }
        .task { await load() }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .alert("Remote file changed", isPresented: $showConflict) {
            Button("Cancel", role: .cancel) { }
            Button("Overwrite", role: .destructive) { Task { await save(force: true) } }
        } message: {
            Text("The file changed on the server after it was opened. Overwriting may discard another edit.")
        }
    }

    private func load() async {
        do {
            let url = try await CacheManager.shared.materialize(provider: provider, item: item, forceRefresh: true)
            let data = try Data(contentsOf: url)
            guard data.count <= 20 * 1024 * 1024 else {
                throw RemoteProviderError.unsupported("Text files larger than 20 MB are not opened in the editor.")
            }
            guard let decoded = TextFileDetector.decode(data) else {
                throw RemoteProviderError.unsupported("This appears to be a binary file, so it is not opened as text.")
            }
            localURL = url
            text = decoded
            baseRevision = item.revision
            loading = false
        } catch {
            loadError = error.localizedDescription
            loading = false
        }
    }

    private func save(force: Bool) async {
        guard let localURL else { return }
        saving = true
        defer { saving = false }
        do {
            if !force, let baseRevision {
                let current = try await provider.attributes(path: item.path).revision
                if Self.hasChanged(baseRevision, current) {
                    showConflict = true
                    return
                }
            }
            try Data(text.utf8).write(to: localURL, options: .atomic)
            try await provider.upload(from: localURL, to: item.path, overwrite: true)
            if let refreshed = try? await provider.attributes(path: item.path) {
                baseRevision = refreshed.revision
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func hasChanged(_ old: RemoteRevision, _ new: RemoteRevision) -> Bool {
        if let a = old.eTag, let b = new.eTag { return a != b }
        if let a = old.modifiedAt, let b = new.modifiedAt, a != b { return true }
        if let a = old.size, let b = new.size, a != b { return true }
        return false
    }

}

