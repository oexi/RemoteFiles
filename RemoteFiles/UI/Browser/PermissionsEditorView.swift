import Foundation
import SwiftUI

struct PermissionsEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let provider: any RemoteFileProvider
    let item: RemoteItem

    @State private var modeText = ""
    @State private var loading = true
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Item") {
                    LabeledContent("Name", value: item.name)
                    LabeledContent("Path", value: item.path)
                }

                Section {
                    TextField("Octal mode", text: $modeText)
                        .keyboardType(.numberPad)
                        .fontDesign(.monospaced)
                    if let mode = parsedMode {
                        LabeledContent("Symbolic", value: symbolic(mode))
                    }
                    HStack {
                        Button("0644") { modeText = "0644" }
                        Spacer()
                        Button("0755") { modeText = "0755" }
                        Spacer()
                        Button("0600") { modeText = "0600" }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Unix Permissions")
                } footer: {
                    Text("Enter an octal Unix mode from 0000 to 7777. The server may reject permission changes for files you do not own or when its permission extension is read-only.")
                }

                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(loading || saving || parsedMode == nil)
                }
            }
            .task { await load() }
        }
    }

    private var parsedMode: UInt32? {
        let trimmed = modeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 4,
              trimmed.allSatisfy({ $0 >= "0" && $0 <= "7" }),
              let value = UInt32(trimmed, radix: 8), value <= 0o7777 else { return nil }
        return value
    }

    private func load() async {
        do {
            let refreshed = try await provider.attributes(path: item.path)
            guard let mode = refreshed.permissions ?? item.permissions else {
                throw RemoteProviderError.unsupported("This server did not return Unix permission bits for the item.")
            }
            modeText = String(format: "%04o", mode & 0o7777)
        } catch {
            message = error.localizedDescription
        }
        loading = false
    }

    private func save() async {
        guard let mode = parsedMode else { return }
        saving = true
        message = nil
        do {
            try await provider.setPermissions(path: item.path, permissions: mode)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
        saving = false
    }

    private func symbolic(_ mode: UInt32) -> String {
        var chars: [Character] = [
            mode & 0o400 != 0 ? "r" : "-",
            mode & 0o200 != 0 ? "w" : "-",
            mode & 0o100 != 0 ? "x" : "-",
            mode & 0o040 != 0 ? "r" : "-",
            mode & 0o020 != 0 ? "w" : "-",
            mode & 0o010 != 0 ? "x" : "-",
            mode & 0o004 != 0 ? "r" : "-",
            mode & 0o002 != 0 ? "w" : "-",
            mode & 0o001 != 0 ? "x" : "-"
        ]
        if mode & 0o4000 != 0 { chars[2] = mode & 0o100 != 0 ? "s" : "S" }
        if mode & 0o2000 != 0 { chars[5] = mode & 0o010 != 0 ? "s" : "S" }
        if mode & 0o1000 != 0 { chars[8] = mode & 0o001 != 0 ? "t" : "T" }
        return String(chars)
    }
}
