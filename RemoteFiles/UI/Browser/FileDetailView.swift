import SwiftUI

struct FileDetailView: View {
    @EnvironmentObject private var connections: ConnectionStore
    @EnvironmentObject private var transfers: TransferEngine
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var history: LocationHistoryStore

    let provider: any RemoteFileProvider
    let item: RemoteItem

    @State private var showingDestinations = false
    @State private var showingPermissions = false
    @State private var showingAccessControl = false
    @State private var copyError: String?
    @State private var offlineWorking = false

    var body: some View {
        Group {
            if EditorLanguage.isEditable(fileName: item.name) {
                RemoteEditorView(provider: provider, item: item)
            } else if ArchiveManager.canOpen(fileName: item.name) {
                ArchiveDetailView(provider: provider, item: item)
            } else {
                RemotePreviewView(provider: provider, item: item)
            }
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                let isFavorite = history.isFavorite(profileID: provider.profile.id, path: item.path)
                Button(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "star.slash" : "star"
                ) {
                    history.toggleFavorite(
                        profileID: provider.profile.id,
                        path: item.path,
                        name: item.name,
                        isDirectory: false
                    )
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(
                    offlineActionTitle,
                    systemImage: offline.isPinned(profileID: provider.profile.id, path: item.path) ? "checkmark.circle.fill" : "arrow.down.circle"
                ) {
                    Task { await toggleOffline() }
                }
                .disabled(offlineWorking)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Copy to Server", systemImage: "arrow.right.doc.on.clipboard") {
                    showingDestinations = true
                }
            }
            if provider.capabilities.contains(.permissions) {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Permissions", systemImage: "lock.shield") {
                        showingPermissions = true
                    }
                }
            }
            if provider.capabilities.contains(.accessControl) {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Access Control", systemImage: "person.badge.key") {
                        showingAccessControl = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingDestinations) {
            CopyDestinationView(
                profiles: connections.profiles.filter { $0.id != provider.profile.id },
                fileName: item.name
            ) { destination, folder in
                let sourceProfile = provider.profile
                Task {
                    do {
                        try await transfers.copyItems(
                            [item],
                            from: sourceProfile,
                            to: destination,
                            destinationDirectory: folder
                        )
                    } catch is CancellationError {
                    } catch {
                        copyError = error.localizedDescription
                    }
                }
            }
        }
        .alert("Copy Failed", isPresented: Binding(get: { copyError != nil }, set: { if !$0 { copyError = nil } })) {
            Button("OK") { copyError = nil }
        } message: {
            Text(copyError ?? "Unknown error")
        }
        .sheet(isPresented: $showingPermissions) {
            PermissionsEditorView(provider: provider, item: item)
        }
        .sheet(isPresented: $showingAccessControl) {
            AccessControlView(provider: provider, item: item)
        }
        .onAppear {
            history.recordOpened(profileID: provider.profile.id, path: item.path, name: item.name)
        }
    }

    private var offlineActionTitle: LocalizedStringKey {
        offline.isPinned(profileID: provider.profile.id, path: item.path) ? "Remove Offline Copy" : "Keep Offline"
    }

    private func toggleOffline() async {
        offlineWorking = true
        defer { offlineWorking = false }
        if offline.isPinned(profileID: provider.profile.id, path: item.path) {
            offline.unpin(profileID: provider.profile.id, path: item.path)
            return
        }
        do {
            try await offline.pin(provider: provider, item: item, transfers: transfers)
        } catch {
            copyError = error.localizedDescription
        }
    }
}

struct CopyDestinationView: View {
    @Environment(\.dismiss) private var dismiss
    let profiles: [ConnectionProfile]
    let fileName: String
    let onSelect: (ConnectionProfile, String) -> Void

    var body: some View {
        NavigationStack {
            List(profiles) { profile in
                NavigationLink {
                    RemoteFolderPickerView(profile: profile) { folder in
                        onSelect(profile, folder)
                        dismiss()
                    }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                            Text("\(profile.protocolType.title) · \(RemotePath.normalize(profile.initialPath))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: profile.protocolType.systemImage)
                    }
                }
            }
            .overlay {
                if profiles.isEmpty {
                    ContentUnavailableView("No Other Servers", systemImage: "externaldrive", description: Text("Add another connection before copying \(fileName)."))
                }
            }
            .navigationTitle("Copy to Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
