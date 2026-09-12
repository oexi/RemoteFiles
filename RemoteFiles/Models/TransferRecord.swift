import Foundation

enum TransferState: String, Codable, Sendable {
    case queued, running, completed, failed, cancelled
}

struct TransferRecord: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let fileName: String
    let sourceProfileID: UUID
    let sourcePath: String
    let destinationProfileID: UUID
    let destinationPath: String
    let overwrite: Bool
    let source: String
    let destination: String
    var state: TransferState
    var progress: Double
    var transferredBytes: UInt64?
    var errorMessage: String?

    init(
        fileName: String,
        sourceProfileID: UUID,
        sourcePath: String,
        destinationProfileID: UUID,
        destinationPath: String,
        overwrite: Bool,
        source: String,
        destination: String
    ) {
        id = UUID()
        self.fileName = fileName
        self.sourceProfileID = sourceProfileID
        self.sourcePath = sourcePath
        self.destinationProfileID = destinationProfileID
        self.destinationPath = destinationPath
        self.overwrite = overwrite
        self.source = source
        self.destination = destination
        state = .queued
        progress = 0
        transferredBytes = 0
    }
}

