import SwiftUI

struct ConnectionListView: View {
    @EnvironmentObject private var store: ConnectionStore
    @EnvironmentObject private var history: LocationHistoryStore
    @State private var editingProfile: ConnectionProfile?
    @State private var showingNewConnection = false
    @State private var pendingDeleteProfile: ConnectionProfile?

    var body: some View {
        NavigationStack {
            List {
                favoritesSection
                recentsSection
                if !store.profiles.isEmpty {
                    Section {
                        ForEach(store.profiles) { profile in
                            NavigationLink {
                                BrowserView(profile: profile)
                            } label: {
                                serverRow(profile)
                            }
                            .contextMenu {
                                Button("Edit", systemImage: "pencil") { editingProfile = profile }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    pendingDeleteProfile = profile
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingDeleteProfile = profile
                                } label: { Label("Delete", systemImage: "trash") }
                                Button { editingProfile = profile } label: { Label("Edit", systemImage: "pencil") }
                                    .tint(.blue)
                            }
                        }
                    } header: {
                        if hasBookmarks { Text("Servers") }
                    }
                }
            }
            .overlay {
                if store.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No Servers", systemImage: "externaldrive.badge.plus")
                    } description: {
                        Text("Add an FTP, SFTP, SMB, WebDAV or NFS server.")
                    } actions: {
                        Button("Add Server") { showingNewConnection = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("RemoteFiles")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingNewConnection = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add Server")
                }
            }
            .confirmationDialog(
                "Delete “\(pendingDeleteProfile?.name ?? "")”?",
                isPresented: Binding(
                    get: { pendingDeleteProfile != nil },
                    set: { if !$0 { pendingDeleteProfile = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeleteProfile
            ) { profile in
                Button("Delete Server", role: .destructive) {
                    history.removeAll(for: profile.id)
                    store.remove(profile)
                }
            } message: { _ in
                Text("The saved password, favorites and recent items for this server are removed. Files on the server are not affected.")
            }
            .sheet(isPresented: $showingNewConnection) {
                ConnectionEditorView(profile: .empty()) { profile, credential in
                    try CredentialVault.shared.save(credential, for: profile.id)
                    store.upsert(profile)
                }
            }
            .sheet(item: $editingProfile) { profile in
                ConnectionEditorView(profile: profile) { updated, credential in
                    try CredentialVault.shared.save(credential, for: updated.id)
                    store.upsert(updated)
                }
            }
        }
    }

    private func serverRow(_ profile: ConnectionProfile) -> some View {
        HStack(spacing: 12) {
            ProtocolBadge(protocolType: profile.protocolType, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .lineLimit(1)
                Text(verbatim: "\(profile.protocolType.title) · \(serverAddress(profile))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    private func serverAddress(_ profile: ConnectionProfile) -> String {
        let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return user.isEmpty || host.contains("://") ? host : "\(user)@\(host)"
    }

    private var hasBookmarks: Bool {
        !visible(history.favorites).isEmpty || !visible(history.recents).isEmpty
    }

    /// Pairs bookmarks with their connection, hiding those whose connection no longer exists.
    private func visible(_ bookmarks: [LocationBookmark]) -> [VisibleBookmark] {
        bookmarks.compactMap { bookmark in
            store.profiles.first { $0.id == bookmark.profileID }
                .map { VisibleBookmark(bookmark: bookmark, profile: $0) }
        }
    }

    @ViewBuilder
    private var favoritesSection: some View {
        let favorites = visible(history.favorites)
        if !favorites.isEmpty {
            Section("Favorites") {
                ForEach(favorites) { entry in
                    bookmarkLink(entry)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { history.remove(entry.bookmark) } label: {
                                Label("Remove", systemImage: "star.slash")
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        let recents = visible(history.recents)
        if !recents.isEmpty {
            Section {
                ForEach(recents.prefix(8)) { entry in
                    bookmarkLink(entry)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { history.remove(entry.bookmark) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Recent")
                    Spacer()
                    Button("Clear") { history.clearRecents() }
                        .font(.caption)
                        .textCase(nil)
                }
            }
        }
    }

    private func bookmarkLink(_ entry: VisibleBookmark) -> some View {
        let bookmark = entry.bookmark
        let profile = entry.profile
        return NavigationLink {
            if bookmark.isDirectory {
                BrowserView(profile: profile, startPath: bookmark.path)
            } else {
                BookmarkedFileView(profile: profile, bookmark: bookmark)
            }
        } label: {
            HStack(spacing: 10) {
                WhiteSurFileIconView(fileName: bookmark.name, isDirectory: bookmark.isDirectory, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bookmark.name)
                        .lineLimit(1)
                    Text(verbatim: "\(profile.name) · \(bookmark.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

private struct VisibleBookmark: Identifiable {
    let bookmark: LocationBookmark
    let profile: ConnectionProfile
    var id: UUID { bookmark.id }
}

/// Connects to a bookmarked file's server and opens the file directly.
private struct BookmarkedFileView: View {
    let profile: ConnectionProfile
    let bookmark: LocationBookmark

    @State private var provider: (any RemoteFileProvider)?
    @State private var item: RemoteItem?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let provider, let item {
                FileDetailView(provider: provider, item: item)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Unable to Open",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Connecting…")
            }
        }
        .navigationTitle(bookmark.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await open() }
    }

    private func open() async {
        guard item == nil else { return }
        do {
            let provider = try ProviderFactory.make(for: profile)
            try await provider.connect()
            let attributes = try await provider.attributes(path: bookmark.path)
            self.provider = provider
            item = RemoteItem(
                name: bookmark.name,
                path: bookmark.path,
                kind: attributes.kind == .directory ? .directory : .file,
                size: attributes.size,
                modifiedAt: attributes.modifiedAt,
                createdAt: attributes.createdAt,
                contentType: attributes.contentType,
                permissions: attributes.permissions,
                revision: attributes.revision
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = RemoteProviderError.isNotFound(error)
                ? String(localized: "This file no longer exists on the server.")
                : error.localizedDescription
        }
    }
}

