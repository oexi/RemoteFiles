import Foundation
import Network

enum DiagnosticStatus: String, Sendable {
    case running, passed, failed
}

struct DiagnosticStep: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let status: DiagnosticStatus
    let detail: String
}

enum ConnectionDiagnosticService {
    static func run(profile: ConnectionProfile, credential: Credential) async -> [DiagnosticStep] {
        var steps: [DiagnosticStep] = []

        guard !profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65535).contains(profile.port) else {
            return [DiagnosticStep(title: "Configuration", status: .failed, detail: "Host or port is invalid.")]
        }
        steps.append(.init(title: "Configuration", status: .passed, detail: "\(profile.host):\(profile.port)"))

        do {
            let latency = try await tcpProbe(host: profile.host, port: profile.port)
            steps.append(.init(
                title: "Network",
                status: .passed,
                detail: String(format: "DNS/TCP reachable in %.0f ms", latency * 1000)
            ))
        } catch {
            steps.append(.init(title: "Network", status: .failed, detail: error.localizedDescription))
            return steps
        }

        do {
            let provider = try ProviderFactory.make(for: profile, credential: credential)
            try await provider.connect()
            steps.append(.init(title: "Authentication", status: .passed, detail: "Protocol session established."))

            do {
                let path = RemotePath.normalize(profile.protocolType == .nfs ? profile.initialPath : profile.initialPath)
                let items = try await provider.list(path: path)
                steps.append(.init(
                    title: "Directory Access",
                    status: .passed,
                    detail: "Read \(items.count) item\(items.count == 1 ? "" : "s") from \(path)."
                ))
            } catch {
                steps.append(.init(title: "Directory Access", status: .failed, detail: error.localizedDescription))
            }

            let capabilities = provider.capabilities.values.map(\.rawValue).sorted().joined(separator: ", ")
            steps.append(.init(
                title: "Capabilities",
                status: .passed,
                detail: capabilities.isEmpty ? "Read-only/basic provider" : capabilities
            ))
            await provider.disconnect()
        } catch {
            steps.append(.init(title: "Authentication", status: .failed, detail: error.localizedDescription))
        }
        return steps
    }

    private static func tcpProbe(host: String, port: Int) async throws -> TimeInterval {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw RemoteProviderError.invalidConfiguration("Invalid TCP port.")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let gate = ContinuationGate()
        let started = Date()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.runOnce {
                            continuation.resume(returning: Date().timeIntervalSince(started))
                            connection.cancel()
                        }
                    case .failed(let error):
                        gate.runOnce { continuation.resume(throwing: error) }
                    case .cancelled:
                        gate.runOnce { continuation.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                connection.start(queue: DispatchQueue(label: "RemoteFiles.ConnectionDiagnostic"))
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
                    gate.runOnce {
                        connection.cancel()
                        continuation.resume(throwing: URLError(.timedOut))
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func runOnce(_ action: () -> Void) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        action()
    }
}
