import Foundation

enum TransferState: String, Codable, Sendable {
    case queued, running, completed, failed, cancelled
}

struct TransferRecord: Identifiable, Hashable, Sendable {
    let id: UUID
    let fileName: String
    let source: String
    let destination: String
    var state: TransferState
    var progress: Double
    var errorMessage: String?

    init(fileName: String, source: String, destination: String) {
        id = UUID()
        self.fileName = fileName
        self.source = source
        self.destination = destination
        state = .queued
        progress = 0
    }
}

