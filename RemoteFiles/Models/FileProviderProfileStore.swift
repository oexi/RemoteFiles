import Foundation

enum FileProviderProfileStore {
    static let appGroupIdentifier = "group.com.oexi.RemoteFiles"

    static func load(profileID: UUID) -> ConnectionProfile? {
        guard let data = try? Data(contentsOf: fileURL(profileID: profileID)) else { return nil }
        return try? JSONDecoder().decode(ConnectionProfile.self, from: data)
    }

    static func save(_ profile: ConnectionProfile) throws {
        let data = try JSONEncoder().encode(profile)
        try data.write(to: fileURL(profileID: profile.id), options: .atomic)
    }

    static func remove(profileID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(profileID: profileID))
    }

    static func retainOnly(_ profileIDs: Set<UUID>) {
        guard let directory = try? directoryURL() else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "json" {
            let name = url.deletingPathExtension().lastPathComponent
            if let id = UUID(uuidString: name), !profileIDs.contains(id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func fileURL(profileID: UUID) -> URL {
        let directory = (try? directoryURL())
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return directory.appendingPathComponent(profileID.uuidString).appendingPathExtension("json")
    }

    private static func directoryURL() throws -> URL {
        let fileManager = FileManager.default
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = container.appendingPathComponent("FileProviderProfiles", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
