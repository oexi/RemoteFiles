import Foundation
import Combine

@MainActor
final class TransferEngine: ObservableObject {
    @Published private(set) var records: [TransferRecord] = []

    func copyFile(
        item: RemoteItem,
        from source: any RemoteFileProvider,
        to destination: any RemoteFileProvider,
        destinationPath: String,
        overwrite: Bool = false
    ) {
        let record = TransferRecord(
            fileName: item.name,
            source: "\(source.profile.name):\(item.path)",
            destination: "\(destination.profile.name):\(destinationPath)"
        )
        records.insert(record, at: 0)
        let id = record.id

        Task {
            update(id) { $0.state = .running; $0.progress = 0.05 }
            do {
                let tempURL = try await CacheManager.shared.temporaryURL(fileName: item.name)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try await source.download(path: item.path, to: tempURL)
                update(id) { $0.progress = 0.55 }
                try await destination.upload(from: tempURL, to: destinationPath, overwrite: overwrite)
                await destination.disconnect()
                update(id) { $0.state = .completed; $0.progress = 1 }
            } catch {
                await destination.disconnect()
                update(id) { $0.state = .failed; $0.errorMessage = error.localizedDescription }
            }
        }
    }

    func clearFinished() {
        records.removeAll { $0.state == .completed || $0.state == .cancelled }
    }

    private func update(_ id: UUID, _ mutation: (inout TransferRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutation(&records[index])
    }
}

