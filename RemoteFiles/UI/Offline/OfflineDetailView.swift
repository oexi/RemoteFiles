import SwiftUI

struct OfflineDetailView: View {
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var connections: ConnectionStore

    let item: OfflineItem

    @State private var showingExporter = false
    @State private var showingShare = false
    @State private var showingDestinations = false
    @State private var working = false
    @State private var message: String?
    @State private var externalURL: URL?

    private var url: URL { offline.localURL(for: item) }

    var body: some View {
        Group {
            if ArchiveManager.canOpen(fileName: item.fileName) {
                OfflineArchiveContentView(item: item, message: $message, working: $working)
            } else if EditorLanguage.isEditable(fileName: item.fileName) {
                OfflineEditorView(item: item)
            } else {
                QuickLookView(url: url)
            }
        }
        .navigationTitle(item.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                if let externalURL {
                    Button {
                        showingShare = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Export", systemImage: "folder.badge.plus") {
                    showingExporter = true
                }
                .disabled(externalURL == nil)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Copy to Server", systemImage: "arrow.right.doc.on.clipboard") {
                    showingDestinations = true
                }
                .disabled(working)
            }
        }
        .sheet(isPresented: $showingExporter) {
            if let externalURL {
                SystemDocumentExporter(urls: [externalURL]) { showingExporter = false }
                    .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showingShare) {
            if let externalURL {
                SystemShareSheet(urls: [externalURL]) {
                    showingShare = false
                }
                .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showingDestinations) {
            CopyDestinationView(profiles: connections.profiles, fileName: item.fileName) { profile in
                Task { await copy(to: profile) }
            }
        }
        .alert("Offline File", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .task {
            do {
                externalURL = try await offline.externalURL(for: item)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func copy(to profile: ConnectionProfile) async {
        working = true
        defer { working = false }
        do {
            try await offline.copyToServer(item, destination: profile)
            message = "Copied to \(profile.name)."
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct OfflineArchiveContentView: View {
    @EnvironmentObject private var offline: OfflineStore
    let item: OfflineItem
    @Binding var message: String?
    @Binding var working: Bool

    @State private var entries: [ArchiveEntryInfo] = []
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView("Reading archive…")
            } else {
                List(entries) { entry in
                    HStack {
                        Image(systemName: entry.kind == .directory ? "folder" : "doc")
                        VStack(alignment: .leading, spacing: 3) {
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(working ? "Extracting…" : "Extract to Offline", systemImage: "archivebox") {
                    Task { await extract() }
                }
                .disabled(loading || working)
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let url = offline.localURL(for: item)
            let name = item.fileName
            entries = try await Task.detached(priority: .userInitiated) {
                try ArchiveManager.list(url, originalName: name)
            }.value
        } catch {
            message = error.localizedDescription
        }
        loading = false
    }

    private func extract() async {
        working = true
        defer { working = false }
        do {
            let count = try await offline.extractArchive(item)
            message = "Extracted \(count) file(s) to Offline."
        } catch {
            message = error.localizedDescription
        }
    }
}
