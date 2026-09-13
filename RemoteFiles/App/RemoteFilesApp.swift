import SwiftUI

@main
struct RemoteFilesApp: App {
    @StateObject private var connections = ConnectionStore()
    @StateObject private var transfers = TransferEngine()
    @StateObject private var offline = OfflineStore()
    @StateObject private var clipboard = FileOperationClipboard()
    @AppStorage(AppPreferenceKey.appearance) private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(AppPreferenceKey.language) private var languageRawValue = AppLanguage.system.rawValue

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRawValue) ?? .system
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRawValue) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(connections)
                .environmentObject(transfers)
                .environmentObject(offline)
                .environmentObject(clipboard)
                .preferredColorScheme(appearance.colorScheme)
                .environment(\.locale, language.locale)
        }
    }
}

