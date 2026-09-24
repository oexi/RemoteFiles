import SwiftUI

struct ArchiveDetailView: View {
    let provider: any RemoteFileProvider
    let item: RemoteItem

    @State private var nodes: [ArchiveTreeNode] = []
    @State private var archiveURL: URL?
    @State private var loading = true
    @State private var extracting = false
    @State private var showingExtractChoice = false
    @State private var message: String?

    var body: some View {
        Group {
            if loading {
                ProgressView("Reading archive…")
            } else if let archiveURL {
                ArchiveTreeView(nodes: nodes, archiveURL: archiveURL, archiveName: item.name)
            } else {
                ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(extractionActionTitle) {
                    // Several top-level items would scatter into the current folder, so ask first.
                    if nodes.count > 1 {
                        showingExtractChoice = true
                    } else {
                        Task { await extract(intoFolder: false) }
                    }
                }
                .disabled(extracting || loading || archiveURL == nil)
            }
        }
        .confirmationDialog(
            "Extract Archive",
            isPresented: $showingExtractChoice,
            titleVisibility: .visible
        ) {
            Button("Extract to “\(ArchiveManager.suggestedFolderName(for: item.name))”") {
                Task { await extract(intoFolder: true) }
            }
            Button("Extract into Current Folder") {
                Task { await extract(intoFolder: false) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This archive has several items at its top level. Extract them into a new folder?")
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
            let name = item.name
            nodes = try await Task.detached(priority: .userInitiated) {
                try ArchiveTree.build(from: ArchiveManager.list(localURL, originalName: name))
            }.value
            archiveURL = localURL
        } catch {
            message = error.localizedDescription
        }
        loading = false
    }

    private func extract(intoFolder: Bool) async {
        extracting = true
        defer { extracting = false }
        do {
            let destination = try await RemoteArchiveService.extractHere(
                item: item,
                provider: provider,
                intoFolder: intoFolder
            )
            if intoFolder {
                message = String(
                    localized: "Extracted to “\((destination as NSString).lastPathComponent)”."
                )
            } else {
                message = String(localized: "Archive extracted successfully.")
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
