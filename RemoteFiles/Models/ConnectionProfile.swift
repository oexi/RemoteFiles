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

    static func empty(for type: RemoteProtocol = .sftp) -> Self {
        .init(name: type.title, protocolType: type, host: "", port: type.defaultPort, useTLS: type == .webdav || type == .ftps)
    }
}

