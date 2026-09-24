import Combine
import Foundation
import Network

/// A file server advertised over Bonjour on the local network.
struct DiscoveredServer: Identifiable, Hashable, Sendable {
    var id: String { "\(serviceType)|\(name)" }
    let name: String
    let serviceType: String
    let protocolType: RemoteProtocol
    let useTLS: Bool
    fileprivate let endpoint: NWEndpoint
}

struct ResolvedServer: Equatable, Sendable {
    let host: String
    let port: Int
}

/// Browses Bonjour for SMB, SFTP, WebDAV, FTP and NFS servers.
/// Every browsed type must also be listed in `NSBonjourServices` (RemoteFiles/Info.plist).
@MainActor
final class LANServiceBrowser: ObservableObject {
    static let serviceTypes = [
        "_smb._tcp", "_sftp-ssh._tcp", "_ssh._tcp", "_webdav._tcp", "_webdavs._tcp", "_ftp._tcp", "_nfs._tcp"
    ]

    @Published private(set) var servers: [DiscoveredServer] = []

    private var browsers: [NWBrowser] = []
    private var results: [String: [DiscoveredServer]] = [:]

    /// Maps a Bonjour service type to the protocol to connect with, and whether it uses TLS.
    nonisolated static func connectionKind(forServiceType type: String) -> (protocolType: RemoteProtocol, useTLS: Bool)? {
        switch type.trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
        case "_smb._tcp": (.smb, false)
        case "_sftp-ssh._tcp", "_ssh._tcp": (.sftp, false)
        case "_webdav._tcp": (.webdav, false)
        case "_webdavs._tcp": (.webdav, true)
        case "_ftp._tcp": (.ftp, false)
        case "_nfs._tcp": (.nfs, false)
        default: nil
        }
    }

    func start() {
        guard browsers.isEmpty else { return }
        for type in Self.serviceTypes {
            let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let servers = results.compactMap { Self.server(from: $0.endpoint) }
                Task { @MainActor in self?.update(type: type, servers: servers) }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
    }

    /// Resolves a server's address by opening (and immediately closing) a TCP connection.
    /// IPv4 is preferred so the host field does not end up with a scoped IPv6 address.
    nonisolated func resolve(_ server: DiscoveredServer) async throws -> ResolvedServer {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: server.endpoint, using: parameters)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumed = ResumeOnce()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let endpoint = connection.currentPath?.remoteEndpoint
                        connection.cancel()
                        if case let .hostPort(host, port)? = endpoint {
                            resumed.run { continuation.resume(returning: ResolvedServer(host: Self.hostString(host), port: Int(port.rawValue))) }
                        } else {
                            resumed.run { continuation.resume(throwing: RemoteProviderError.invalidResponse("The server address could not be resolved.")) }
                        }
                    case let .failed(error), let .waiting(error):
                        connection.cancel()
                        resumed.run { continuation.resume(throwing: error) }
                    case .cancelled:
                        resumed.run { continuation.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func update(type: String, servers: [DiscoveredServer]) {
        results[type] = servers
        // A NAS usually advertises several services; list each protocol once per name.
        var seen = Set<String>()
        self.servers = results.values.flatMap { $0 }
            .sorted {
                if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return $0.serviceType < $1.serviceType
            }
            .filter { seen.insert("\($0.name)|\($0.protocolType.rawValue)|\($0.useTLS)").inserted }
    }

    private nonisolated static func server(from endpoint: NWEndpoint) -> DiscoveredServer? {
        guard case let .service(name, type, _, _) = endpoint,
              let kind = connectionKind(forServiceType: type) else { return nil }
        return DiscoveredServer(
            name: name,
            serviceType: type,
            protocolType: kind.protocolType,
            useTLS: kind.useTLS,
            endpoint: endpoint
        )
    }

    private nonisolated static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case let .name(name, _): name
        case let .ipv4(address): "\(address)"
        case let .ipv6(address): "\(address)".components(separatedBy: "%").first ?? "\(address)"
        @unknown default: "\(host)"
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let shouldRun = lock.withLock {
            defer { done = true }
            return !done
        }
        if shouldRun { body() }
    }
}
