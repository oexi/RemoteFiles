import Citadel
import SwiftUI
import UniformTypeIdentifiers

struct ConnectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ConnectionProfile
    @State private var password: String
    @State private var privateKey: Data?
    @State private var privateKeyName: String?
    @State private var privateKeyPassphrase: String
    @State private var showingPrivateKeyImporter = false
    @State private var showingDiagnostics = false
    @State private var testing = false
    @State private var testMessage: String?

    let onSave: (ConnectionProfile, Credential) -> Void

    init(profile: ConnectionProfile, onSave: @escaping (ConnectionProfile, Credential) -> Void) {
        let storedCredential = try? CredentialVault.shared.load(for: profile.id)
        _profile = State(initialValue: profile)
        _password = State(initialValue: storedCredential?.password ?? "")
        _privateKey = State(initialValue: storedCredential?.privateKey)
        _privateKeyName = State(initialValue: storedCredential?.privateKeyName)
        _privateKeyPassphrase = State(initialValue: storedCredential?.privateKeyPassphrase ?? "")
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

                if profile.protocolType == .sftp {
                    Section("Authentication") {
                        TextField("Username", text: $profile.username)
                            .textInputAutocapitalization(.never)

                        if privateKey == nil {
                            SecureField("Password", text: $password)
                            Button("Import OpenSSH Private Key", systemImage: "key") {
                                showingPrivateKeyImporter = true
                            }
                        } else {
                            LabeledContent("Private Key", value: privateKeyName ?? "Imported key")
                            SecureField("Key Passphrase (optional)", text: $privateKeyPassphrase)
                            Button("Replace Private Key", systemImage: "arrow.triangle.2.circlepath") {
                                showingPrivateKeyImporter = true
                            }
                            Button("Remove Private Key", role: .destructive) {
                                privateKey = nil
                                privateKeyName = nil
                                privateKeyPassphrase = ""
                            }
                        }
                    }
                } else if profile.protocolType != .nfs {
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
                    Button("Run Diagnostics", systemImage: "stethoscope") {
                        showingDiagnostics = true
                    }
                    .disabled(profile.host.isEmpty)
                    if let testMessage { Text(testMessage).font(.footnote) }
                }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(profile, Credential(
                            username: profile.username,
                            password: password,
                            privateKey: privateKey,
                            privateKeyName: privateKeyName,
                            privateKeyPassphrase: privateKeyPassphrase.isEmpty ? nil : privateKeyPassphrase
                        ))
                        dismiss()
                    }
                    .disabled(profile.name.isEmpty || profile.host.isEmpty)
                }
            }
            .onChange(of: profile.protocolType) { oldValue, newValue in
                if profile.port == oldValue.defaultPort { profile.port = newValue.defaultPort }
                if profile.name == oldValue.title { profile.name = newValue.title }
            }
            .fileImporter(
                isPresented: $showingPrivateKeyImporter,
                allowedContentTypes: [.data, .plainText],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    guard data.count <= 1024 * 1024 else {
                        throw RemoteProviderError.invalidConfiguration("The private key file is unexpectedly large.")
                    }
                    guard let keyString = String(data: data, encoding: .utf8) else {
                        throw RemoteProviderError.invalidConfiguration("The private key must be UTF-8 text.")
                    }
                    _ = try SSHKeyDetection.detectPrivateKeyType(from: keyString)
                    privateKey = data
                    privateKeyName = url.lastPathComponent
                    testMessage = "Private key imported. Test the connection before saving."
                } catch {
                    testMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showingDiagnostics) {
                ConnectionDiagnosticView(
                    profile: profile,
                    credential: Credential(
                        username: profile.username,
                        password: password,
                        privateKey: privateKey,
                        privateKeyName: privateKeyName,
                        privateKeyPassphrase: privateKeyPassphrase.isEmpty ? nil : privateKeyPassphrase
                    )
                )
            }
        }
    }

    private func testConnection() async {
        testing = true
        testMessage = nil
        do {
            let credential = Credential(
                username: profile.username,
                password: password,
                privateKey: privateKey,
                privateKeyName: privateKeyName,
                privateKeyPassphrase: privateKeyPassphrase.isEmpty ? nil : privateKeyPassphrase
            )
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

