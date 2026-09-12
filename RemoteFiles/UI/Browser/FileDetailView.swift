import SwiftUI

struct FileDetailView: View {
    @EnvironmentObject private var connections: ConnectionStore
    @EnvironmentObject private var transfers: TransferEngine

    let provider: any RemoteFileProvider
    let item: RemoteItem

    @State private var showingDestinations = false
    @State private var copyError: String?

    var body: some View {
        let ext = (item.name as NSString).pathExtension.lowercased()
        Group {
            if EditorLanguage.isEditable(fileName: item.name) {
                RemoteEditorView(provider: provider, item: item)
            } else if ext == "zip" {
                ArchiveDetailView(provider: provider, item: item)
            } else {
                RemotePreviewView(provider: provider, item: item)
            }
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button("Copy to Server", systemImage: "arrow.right.doc.on.clipboard") {
                    showingDestinations = true
                }
            }
        }
        .sheet(isPresented: $showingDestinations) {
            CopyDestinationView(
                profiles: connections.profiles.filter { $0.id != provider.profile.id },
                fileName: item.name
            ) { destination in
                do {
                    let destinationProvider = try ProviderFactory.make(for: destination)
                    let root = RemotePath.normalize(destination.initialPath)
                    transfers.copyFile(
                        item: item,
                        from: provider,
                        to: destinationProvider,
                        destinationPath: RemotePath.join(root, item.name)
                    )
                } catch {
                    copyError = error.localizedDescription
                }
            }
        }
        .alert("Copy Failed", isPresented: Binding(get: { copyError != nil }, set: { if !$0 { copyError = nil } })) {
            Button("OK") { copyError = nil }
        } message: {
            Text(copyError ?? "Unknown error")
        }
    }
}

private struct CopyDestinationView: View {
    @Environment(\.dismiss) private var dismiss
    let profiles: [ConnectionProfile]
    let fileName: String
    let onSelect: (ConnectionProfile) -> Void

    var body: some View {
        NavigationStack {
            List(profiles) { profile in
                Button {
                    onSelect(profile)
                    dismiss()
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
                .buttonStyle(.plain)
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

