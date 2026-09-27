import SwiftUI

struct SettingsView: View {
    @AppStorage(AppPreferenceKey.appearance) private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(AppPreferenceKey.language) private var languageRawValue = AppLanguage.system.rawValue
    @AppStorage(AppPreferenceKey.rememberRecentFiles) private var rememberRecentFiles = true
    @EnvironmentObject private var appLock: AppLockManager
    @EnvironmentObject private var history: LocationHistoryStore
    @State private var cacheUsage: Int64?
    @State private var cacheError: String?
    @State private var isClearingCache = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker(selection: $appearanceRawValue) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance.rawValue)
                        }
                    } label: {
                        SettingsLabel("Theme", systemImage: "circle.lefthalf.filled", color: .indigo)
                    }
                    Picker(selection: $languageRawValue) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language.rawValue)
                        }
                    } label: {
                        SettingsLabel("Language", systemImage: "globe", color: .blue)
                    }
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { appLock.isEnabled },
                        set: { enabled in Task { await appLock.setEnabled(enabled) } }
                    )) {
                        SettingsLabel("App Lock", systemImage: "lock.fill", color: .green)
                    }
                    .disabled(!appLock.isEnabled && !appLock.canAuthenticate)
                    if appLock.isEnabled {
                        Picker(selection: $appLock.timeout) {
                            ForEach(AppLockTimeout.allCases) { timeout in
                                Text(timeout.title).tag(timeout)
                            }
                        } label: {
                            SettingsLabel("Require Unlock", systemImage: "timer", color: .orange)
                        }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Uses Face ID, Touch ID or the device passcode. Transfers keep running while the app is locked. The Files app is not covered by the app lock.")
                }

                Section {
                    Toggle(isOn: $rememberRecentFiles) {
                        SettingsLabel("Remember Recent Files", systemImage: "clock.fill", color: .orange)
                    }
                    .onChange(of: rememberRecentFiles) { _, remember in
                        if !remember { history.clearRecents() }
                    }
                } footer: {
                    Text("Files you open are listed under Recent Files on the Files tab. Turning this off also clears the list.")
                }

                Section {
                    LabeledContent {
                        if let cacheUsage {
                            Text(ByteCountFormatter.string(fromByteCount: cacheUsage, countStyle: .file))
                        } else if cacheError == nil {
                            ProgressView()
                        }
                    } label: {
                        SettingsLabel("Cache Usage", systemImage: "internaldrive.fill", color: .gray)
                    }

                    Button(role: .destructive) {
                        Task { @MainActor in
                            await clearCache()
                        }
                    } label: {
                        HStack {
                            Text("Clear Cache")
                            Spacer()
                            if isClearingCache {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isClearingCache)

                    if let cacheError {
                        Text(cacheError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Cache")
                } footer: {
                    Text("Cached previews and materialized files. Offline files and active transfers are not affected.")
                }

                Section("About") {
                    LabeledContent("Version") {
                        Text(verbatim: "\(AppVersion.short) (\(AppVersion.build))")
                    }
                    LabeledContent("Protocols") {
                        Text(verbatim: "FTP · FTPS · SFTP · SMB · WebDAV · NFS")
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("File Icons", value: "WhiteSur · GPL-3.0")
                }
            }
            .navigationTitle("Settings")
            .task {
                await refreshCacheUsage()
            }
        }
    }

    @MainActor
    private func refreshCacheUsage() async {
        do {
            cacheUsage = try await currentCacheUsage()
            cacheError = nil
        } catch {
            cacheUsage = nil
            cacheError = error.localizedDescription
        }
    }

    @MainActor
    private func clearCache() async {
        guard !isClearingCache else { return }
        isClearingCache = true

        var failures: [String] = []
        do {
            try await CacheManager.shared.clear()
        } catch {
            failures.append(error.localizedDescription)
        }

        do {
            try ThumbnailStore.shared.clear()
        } catch {
            failures.append(error.localizedDescription)
        }

        do {
            cacheUsage = try await currentCacheUsage()
        } catch {
            cacheUsage = nil
            failures.append(error.localizedDescription)
        }

        cacheError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        isClearingCache = false
    }

    @MainActor
    private func currentCacheUsage() async throws -> Int64 {
        let materializedBytes = try await CacheManager.shared.cacheSize()
        let thumbnailBytes = try ThumbnailStore.shared.diskUsage()
        return materializedBytes + thumbnailBytes
    }
}
