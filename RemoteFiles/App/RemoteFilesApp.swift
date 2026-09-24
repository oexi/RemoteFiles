import SwiftUI

@main
struct RemoteFilesApp: App {
    @StateObject private var connections = ConnectionStore()
    @StateObject private var transfers = TransferEngine()
    @StateObject private var offline = OfflineStore()
    @StateObject private var clipboard = FileOperationClipboard()
    @StateObject private var history = LocationHistoryStore()
    @StateObject private var appLock = AppLockManager()
    @StateObject private var backgroundActivity = TransferBackgroundActivity()
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
                .modifier(AppLockCoverModifier(appLock: appLock))
                .environmentObject(connections)
                .environmentObject(transfers)
                .environmentObject(offline)
                .environmentObject(clipboard)
                .environmentObject(history)
                .environmentObject(appLock)
                .preferredColorScheme(appearance.colorScheme)
                .environment(\.locale, language.locale)
                .task { backgroundActivity.attach(to: transfers) }
        }
    }
}

