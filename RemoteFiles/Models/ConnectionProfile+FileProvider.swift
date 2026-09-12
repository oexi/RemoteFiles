import Foundation

extension ConnectionProfile {
    var fileProviderUserInfo: [AnyHashable: Any] {
        [
            "name": name,
            "protocol": protocolType.rawValue,
            "host": host,
            "port": port,
            "username": username,
            "initialPath": initialPath,
            "share": share,
            "domain": domain,
            "useTLS": useTLS,
            "verifyTLS": verifyTLS,
            "nfsExport": nfsExport
        ]
    }

    init?(fileProviderDomainIdentifier: String, userInfo: [AnyHashable: Any]?) {
        guard let id = UUID(uuidString: fileProviderDomainIdentifier),
              let info = userInfo,
              let rawProtocol = info["protocol"] as? String,
              let protocolType = RemoteProtocol(rawValue: rawProtocol),
              let host = info["host"] as? String,
              let port = info["port"] as? Int else { return nil }
        self.init(
            id: id,
            name: info["name"] as? String ?? protocolType.title,
            protocolType: protocolType,
            host: host,
            port: port,
            username: info["username"] as? String ?? "",
            initialPath: info["initialPath"] as? String ?? "/",
            share: info["share"] as? String ?? "",
            domain: info["domain"] as? String ?? "",
            useTLS: info["useTLS"] as? Bool ?? true,
            verifyTLS: info["verifyTLS"] as? Bool ?? true,
            nfsExport: info["nfsExport"] as? String ?? "/"
        )
    }
}
