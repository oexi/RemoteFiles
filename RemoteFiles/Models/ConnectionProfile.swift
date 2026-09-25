import Foundation

enum RemoteProtocol: String, CaseIterable, Codable, Identifiable, Sendable {
    case ftp, ftps, sftp, smb, webdav, nfs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ftp: "FTP"
        case .ftps: "FTPS"
        case .sftp: "SFTP"
        case .smb: "SMB"
        case .webdav: "WebDAV"
        case .nfs: "NFS"
        }
    }

    var defaultPort: Int {
        switch self {
        case .ftp: 21
        case .ftps: 990
        case .sftp: 22
        case .smb: 445
        case .webdav: 443
        case .nfs: 2049
        }
    }

    var systemImage: String {
        switch self {
        case .ftp, .ftps: "arrow.up.arrow.down.circle"
        case .sftp: "terminal"
        case .smb: "externaldrive.connected.to.line.below"
        case .webdav: "globe"
        case .nfs: "server.rack"
        }
    }
}

enum SMBTransport: String, CaseIterable, Codable, Identifiable, Sendable {
    case tcp, quic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tcp: "TCP"
        case .quic: "QUIC"
        }
    }

    var defaultPort: Int {
        switch self {
        case .tcp: 445
        case .quic: 443
        }
    }
}

struct ConnectionProfile: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var protocolType: RemoteProtocol
    var host: String
    var port: Int
    var username = ""
    var initialPath = "/"
    var share = ""
    var domain = ""
    var useTLS = true
    var verifyTLS = true
    var nfsExport = "/"
    /// SMB over QUIC instead of TCP (Windows Server 2022 Azure Edition, 2025).
    var smbTransport = SMBTransport.tcp
    /// Refuse to connect unless the whole session is encrypted (SMB 3.x).
    var smbRequireEncryption = false
    /// Spread large transfers over extra connections (SMB 3.x multichannel).
    var smbMultiChannel = false
    /// Offer SMB 3.1.1 compression to the server.
    var smbCompression = false

    static func empty(for type: RemoteProtocol = .sftp) -> Self {
        .init(name: type.title, protocolType: type, host: "", port: type.defaultPort, useTLS: type == .webdav || type == .ftps)
    }
}

extension ConnectionProfile {
    private enum CodingKeys: String, CodingKey {
        case id, name, protocolType, host, port, username, initialPath, share, domain
        case useTLS, verifyTLS, nfsExport
        case smbTransport, smbRequireEncryption, smbMultiChannel, smbCompression
    }

    /// Profiles saved before a setting existed lack its key, so every
    /// property falls back to its default instead of failing to decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let protocolType = try container.decode(RemoteProtocol.self, forKey: .protocolType)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            protocolType: protocolType,
            host: try container.decode(String.self, forKey: .host),
            port: try container.decode(Int.self, forKey: .port)
        )
        id = try container.decode(UUID.self, forKey: .id)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? username
        initialPath = try container.decodeIfPresent(String.self, forKey: .initialPath) ?? initialPath
        share = try container.decodeIfPresent(String.self, forKey: .share) ?? share
        domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? domain
        useTLS = try container.decodeIfPresent(Bool.self, forKey: .useTLS) ?? useTLS
        verifyTLS = try container.decodeIfPresent(Bool.self, forKey: .verifyTLS) ?? verifyTLS
        nfsExport = try container.decodeIfPresent(String.self, forKey: .nfsExport) ?? nfsExport
        smbTransport = try container.decodeIfPresent(SMBTransport.self, forKey: .smbTransport) ?? smbTransport
        smbRequireEncryption = try container.decodeIfPresent(Bool.self, forKey: .smbRequireEncryption) ?? smbRequireEncryption
        smbMultiChannel = try container.decodeIfPresent(Bool.self, forKey: .smbMultiChannel) ?? smbMultiChannel
        smbCompression = try container.decodeIfPresent(Bool.self, forKey: .smbCompression) ?? smbCompression
    }
}
