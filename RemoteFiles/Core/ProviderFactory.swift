import Foundation

enum ProviderFactory {
    static func make(for profile: ConnectionProfile, credential providedCredential: Credential? = nil) throws -> any RemoteFileProvider {
        let credential: Credential?
        if let providedCredential {
            credential = providedCredential
        } else {
            credential = try CredentialVault.shared.load(for: profile.id)
        }
        switch profile.protocolType {
        case .webdav:
            return WebDAVProvider(profile: profile, credential: credential)
        case .smb:
            return SMBProvider(profile: profile, credential: credential)
        case .nfs:
            return try NFSProvider(profile: profile)
        case .ftp, .ftps:
            return try FTPProvider(profile: profile, credential: credential)
        case .sftp:
            return SFTPProvider(profile: profile, credential: credential)
        }
    }
}

