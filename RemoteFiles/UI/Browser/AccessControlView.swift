import SwiftUI

struct AccessControlView: View {
    @Environment(\.dismiss) private var dismiss

    let provider: any RemoteFileProvider
    let item: RemoteItem

    @State private var info: RemoteAccessControlInfo?
    @State private var loading = true
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Item") {
                    LabeledContent("Name", value: item.name)
                    LabeledContent("Path", value: item.path)
                }

                if let info {
                    Section("Windows Security") {
                        LabeledContent("Owner SID", value: info.owner ?? "Unavailable")
                        LabeledContent("Group SID", value: info.group ?? "Unavailable")
                        LabeledContent("Inheritance", value: info.daclProtected ? "Protected" : "Inherited / inheritable")
                    }

                    Section("Access Control Entries") {
                        if info.entries.isEmpty {
                            Text("No DACL entries were returned by the SMB server.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(info.entries) { entry in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(entry.principal)
                                            .font(.subheadline.monospaced())
                                        Spacer()
                                        Text(entry.kind.rawValue.capitalized)
                                            .font(.caption)
                                            .foregroundStyle(entry.kind == .deny ? Color.red : Color.secondary)
                                    }
                                    Text(entry.rights.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 8) {
                                        Text(String(format: "0x%08X", entry.accessMask))
                                            .font(.caption2.monospaced())
                                        if entry.isInherited {
                                            Label("Inherited", systemImage: "arrow.down.right")
                                                .font(.caption2)
                                        }
                                    }
                                    .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }

                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Access Control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        message = nil
        do {
            info = try await provider.accessControl(path: item.path)
        } catch {
            message = error.localizedDescription
        }
        loading = false
    }
}
