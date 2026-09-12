import SwiftUI

struct RootView: View {
    @EnvironmentObject private var connections: ConnectionStore
    @EnvironmentObject private var transfers: TransferEngine

    var body: some View {
        TabView {
            ConnectionListView()
                .tabItem { Label("Files", systemImage: "folder") }
            TransferListView()
                .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
            OfflineListView()
                .tabItem { Label("Offline", systemImage: "arrow.down.circle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task {
            transfers.resumePending(using: connections)
        }
    }
}

