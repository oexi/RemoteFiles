import Citadel
import SwiftUI

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
    @StateObject private var lanBrowser = LANServiceBrowser()
    @State private var resolvingServerID: String?
    /// Nearby servers are only offered while filling in a new connection.
    private let showsNearbyServers: Bool

    let onSave: (ConnectionProfile, Credential) throws -> Void

    init(profile: ConnectionProfile, onSave: @escaping (ConnectionProfile, Credential) throws -> Void) {
        let storedCredential = try? CredentialVault.shared.load(for: profile.id)
        _profile = State(initialValue: profile)
        _password = State(initialValue: storedCredential?.password ?? "")
        _privateKey = State(initialValue: storedCredential?.privateKey)
        _privateKeyName = State(initialValue: storedCredential?.privateKeyName)
        _privateKeyPassphrase = State(initialValue: storedCredential?.privateKeyPassphrase ?? "")
        showsNearbyServers = profile.host.isEmpty
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                if showsNearbyServers {
                    nearbyServersSection
                }

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
                            Button("Import SSH Private Key", systemImage: "key") {
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

                if usesTLS {
                    Section {
                        Toggle("Verify TLS Certificate", isOn: $profile.verifyTLS)
                        if !profile.verifyTLS && profile.protocolType == .webdav {
                            Button("Forget Trusted Certificate", role: .destructive) {
                                forgetTrustedCertificate()
                            }
                            .disabled(profile.host.isEmpty)
                        }
                    } header: {
                        Text("TLS Certificate")
                    } footer: {
                        Text(tlsFooter)
                    }
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
                        do {
                            try validateForSave()
                            try onSave(profile, Credential(
                                username: profile.username,
                                password: password,
                                privateKey: privateKey,
                                privateKeyName: privateKeyName,
                                privateKeyPassphrase: privateKeyPassphrase.isEmpty ? nil : privateKeyPassphrase
                            ))
                            dismiss()
                        } catch {
                            testMessage = error.localizedDescription
                        }
                    }
                    .disabled(profile.name.isEmpty || profile.host.isEmpty)
                }
            }
            .task {
                if showsNearbyServers { lanBrowser.start() }
            }
            .onDisappear { lanBrowser.stop() }
            .onChange(of: profile.protocolType) { oldValue, newValue in
                if profile.port == oldValue.defaultPort { profile.port = newValue.defaultPort }
                if profile.name == oldValue.title { profile.name = newValue.title }
            }
            .sheet(isPresented: $showingPrivateKeyImporter) {
                SystemDocumentPicker(
                    mode: .privateKey,
                    onPick: { urls in
                        showingPrivateKeyImporter = false
                        guard let url = urls.first else { return }
                        importPrivateKey(from: url)
                    },
                    onCancel: {
                        showingPrivateKeyImporter = false
                    }
                )
                .ignoresSafeArea()
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

    private var usesTLS: Bool {
        switch profile.protocolType {
        case .ftps:
            return true
        case .webdav:
            let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if host.hasPrefix("https://") { return true }
            if host.hasPrefix("http://") { return false }
            return profile.useTLS
        default:
            return false
        }
    }

    private var tlsFooter: LocalizedStringKey {
        if profile.verifyTLS {
            return "Only certificates trusted by iOS are accepted."
        }
        if profile.protocolType == .ftps {
            return "Any certificate is accepted, including self-signed ones. Use this only on a network you trust."
        }
        return "Self-signed certificates are accepted. The first certificate is remembered, and a different certificate later blocks the connection."
    }

    private func forgetTrustedCertificate() {
        do {
            let endpoint = try WebDAVProvider(profile: profile, credential: nil).trustEndpoint()
            TLSCertificatePinStore().remove(host: endpoint.host, port: endpoint.port)
            testMessage = String(localized: "Trusted certificate forgotten. Verify the server before reconnecting.")
        } catch {
            testMessage = error.localizedDescription
        }
    }

    private func importPrivateKey(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1024 * 1024 else {
                throw RemoteProviderError.invalidConfiguration("The private key file is unexpectedly large.")
            }
            guard let keyString = String(data: data, encoding: .utf8) else {
                throw RemoteProviderError.invalidConfiguration("The private key must be UTF-8 text.")
            }
            _ = try SSHPrivateKeyLoader.detectKind(keyString)
            privateKey = data
            privateKeyName = url.lastPathComponent
            testMessage = "Private key imported. Test the connection before saving."
        } catch {
            testMessage = error.localizedDescription
        }
    }

    private func validateForSave() throws {
        guard profile.protocolType == .webdav else { return }
        let input = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBase: String
        if input.contains("://") {
            rawBase = input
        } else {
            let scheme = profile.useTLS ? "https" : "http"
            let defaultPort = profile.useTLS ? 443 : 80
            rawBase = "\(scheme)://\(input)" + (profile.port == defaultPort ? "" : ":\(profile.port)")
        }
        guard let parts = URLComponents(string: rawBase),
              let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              parts.host?.isEmpty == false else {
            throw RemoteProviderError.invalidConfiguration("Invalid WebDAV server URL.")
        }
        guard parts.user == nil, parts.password == nil else {
            throw RemoteProviderError.invalidConfiguration(
                "Do not embed WebDAV credentials in the server URL. Use the Username and Password fields instead."
            )
        }
        guard parts.query == nil, parts.fragment == nil else {
            throw RemoteProviderError.invalidConfiguration("WebDAV server URL must not contain a query or fragment.")
        }
    }

    private var nearbyServersSection: some View {
        Section {
            if lanBrowser.servers.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching the local network…")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(lanBrowser.servers) { server in
                    Button {
                        Task { await useNearbyServer(server) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: server.protocolType.systemImage)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                Text(server.useTLS ? "\(server.protocolType.title) (HTTPS)" : server.protocolType.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if resolvingServerID == server.id {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(resolvingServerID != nil)
                }
            }
        } header: {
            Text("Nearby Servers")
        }
    }

    private func useNearbyServer(_ server: DiscoveredServer) async {
        resolvingServerID = server.id
        defer { resolvingServerID = nil }
        do {
            let resolved = try await lanBrowser.resolve(server)
            let previousTitle = profile.protocolType.title
            profile.protocolType = server.protocolType
            profile.host = resolved.host
            profile.port = resolved.port
            if server.protocolType == .webdav { profile.useTLS = server.useTLS }
            if profile.name.isEmpty || profile.name == previousTitle {
                profile.name = server.name
            }
        } catch is CancellationError {
            return
        } catch {
            testMessage = error.localizedDescription
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

