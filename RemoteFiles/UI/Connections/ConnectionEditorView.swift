import SwiftUI

struct ConnectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ConnectionProfile
    @State private var password: String
    @State private var testing = false
    @State private var testMessage: String?

    let onSave: (ConnectionProfile, Credential) -> Void

    init(profile: ConnectionProfile, onSave: @escaping (ConnectionProfile, Credential) -> Void) {
        _profile = State(initialValue: profile)
        _password = State(initialValue: (try? CredentialVault.shared.load(for: profile.id))?.password ?? "")
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    Picker("Protocol", selection: $profile.protocolType) {
                        ForEach(RemoteProtocol.allCases) { value in Text(value.title).tag(value) }
                    }
                    TextField("Name", text: $profile.name)
                    TextField(profile.protocolType == .webdav ? "Host or full WebDAV URL" : "Host", text: $profile.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", value: $profile.port, format: .number)
                        .keyboardType(.numberPad)
                }

                if profile.protocolType != .nfs {
                    Section("Authentication") {
                        TextField("Username", text: $profile.username)
                            .textInputAutocapitalization(.never)
                        SecureField("Password", text: $password)
                    }
                }

                if profile.protocolType == .smb {
                    Section("SMB") {
                        TextField("Share", text: $profile.share)
                        TextField("Domain (optional)", text: $profile.domain)
                    }
                }

                if profile.protocolType == .nfs {
                    Section("NFS") { TextField("Export", text: $profile.nfsExport) }
                }

                if profile.protocolType == .sftp {
                    Section("SSH Host Key") {
                        Text("The first host key is pinned automatically. Later key changes are blocked.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Reset Trusted Host Key", role: .destructive) {
                            SSHHostKeyStore().remove(host: profile.host, port: profile.port)
                            testMessage = "Trusted SSH host key reset. Verify the server before reconnecting."
                        }
                        .disabled(profile.host.isEmpty)
                    }
                }

                if profile.protocolType == .webdav {
                    Section("WebDAV") { Toggle("Use HTTPS", isOn: $profile.useTLS) }
                }

                if profile.protocolType != .webdav {
                    Section("Start") { TextField("Initial path", text: $profile.initialPath) }
                }

                Section {
                    Button(testing ? "Testing…" : "Test Connection") { Task { await testConnection() } }
                        .disabled(testing || profile.host.isEmpty)
                    if let testMessage { Text(testMessage).font(.footnote) }
                }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(profile, Credential(username: profile.username, password: password))
                        dismiss()
                    }
                    .disabled(profile.name.isEmpty || profile.host.isEmpty)
                }
            }
            .onChange(of: profile.protocolType) { oldValue, newValue in
                if profile.port == oldValue.defaultPort { profile.port = newValue.defaultPort }
                if profile.name == oldValue.title { profile.name = newValue.title }
            }
        }
    }

    private func testConnection() async {
        testing = true
        testMessage = nil
        do {
            let credential = Credential(username: profile.username, password: password)
            let provider = try ProviderFactory.make(for: profile, credential: credential)
            try await provider.connect()
            await provider.disconnect()
            testMessage = "Connection successful."
        } catch {
            testMessage = error.localizedDescription
        }
        testing = false
    }
}

