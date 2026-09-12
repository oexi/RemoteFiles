import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            ConnectionListView()
                .tabItem { Label("Files", systemImage: "folder") }
            TransferListView()
                .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
        }
    }
}

