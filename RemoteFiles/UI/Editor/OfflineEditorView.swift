import SwiftUI

struct OfflineEditorView: View {
    @EnvironmentObject private var offline: OfflineStore

    let item: OfflineItem

    var body: some View {
        LocalTextEditorView(
            url: offline.localURL(for: item),
            fileName: item.fileName,
            onSaved: { offline.fileDidChange(item) }
        )
    }
}

struct LocalTextEditorView: View {
    let url: URL
    let fileName: String
    let onSaved: (() -> Void)?

    @State private var text = ""
    @State private var loading = true
    @State private var saving = false
    @State private var loadError: String?
    @State private var saveError: String?

    var body: some View {
        Group {
            if loading {
                ProgressView("Loading \(fileName)…")
            } else if loadError == nil {
                RunestoneEditor(text: $text, fileName: fileName)
            } else {
                ContentUnavailableView(
                    "Text preview unavailable",
                    systemImage: "doc.questionmark",
                    description: Text(loadError ?? "")
                )
            }
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { Task { await save() } }
                    .disabled(loading || saving || loadError != nil)
            }
        }
        .task { await load() }
        .alert("Error", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "Unknown error")
        }
    }

    private func load() async {
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 20 * 1024 * 1024 else {
                throw RemoteProviderError.unsupported("Text files larger than 20 MB are not opened in the editor.")
            }
            guard let decoded = TextFileDetector.decode(data) else {
                throw RemoteProviderError.unsupported("This appears to be a binary file, so it is not opened as text.")
            }
            text = decoded
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            onSaved?()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
