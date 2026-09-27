import SwiftUI

struct RootView: View {
    @EnvironmentObject private var connections: ConnectionStore
    @EnvironmentObject private var transfers: TransferEngine

    /// Transfers still running or waiting to run, shown on the Transfers tab.
    private var activeTransfers: Int {
        transfers.records.filter { $0.state == .queued || $0.state == .running }.count
    }

    var body: some View {
        TabView {
            ConnectionListView()
                .tabItem { Label("Files", systemImage: "folder") }
            TransferListView()
                .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
                .badge(activeTransfers)
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

