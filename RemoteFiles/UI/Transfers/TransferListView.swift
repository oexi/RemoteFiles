import SwiftUI

struct TransferListView: View {
    @EnvironmentObject private var engine: TransferEngine
    @EnvironmentObject private var connections: ConnectionStore

    var body: some View {
        NavigationStack {
            List(engine.records) { record in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Image(systemName: icon(for: record))
                        Text(record.fileName).font(.headline).lineLimit(1)
                        Spacer()
                        if record.state == .running {
                            Text("\(Int((record.progress * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(stateTitle(for: record.state)).font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: record.progress)
                    if let transferred = record.transferredBytes,
                       transferred > 0 || record.state == .running {
                        HStack(spacing: 4) {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: transferred), countStyle: .file))
                            if let total = record.totalBytes, total > 0 {
                                Text("of")
                                Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                            }
                            if let speed = record.bytesPerSecond, speed > 0, record.state == .running {
                                Text("·")
                                Text("\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Text(operationTitle(for: record))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("\(record.source) → \(record.destination)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let error = record.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 4)
                .swipeActions(edge: .trailing) {
                    if record.state == .running || record.state == .queued {
                        Button(role: .destructive) { engine.cancel(record) } label: {
                            Label("Cancel", systemImage: "xmark")
                        }
                    } else if record.state == .failed || record.state == .cancelled {
                        Button(role: .destructive) { engine.remove(record) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        if record.operationKind == .serverToServer {
                            Button { engine.retry(record, using: connections) } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                            .tint(.blue)
                        }
                    } else if record.state == .completed {
                        Button(role: .destructive) { engine.remove(record) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .overlay {
                if engine.records.isEmpty {
                    ContentUnavailableView("No Transfers", systemImage: "arrow.up.arrow.down", description: Text("Cross-server and upload/download jobs will appear here."))
                }
            }
            .navigationTitle("Transfers")
            .toolbar {
                Button("Clear Finished") { engine.clearFinished() }
                    .disabled(!engine.records.contains(where: { $0.state == .completed || $0.state == .cancelled }))
            }
        }
    }

    private func icon(for record: TransferRecord) -> String {
        switch record.state {
        case .queued: return "clock"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle"
        case .running:
            switch record.operationKind {
            case .upload: return "arrow.up.circle.fill"
            case .download: return "arrow.down.circle.fill"
            case .serverToServer: return "arrow.left.arrow.right.circle.fill"
            }
        }
    }

    private func stateTitle(for state: TransferState) -> LocalizedStringKey {
        switch state {
        case .queued: "Queued"
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private func operationTitle(for record: TransferRecord) -> LocalizedStringKey {
        switch record.operationKind {
        case .serverToServer: "Server to Server"
        case .upload: "Upload"
        case .download: "Download / Keep Offline"
        }
    }
}

