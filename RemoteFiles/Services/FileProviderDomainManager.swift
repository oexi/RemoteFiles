import FileProvider
import Foundation
import OSLog

@MainActor
enum FileProviderDomainManager {
    private static let logger = Logger(subsystem: "com.oexi.RemoteFiles", category: "FileProviderDomains")

    static func register(_ profile: ConnectionProfile) {
        Task { await upsert(profile) }
    }

    static func remove(_ profile: ConnectionProfile) {
        Task {
            do {
                let domains = try await NSFileProviderManager.domains()
                guard let domain = domains.first(where: { $0.identifier.rawValue == profile.id.uuidString }) else { return }
                try await NSFileProviderManager.remove(domain)
                FileProviderProfileStore.remove(profileID: profile.id)
            } catch {
                logger.error("Failed to remove File Provider domain: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Asks the Files app to re-enumerate `directory` after the app changed
    /// it, so uploads, deletes and renames show up without a manual refresh.
    /// Directories the extension has never enumerated are skipped: the Files
    /// app will list them fresh when it opens them.
    static func signalChange(in directory: String, profile: ConnectionProfile) {
        guard isRunningOutsideTests else { return }
        let codec = FileProviderPathCodec(rootPath: profile.initialPath)
        guard let identifier = FileProviderIdentityStore(profileID: profile.id)
            .knownIdentifier(for: directory, codec: codec) else { return }
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: profile.id.uuidString),
            displayName: profile.name
        )
        let logger = Self.logger
        NSFileProviderManager(for: domain)?.signalEnumerator(for: identifier) { error in
            if let error {
                logger.debug("File Provider signal failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static var isRunningOutsideTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] == nil
            && environment["XCTestBundlePath"] == nil
    }

    static func registerAll(_ profiles: [ConnectionProfile]) {
        Task {
            do {
                let domains = try await NSFileProviderManager.domains()
                let profileIDs = Set(profiles.map { $0.id.uuidString })
                FileProviderProfileStore.retainOnly(Set(profiles.map(\.id)))

                for domain in domains where !profileIDs.contains(domain.identifier.rawValue) {
                    try? await NSFileProviderManager.remove(domain)
                }

                for profile in profiles {
                    await upsert(profile, knownDomains: try await NSFileProviderManager.domains())
                }
            } catch {
                logger.error("Failed to synchronize File Provider domains: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func upsert(_ profile: ConnectionProfile, knownDomains: [NSFileProviderDomain]? = nil) async {
        do {
            let previousProfile = FileProviderProfileStore.load(profileID: profile.id)
            try FileProviderProfileStore.save(profile)

            let domains: [NSFileProviderDomain]
            if let knownDomains {
                domains = knownDomains
            } else {
                domains = try await NSFileProviderManager.domains()
            }
            let identifier = NSFileProviderDomainIdentifier(rawValue: profile.id.uuidString)
            let desired = NSFileProviderDomain(identifier: identifier, displayName: profile.name)

            if let existing = domains.first(where: { $0.identifier == identifier }) {
                let sameName = existing.displayName == desired.displayName
                if sameName && previousProfile == profile {
                    return
                }
                try await NSFileProviderManager.remove(existing)
            }

            try await NSFileProviderManager.add(desired)
        } catch {
            logger.error("Failed to register File Provider domain for \(profile.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
