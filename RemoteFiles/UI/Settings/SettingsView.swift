import SwiftUI

struct SettingsView: View {
    @AppStorage(AppPreferenceKey.appearance) private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(AppPreferenceKey.language) private var languageRawValue = AppLanguage.system.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearanceRawValue) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance.rawValue)
                        }
                    }
                }

                Section("Language") {
                    Picker("Language", selection: $languageRawValue) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language.rawValue)
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: AppVersion.short)
                    LabeledContent("Build", value: AppVersion.build)
                    LabeledContent("File Icons", value: "WhiteSur · GPL-3.0")
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
