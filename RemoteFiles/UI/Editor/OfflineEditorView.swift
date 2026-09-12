import SwiftUI

struct OfflineEditorView: View {
    @EnvironmentObject private var offline: OfflineStore

    let item: OfflineItem

    @State private var text = ""
    @State private var loading = true
    @State private var saving = false
    @State private var loadError: String?
    @State private var saveError: String?

    var body: some View {
        Group {
            if loading {
                ProgressView("Loading \(item.fileName)…")
            } else if loadError == nil {
                RunestoneEditor(text: $text, fileName: item.fileName)
            } else {
                ContentUnavailableView(
                    "Text preview unavailable",
                    systemImage: "doc.questionmark",
                    description: Text(loadError ?? "")
                )
            }
        }
        .navigationTitle(item.fileName)
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
            let url = offline.localURL(for: item)
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
            try Data(text.utf8).write(to: offline.localURL(for: item), options: .atomic)
            offline.fileDidChange(item)
        } catch {
            saveError = error.localizedDescription
        }
    }
}
