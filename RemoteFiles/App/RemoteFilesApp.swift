import SwiftUI

@main
struct RemoteFilesApp: App {
    @StateObject private var connections = ConnectionStore()
    @StateObject private var transfers = TransferEngine()
    @StateObject private var offline = OfflineStore()
    @StateObject private var clipboard = FileOperationClipboard()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(connections)
                .environmentObject(transfers)
                .environmentObject(offline)
                .environmentObject(clipboard)
        }
    }
}

