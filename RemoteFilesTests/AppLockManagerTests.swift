import XCTest
@testable import RemoteFiles

@MainActor
final class AppLockManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppLockManagerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTimeoutDecision() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(AppLockManager.shouldLock(backgroundedAt: start, now: start, timeout: .immediately))
        XCTAssertFalse(AppLockManager.shouldLock(backgroundedAt: start, now: start.addingTimeInterval(59), timeout: .oneMinute))
        XCTAssertTrue(AppLockManager.shouldLock(backgroundedAt: start, now: start.addingTimeInterval(60), timeout: .oneMinute))
    }

    func testEnablingRequiresAuthenticationAndPersists() async {
        let authenticator = FakeAuthenticator(result: false)
        let manager = AppLockManager(defaults: defaults, authenticator: authenticator)

        await manager.setEnabled(true)
        XCTAssertFalse(manager.isEnabled)

        authenticator.result = true
        await manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertFalse(manager.isLocked)

        let relaunched = AppLockManager(defaults: defaults, authenticator: authenticator)
        XCTAssertTrue(relaunched.isEnabled)
        XCTAssertTrue(relaunched.isLocked, "An enabled lock starts locked on launch")
    }

    func testLocksOnlyAfterTimeoutInBackground() async {
        let authenticator = FakeAuthenticator(result: true)
        var clock = Date(timeIntervalSince1970: 1_000)
        let manager = AppLockManager(defaults: defaults, authenticator: authenticator, now: { clock })
        await manager.setEnabled(true)
        manager.timeout = .fiveMinutes

        manager.didEnterBackground()
        clock.addTimeInterval(120)
        manager.willEnterForeground()
        XCTAssertFalse(manager.isLocked)

        manager.didEnterBackground()
        clock.addTimeInterval(300)
        manager.willEnterForeground()
        XCTAssertTrue(manager.isLocked)
    }

    func testFailedUnlockStaysLocked() async {
        defaults.set(true, forKey: AppPreferenceKey.appLockEnabled)
        let authenticator = FakeAuthenticator(result: false)
        let manager = AppLockManager(defaults: defaults, authenticator: authenticator)

        await manager.unlock()
        XCTAssertTrue(manager.isLocked)

        authenticator.result = true
        await manager.unlock()
        XCTAssertFalse(manager.isLocked)
    }
}

private final class FakeAuthenticator: DeviceAuthenticating, @unchecked Sendable {
    var result: Bool

    init(result: Bool) { self.result = result }

    func canAuthenticate() -> Bool { true }
    func authenticate(reason: String) async -> Bool { result }
}
