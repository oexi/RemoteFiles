import SwiftUI

struct SettingsView: View {
    @AppStorage(AppPreferenceKey.appearance) private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(AppPreferenceKey.language) private var languageRawValue = AppLanguage.system.rawValue
    @State private var cacheUsage: Int64?
    @State private var cacheError: String?
    @State private var isClearingCache = false

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

                Section("Cache") {
                    LabeledContent("Cache Usage") {
                        if let cacheUsage {
                            Text(ByteCountFormatter.string(fromByteCount: cacheUsage, countStyle: .file))
                        } else {
                            Text("Calculating…")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Cached previews and materialized files. Offline files and active transfers are not affected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Clear Cache", role: .destructive) {
                        Task { @MainActor in
                            await clearCache()
                        }
                    }
                    .disabled(isClearingCache)

                    if isClearingCache {
                        ProgressView()
                    }

                    if let cacheError {
                        Text(cacheError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
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
