import SwiftUI

struct ArchiveDetailView: View {
    let provider: any RemoteFileProvider
    let item: RemoteItem

    @State private var entries: [ArchiveEntryInfo] = []
    @State private var loading = true
    @State private var extracting = false
    @State private var message: String?

    var body: some View {
        Group {
            if loading {
                ProgressView("Reading archive…")
            } else {
                List(entries) { entry in
                    HStack {
                        Image(systemName: entry.kind == .directory ? "folder" : "doc")
                        VStack(alignment: .leading) {
                            Text(entry.path)
                            if entry.kind == .file {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.uncompressedSize), countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(extractionActionTitle) {
                    Task { await extract() }
                }
                .disabled(extracting || loading)
            }
        }
        .task { await load() }
        .alert("Archive", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    private var extractionActionTitle: LocalizedStringKey {
        extracting ? "Extracting…" : "Extract Here"
    }

    private func load() async {
        do {
            let localURL = try await CacheManager.shared.materialize(provider: provider, item: item)
            entries = try ArchiveManager.list(localURL, originalName: item.name)
        } catch {
            message = error.localizedDescription
        }
        loading = false
    }

    private func extract() async {
        extracting = true
        defer { extracting = false }
        do {
            try await RemoteArchiveService.extractHere(item: item, provider: provider)
            message = "Archive extracted successfully."
        } catch {
            message = error.localizedDescription
        }
    }
}
