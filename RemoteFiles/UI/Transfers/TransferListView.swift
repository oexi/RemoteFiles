import SwiftUI

struct TransferListView: View {
    @EnvironmentObject private var engine: TransferEngine
    @EnvironmentObject private var connections: ConnectionStore

    var body: some View {
        let active = engine.records.filter { Self.isActive($0.state) }
        let finished = engine.records.filter { !Self.isActive($0.state) }
        return NavigationStack {
            List {
                if !active.isEmpty {
                    Section("Active") {
                        ForEach(active) { record in transferRow(record) }
                    }
                }
                if !finished.isEmpty {
                    Section("Finished") {
                        ForEach(finished) { record in transferRow(record) }
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
                Button("Clear") { engine.clearFinished(using: connections) }
                    .accessibilityLabel("Clear Finished")
                    .disabled(!engine.records.contains(where: { $0.state == .completed || $0.state == .cancelled }))
            }
        }
    }

    /// Transfers that are still under way or waiting to be resumed.
    static func isActive(_ state: TransferState) -> Bool {
        state == .queued || state == .running || state == .paused
    }

    private func transferRow(_ record: TransferRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: record))
                .font(.title2)
                .foregroundStyle(tint(for: record.state))
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(record.fileName).font(.headline).lineLimit(1)
                    Spacer()
                    if record.state == .running {
                        Text(verbatim: "\(Int((record.progress * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(stateTitle(for: record.state))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tint(for: record.state))
                }
                if record.state != .completed {
                    ProgressView(value: record.progress)
                        .tint(tint(for: record.state))
                }
                if let transferred = record.transferredBytes,
                   transferred > 0 || record.state == .running {
                    HStack(spacing: 4) {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: transferred), countStyle: .file))
                        if let total = record.totalBytes, total > 0 {
                            Text("of")
                            Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                        }
                        if let speed = record.bytesPerSecond, speed > 0, record.state == .running {
                            Text(verbatim: "·")
                            Text(verbatim: "\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s")
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Text(operationTitle(for: record))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(verbatim: "\(record.source) → \(record.destination)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let error = record.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            if canPause(record) || canResume(record) || canRetry(record) {
                transferControl(for: record)
                    .font(.title2)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if record.state == .running || record.state == .queued {
                if record.commitPending != true {
                    Button(role: .destructive) { engine.cancel(record) } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                }
                if canPause(record) {
                    Button { engine.pause(record) } label: {
                        Label("Pause", systemImage: "pause")
                    }
                    .tint(.orange)
                }
            } else if canResume(record) {
                Button(role: .destructive) { engine.remove(record, using: connections) } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button { engine.resume(record, using: connections) } label: {
                    Label("Resume", systemImage: "play")
                }
                .tint(.blue)
            } else if canRetry(record) {
                Button(role: .destructive) { engine.remove(record, using: connections) } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button { engine.retry(record, using: connections) } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
            } else if canDelete(record) {
                Button(role: .destructive) { engine.remove(record, using: connections) } label: {
                    Label("Delete", systemImage: "trash")
                }
            } else if record.state == .completed {
                Button(role: .destructive) { engine.remove(record, using: connections) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func tint(for state: TransferState) -> Color {
        switch state {
        case .queued, .cancelled: .secondary
        case .running: .accentColor
        case .paused: .orange
        case .completed: .green
        case .failed: .red
        }
    }

    @ViewBuilder
    private func transferControl(for record: TransferRecord) -> some View {
        if canPause(record) {
            Button { engine.pause(record) } label: {
                Image(systemName: "pause.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.orange)
            .accessibilityLabel(controlTitle(for: record))
        } else if canResume(record) {
            Button { engine.resume(record, using: connections) } label: {
                Image(systemName: "play.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.blue)
            .accessibilityLabel(controlTitle(for: record))
        } else if canRetry(record) {
            Button { engine.retry(record, using: connections) } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.blue)
            .accessibilityLabel(controlTitle(for: record))
        }
    }

    private func canPause(_ record: TransferRecord) -> Bool {
        record.commitPending != true
            && record.supportsResuming
            && (record.state == .running || record.state == .queued)
    }

    private func canResume(_ record: TransferRecord) -> Bool {
        guard record.supportsResuming else { return false }
        if record.state == .paused {
            return true
        }
        return record.operationKind == .serverToServer
            && (record.state == .failed || record.state == .cancelled)
    }

    private func canRetry(_ record: TransferRecord) -> Bool {
        engine.canRetry(record)
    }

    private func canDelete(_ record: TransferRecord) -> Bool {
        record.state == .paused || record.state == .failed || record.state == .cancelled
    }

    private func controlTitle(for record: TransferRecord) -> LocalizedStringKey {
        if canPause(record) {
            return "Pause"
        }
        if canResume(record) {
            return "Resume"
        }
        return "Retry"
    }

    private func icon(for record: TransferRecord) -> String {
        switch record.state {
        case .queued: return "clock.fill"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
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
        case .paused: "Paused"
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
