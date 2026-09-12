import SwiftUI

struct TransferListView: View {
    @EnvironmentObject private var engine: TransferEngine
    @EnvironmentObject private var connections: ConnectionStore

    var body: some View {
        NavigationStack {
            List(engine.records) { record in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Image(systemName: icon(for: record.state))
                        Text(record.fileName).font(.headline).lineLimit(1)
                        Spacer()
                        Text(record.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: record.progress)
                    if let transferred = record.transferredBytes, transferred > 0 {
                        HStack(spacing: 4) {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: transferred), countStyle: .file))
                            if let total = record.totalBytes, total > 0 {
                                Text("of")
                                Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
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
                        Button { engine.retry(record, using: connections) } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .tint(.blue)
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

    private func icon(for state: TransferState) -> String {
        switch state {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }
}

