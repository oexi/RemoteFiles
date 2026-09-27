import SwiftUI

struct ConnectionDiagnosticView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: ConnectionProfile
    let credential: Credential

    @State private var steps: [DiagnosticStep] = []
    @State private var running = true

    var body: some View {
        NavigationStack {
            List {
                if running && steps.isEmpty {
                    HStack { Spacer(); ProgressView("Diagnosing…"); Spacer() }
                }
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(step.status))
                            .foregroundStyle(color(step.status))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title).font(.headline)
                            Text(step.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                steps = await ConnectionDiagnosticService.run(profile: profile, credential: credential)
                running = false
            }
        }
    }

    private func color(_ status: DiagnosticStatus) -> Color {
        switch status {
        case .running: .secondary
        case .passed: .green
        case .failed: .red
        }
    }

    private func icon(_ status: DiagnosticStatus) -> String {
        switch status {
        case .running: "clock"
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }
}
