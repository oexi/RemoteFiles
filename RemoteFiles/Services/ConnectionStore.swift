import Foundation
import Combine

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("RemoteFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("connections.json")
        load()
        FileProviderDomainManager.registerAll(profiles)
    }

    func upsert(_ profile: ConnectionProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
        FileProviderDomainManager.register(profile)
    }

    func remove(_ profile: ConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
        CredentialVault.shared.remove(for: profile.id)
        persist()
        FileProviderDomainManager.remove(profile)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ConnectionProfile].self, from: data) else { return }
        profiles = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

