import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("About") {
                    LabeledContent("Version", value: AppVersion.short)
                    LabeledContent("Build", value: AppVersion.build)
                }

                Section("Protocols") {
                    Text("FTP, FTPS, SFTP, SMB, WebDAV and NFS")
                }

                Section("Compatibility") {
                    Text("iOS 17–26 · iPadOS 17–26")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
