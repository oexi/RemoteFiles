import SwiftUI

@main
struct RemoteFilesApp: App {
    @StateObject private var connections = ConnectionStore()
    @StateObject private var transfers = TransferEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(connections)
                .environmentObject(transfers)
        }
    }
}

