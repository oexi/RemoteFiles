import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese
    case traditionalChinese

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .english: "English"
        case .simplifiedChinese: "Simplified Chinese"
        case .traditionalChinese: "Traditional Chinese"
        }
    }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .simplifiedChinese: Locale(identifier: "zh-Hans")
        case .traditionalChinese: Locale(identifier: "zh-Hant")
        }
    }
}

enum AppPreferenceKey {
    static let appearance = "RemoteFiles.Appearance"
    static let language = "RemoteFiles.Language"
    static let browserSortKey = "RemoteFiles.Browser.SortKey"
    static let browserSortAscending = "RemoteFiles.Browser.SortAscending"
    static let browserFoldersFirst = "RemoteFiles.Browser.FoldersFirst"
    static let browserLayout = "RemoteFiles.Browser.Layout"
    static let appLockEnabled = "RemoteFiles.AppLock.Enabled"
    static let appLockTimeout = "RemoteFiles.AppLock.Timeout"
}
