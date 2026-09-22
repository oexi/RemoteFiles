import Foundation

/// Reuses one provider per connection across File Provider requests.
///
/// The Files app issues many small requests (item lookups, enumerations,
/// downloads) in quick succession; opening a new SSH/SMB session for each one
/// made browsing slow. Providers that are safe to share between concurrent
/// requests are kept for a short idle period after the last request finishes.
/// Other protocols still get a dedicated connection per request.
final class FileProviderConnectionPool: @unchecked Sendable {
    static let shared = FileProviderConnectionPool()

    /// A leased provider. Call `release()` exactly once when the request ends.
    final class Lease: @unchecked Sendable {
        let provider: any RemoteFileProvider
        private let onRelease: @Sendable () -> Void
        private let lock = NSLock()
        private var released = false

        init(provider: any RemoteFileProvider, onRelease: @escaping @Sendable () -> Void) {
            self.provider = provider
            self.onRelease = onRelease
        }

        func release() {
            let shouldRelease = lock.withLock {
                defer { released = true }
                return !released
            }
            if shouldRelease { onRelease() }
        }
    }

    private static let idleTimeout: UInt64 = 60_000_000_000

    private let lock = NSLock()
    private var providers: [UUID: any RemoteFileProvider] = [:]
    private var credentialFingerprints: [UUID: Int] = [:]
    private var leaseCounts: [UUID: Int] = [:]
    private var idleTasks: [UUID: Task<Void, Never>] = [:]

    static func isShareable(_ type: RemoteProtocol) -> Bool {
        switch type {
        case .sftp, .smb, .webdav:
            // These serialize their own connection state and reconnect after
            // a dropped session, so concurrent requests can share them.
            return true
        case .ftp, .ftps, .nfs:
            return false
        }
    }

    func lease(for profile: ConnectionProfile) async throws -> Lease {
        guard Self.isShareable(profile.protocolType) else {
            let credential = try CredentialVault.shared.load(for: profile.id)
            let provider = try ProviderFactory.make(for: profile, credential: credential)
            try await provider.connect()
            return Lease(provider: provider) {
                Task { await provider.disconnect() }
            }
        }

        let id = profile.id
        // Reload the credential on every request so a password changed in the
        // app takes effect immediately instead of after the idle timeout.
        let credential = try CredentialVault.shared.load(for: id)
        let fingerprint = Self.fingerprint(of: credential)
        let provider: any RemoteFileProvider = try lock.withLock {
            idleTasks.removeValue(forKey: id)?.cancel()
            if let existing = providers[id] {
                if credentialFingerprints[id] == fingerprint {
                    leaseCounts[id, default: 0] += 1
                    return existing
                }
                // Credentials changed: replace the provider. Requests still
                // using the old one keep their reference and finish; its
                // session closes when the last of them lets go.
            }
            let created = try ProviderFactory.make(for: profile, credential: credential)
            providers[id] = created
            credentialFingerprints[id] = fingerprint
            leaseCounts[id, default: 0] += 1
            return created
        }
        // Shared providers connect lazily on first use and reconnect on their
        // own, so no explicit connect round trip is needed here.
        return Lease(provider: provider) { [weak self] in
            self?.release(id)
        }
    }

    private static func fingerprint(of credential: Credential?) -> Int {
        var hasher = Hasher()
        hasher.combine(credential?.username)
        hasher.combine(credential?.password)
        hasher.combine(credential?.privateKey)
        hasher.combine(credential?.privateKeyPassphrase)
        return hasher.finalize()
    }

    private func release(_ id: UUID) {
        lock.withLock {
            let remaining = max(0, (leaseCounts[id] ?? 1) - 1)
            leaseCounts[id] = remaining
            guard remaining == 0 else { return }
            idleTasks[id]?.cancel()
            idleTasks[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.idleTimeout)
                guard !Task.isCancelled else { return }
                await self?.evictIfIdle(id)
            }
        }
    }

    private func evictIfIdle(_ id: UUID) async {
        let provider: (any RemoteFileProvider)? = lock.withLock {
            guard leaseCounts[id] ?? 0 == 0 else { return nil }
            idleTasks[id] = nil
            return providers.removeValue(forKey: id)
        }
        await provider?.disconnect()
    }
}
