import SwiftUI

struct OfflineDetailView: View {
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var connections: ConnectionStore
    @EnvironmentObject private var transfers: TransferEngine

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
            if item.directory {
                OfflineFolderContentView(rootURL: url, offlineItem: item)
            } else if ArchiveManager.canOpen(fileName: item.fileName) {
                OfflineArchiveContentView(item: item, message: $message, working: $working)
            } else if EditorLanguage.isEditable(fileName: item.fileName) {
                OfflineEditorView(item: item)
            } else if MPVPlayer.isPreferred(forFileName: item.fileName) {
                MPVPlayerView(media: .local(url))
            } else {
                QuickLookView(url: url)
            }
        }
        .navigationTitle(item.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !item.directory {
                ToolbarItem(placement: .secondaryAction) {
                    if externalURL != nil {
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
            CopyDestinationView(profiles: connections.profiles, fileName: item.fileName) { profile, folder in
                Task { await copy(to: profile, folder: folder) }
            }
        }
        .alert("Offline File", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .task {
            guard !item.directory else { return }
            do {
                externalURL = try await offline.externalURL(for: item)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func copy(to profile: ConnectionProfile, folder: String) async {
        working = true
        defer { working = false }
        do {
            try await offline.copyToServer(item, destination: profile, folder: folder, transfers: transfers)
            message = "Copied to \(profile.name)."
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct OfflineFolderContentView: View {
    @EnvironmentObject private var offline: OfflineStore

    let rootURL: URL
    let offlineItem: OfflineItem
    @State private var entries: [OfflineFolderEntry] = []
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if loading {
                ProgressView("Reading folder…")
            } else {
                List(entries) { entry in
                    if entry.isDirectory {
                        NavigationLink {
                            OfflineFolderContentView(
                                rootURL: entry.url,
                                offlineItem: offlineItem
                            )
                            .navigationTitle(entry.name)
                            .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            OfflineFolderEntryRow(entry: entry)
                        }
                    } else {
                        NavigationLink {
                            OfflineLocalFileDetailView(
                                url: entry.url,
                                offlineItem: offlineItem
                            )
                        } label: {
                            OfflineFolderEntryRow(entry: entry)
                        }
                    }
                }
            }
        }
        .alert("Offline Folder", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let root = rootURL
            entries = try await Task.detached(priority: .userInitiated) {
                let urls = try FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: []
                )
                var result: [OfflineFolderEntry] = []
                for url in urls {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    result.append(OfflineFolderEntry(
                        url: url,
                        name: url.lastPathComponent,
                        isDirectory: values.isDirectory == true,
                        size: values.isDirectory == true ? nil : values.fileSize.map(Int64.init)
                    ))
                }
                return result.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }.value
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}

private struct OfflineFolderEntry: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
}

private struct OfflineFolderEntryRow: View {
    let entry: OfflineFolderEntry

    var body: some View {
        HStack(spacing: 10) {
            WhiteSurFileIconView(
                fileName: entry.url.lastPathComponent,
                isDirectory: entry.isDirectory,
                size: 34
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .lineLimit(2)
                if let size = entry.size {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct OfflineLocalFileDetailView: View {
    @EnvironmentObject private var offline: OfflineStore

    let url: URL
    let offlineItem: OfflineItem

    var body: some View {
        Group {
            if EditorLanguage.isEditable(fileName: url.lastPathComponent) {
                LocalTextEditorView(
                    url: url,
                    fileName: url.lastPathComponent,
                    onSaved: { offline.fileDidChange(offlineItem) }
                )
            } else if MPVPlayer.isPreferred(forFileName: url.lastPathComponent) {
                MPVPlayerView(media: .local(url))
                    .navigationTitle(url.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                QuickLookView(url: url)
                    .navigationTitle(url.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

private struct OfflineArchiveContentView: View {
    @EnvironmentObject private var offline: OfflineStore
    let item: OfflineItem
    @Binding var message: String?
    @Binding var working: Bool

    @State private var nodes: [ArchiveTreeNode] = []
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView("Reading archive…")
            } else {
                ArchiveTreeView(
                    nodes: nodes,
                    archiveURL: offline.localURL(for: item),
                    archiveName: item.fileName
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(extractionActionTitle, systemImage: "archivebox") {
                    Task { await extract() }
                }
                .disabled(loading || working)
            }
        }
        .task { await load() }
    }

    private var extractionActionTitle: LocalizedStringKey {
        working ? "Extracting…" : "Extract to Offline"
    }

    private func load() async {
        do {
            let url = offline.localURL(for: item)
            let name = item.fileName
            nodes = try await Task.detached(priority: .userInitiated) {
                try ArchiveTree.build(from: ArchiveManager.list(url, originalName: name))
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
