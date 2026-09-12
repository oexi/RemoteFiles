import FileProvider
import Foundation

@MainActor
enum FileProviderDomainManager {
    static func register(_ profile: ConnectionProfile) {
        let identifier = NSFileProviderDomainIdentifier(rawValue: profile.id.uuidString)
        let domain = NSFileProviderDomain(identifier: identifier, displayName: profile.name)
        domain.userInfo = profile.fileProviderUserInfo
        NSFileProviderManager.add(domain) { _ in }
    }

    static func remove(_ profile: ConnectionProfile) {
        let domain = NSFileProviderDomain(
            identifier: .init(rawValue: profile.id.uuidString),
            displayName: profile.name
        )
        NSFileProviderManager.remove(domain) { _ in }
    }

    static func registerAll(_ profiles: [ConnectionProfile]) {
        for profile in profiles { register(profile) }
    }
}
