import Foundation
import XCTest
@testable import RemoteFiles

@MainActor
final class BrowserViewModelTests: XCTestCase {
    func testSupersededListingDoesNotReplaceNewerFolder() async throws {
        let provider = GatedListProvider()
        let model = BrowserViewModel(profile: rootProfile(), makeProvider: { _ in provider })
        await model.start()
        XCTAssertEqual(model.items.map(\.path), ["/fast", "/slow"])

        provider.gate("/slow")
        let slowNavigation = Task {
            await model.enter(RemoteItem(name: "slow", path: "/slow", kind: .directory))
        }
        await provider.waitUntilListing("/slow")
        // The previous folder's rows must not remain visible under the new path.
        XCTAssertEqual(model.currentPath, "/slow")
        XCTAssertTrue(model.items.isEmpty)

        await model.enter(RemoteItem(name: "fast", path: "/fast", kind: .directory))
        XCTAssertEqual(model.items.map(\.path), ["/fast/file.txt"])

        provider.release("/slow")
        await slowNavigation.value

        XCTAssertEqual(model.currentPath, "/fast")
        XCTAssertEqual(model.items.map(\.path), ["/fast/file.txt"])
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.errorMessage)
    }

    func testSupersededListingFailureIsNotReported() async throws {
        let provider = GatedListProvider()
        let model = BrowserViewModel(profile: rootProfile(), makeProvider: { _ in provider })
        await model.start()

        provider.gate("/slow", failing: true)
        let slowNavigation = Task {
            await model.enter(RemoteItem(name: "slow", path: "/slow", kind: .directory))
        }
        await provider.waitUntilListing("/slow")
        await model.enter(RemoteItem(name: "fast", path: "/fast", kind: .directory))
        provider.release("/slow")
        await slowNavigation.value

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.items.map(\.path), ["/fast/file.txt"])
    }

    func testRefreshReconnectsAfterInitialConnectionFailure() async throws {
        let provider = GatedListProvider(connectFailures: 1)
        let model = BrowserViewModel(profile: rootProfile(), makeProvider: { _ in provider })

        await model.start()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.provider)
        XCTAssertTrue(model.items.isEmpty)

        model.errorMessage = nil
        await model.refresh()

        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.provider)
        XCTAssertEqual(model.items.map(\.path), ["/fast", "/slow"])
        XCTAssertEqual(provider.connectAttempts, 2)
    }

    private func rootProfile() -> ConnectionProfile {
        var profile = ConnectionProfile.empty(for: .sftp)
        profile.initialPath = "/"
        return profile
    }
}

private enum GatedListError: Error {
    case connectFailed
    case listFailed
}

private final class GatedListProvider: RemoteFileProvider, @unchecked Sendable {
    let profile = ConnectionProfile.empty(for: .sftp)
    let capabilities = ProviderCapabilities.basicReadWrite

    private let lock = NSLock()
    private var remainingConnectFailures: Int
    private var attempts = 0
    private var gated: [String: Bool] = [:]
    private var started: Set<String> = []
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]

    init(connectFailures: Int = 0) {
        remainingConnectFailures = connectFailures
    }

    var connectAttempts: Int { lock.withLock { attempts } }

    func gate(_ path: String, failing: Bool = false) {
        lock.withLock { gated[path] = failing }
    }

    func release(_ path: String) {
        let continuation = lock.withLock { waiting.removeValue(forKey: path) }
        continuation?.resume()
    }

    func waitUntilListing(_ path: String) async {
        for _ in 0..<2_000 {
            if lock.withLock({ started.contains(path) }) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for a listing of \(path)")
    }

    func connect() async throws {
        let shouldFail = lock.withLock {
            attempts += 1
            guard remainingConnectFailures > 0 else { return false }
            remainingConnectFailures -= 1
            return true
        }
        if shouldFail { throw GatedListError.connectFailed }
    }

    func list(path: String) async throws -> [RemoteItem] {
        if let failing = lock.withLock({ gated[path] }) {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    waiting[path] = continuation
                    started.insert(path)
                }
            }
            if failing { throw GatedListError.listFailed }
        }
        switch path {
        case "/":
            return [
                RemoteItem(name: "fast", path: "/fast", kind: .directory),
                RemoteItem(name: "slow", path: "/slow", kind: .directory)
            ]
        case "/fast":
            return [RemoteItem(name: "file.txt", path: "/fast/file.txt", kind: .file)]
        case "/slow":
            return [RemoteItem(name: "stale.txt", path: "/slow/stale.txt", kind: .file)]
        default:
            return []
        }
    }

    func download(path: String, to localURL: URL) async throws { }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }
}
