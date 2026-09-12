import Foundation

struct UnavailableProvider: RemoteFileProvider {
    let profile: ConnectionProfile
    let reason: String
    let capabilities = ProviderCapabilities.readOnly

    func connect() async throws { throw RemoteProviderError.unsupported(reason) }
    func list(path: String) async throws -> [RemoteItem] { throw RemoteProviderError.unsupported(reason) }
    func download(path: String, to localURL: URL) async throws { throw RemoteProviderError.unsupported(reason) }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { throw RemoteProviderError.unsupported(reason) }
}

