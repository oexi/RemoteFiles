import SwiftUI

struct ArchiveDetailView: View {
    let provider: any RemoteFileProvider
    let item: RemoteItem

    @State private var nodes: [ArchiveTreeNode] = []
    @State private var archiveURL: URL?
    @State private var loading = true
    @State private var extractionProgress: ArchiveExtractionProgress?
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
                // An icon with a fixed label: a text title that changed while extracting
                // resized the item and shifted the navigation title.
                Button("Extract Here", systemImage: "archivebox") {
                    // Several top-level items would scatter into the current folder, so ask first.
                    if nodes.count > 1 {
                        showingExtractChoice = true
                    } else {
                        Task { await extract(intoFolder: false) }
                    }
                }
                .disabled(extractionProgress != nil || loading || archiveURL == nil)
            }
        }
        .archiveExtractionChoice(isPresented: $showingExtractChoice, archiveName: item.name) { intoFolder in
            Task { await extract(intoFolder: intoFolder) }
        }
        .safeAreaInset(edge: .bottom) {
            if let extractionProgress {
                ArchiveExtractionProgressView(progress: extractionProgress)
            }
        }
        .task { await load() }
        .alert("Archive", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
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
        extractionProgress = ArchiveExtractionProgress(phase: .downloading, fraction: nil)
        defer { extractionProgress = nil }
        do {
            let destination = try await RemoteArchiveService.extractHere(
                item: item,
                provider: provider,
                intoFolder: intoFolder
            ) { progress in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // A report can arrive after the extraction has already finished.
                        if extractionProgress != nil { extractionProgress = progress }
                    }
                }
            }
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
