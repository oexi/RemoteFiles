import SwiftUI

struct OfflineListView: View {
    @EnvironmentObject private var offline: OfflineStore

    var body: some View {
        NavigationStack {
            List(offline.items) { item in
                NavigationLink {
                    OfflineDetailView(item: item)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.fileName).lineLimit(1)
                        HStack {
                            Text(item.profileName)
                            if let size = item.size {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { offline.unpin(item) } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
            .overlay {
                if offline.items.isEmpty {
                    ContentUnavailableView(
                        "No Offline Files",
                        systemImage: "arrow.down.circle",
                        description: Text("Keep remote files offline to access them without a server connection.")
                    )
                }
            }
            .navigationTitle("Offline")
        }
    }
}
