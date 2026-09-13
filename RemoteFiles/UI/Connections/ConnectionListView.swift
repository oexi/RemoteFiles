import SwiftUI

struct ConnectionListView: View {
    @EnvironmentObject private var store: ConnectionStore
    @State private var editingProfile: ConnectionProfile?
    @State private var showingNewConnection = false

    var body: some View {
        NavigationStack {
            List {
                if store.profiles.isEmpty {
                    ContentUnavailableView(
                        "No Servers",
                        systemImage: "externaldrive.badge.plus",
                        description: Text("Add an FTP, SFTP, SMB, WebDAV or NFS server.")
                    )
                } else {
                    ForEach(store.profiles) { profile in
                        NavigationLink {
                            BrowserView(profile: profile)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name)
                                    Text("\(profile.protocolType.title) · \(profile.host)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: profile.protocolType.systemImage)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { store.remove(profile) } label: { Label("Delete", systemImage: "trash") }
                            Button { editingProfile = profile } label: { Label("Edit", systemImage: "pencil") }
                                .tint(.blue)
                        }
                    }
                }
            }
            .navigationTitle("RemoteFiles")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingNewConnection = true } label: { Image(systemName: "plus") }
                }
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
}

