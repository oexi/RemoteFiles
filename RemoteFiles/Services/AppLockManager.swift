import Combine
import LocalAuthentication
import SwiftUI

protocol DeviceAuthenticating: Sendable {
    func canAuthenticate() -> Bool
    func authenticate(reason: String) async -> Bool
}

/// Face ID or Touch ID, falling back to the device passcode.
struct LocalDeviceAuthenticator: DeviceAuthenticating {
    func canAuthenticate() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func authenticate(reason: String) async -> Bool {
        do {
            return try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

enum AppLockTimeout: Int, CaseIterable, Identifiable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .immediately: "Immediately"
        case .oneMinute: "After 1 Minute"
        case .fiveMinutes: "After 5 Minutes"
        case .fifteenMinutes: "After 15 Minutes"
        }
    }
}

/// Requires device authentication to open the app. Locking only covers the UI;
/// transfers keep running underneath.
@MainActor
final class AppLockManager: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isLocked: Bool
    @Published var timeout: AppLockTimeout {
        didSet { defaults.set(timeout.rawValue, forKey: AppPreferenceKey.appLockTimeout) }
    }

    private let defaults: UserDefaults
    private let authenticator: any DeviceAuthenticating
    private let now: () -> Date
    private var backgroundedAt: Date?
    private var authenticating = false

    init(
        defaults: UserDefaults = .standard,
        authenticator: any DeviceAuthenticating = LocalDeviceAuthenticator(),
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.authenticator = authenticator
        self.now = now
        let enabled = defaults.bool(forKey: AppPreferenceKey.appLockEnabled)
        isEnabled = enabled
        isLocked = enabled
        timeout = AppLockTimeout(rawValue: defaults.integer(forKey: AppPreferenceKey.appLockTimeout)) ?? .immediately
    }

    var canAuthenticate: Bool { authenticator.canAuthenticate() }

    static func shouldLock(backgroundedAt: Date, now: Date, timeout: AppLockTimeout) -> Bool {
        now.timeIntervalSince(backgroundedAt) >= TimeInterval(timeout.rawValue)
    }

    func didEnterBackground() {
        guard isEnabled, !isLocked else { return }
        backgroundedAt = now()
    }

    func willEnterForeground() {
        defer { backgroundedAt = nil }
        guard isEnabled, let backgroundedAt else { return }
        if Self.shouldLock(backgroundedAt: backgroundedAt, now: now(), timeout: timeout) {
            isLocked = true
        }
    }

    func unlock() async {
        guard isLocked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        if await authenticator.authenticate(reason: String(localized: "Unlock RemoteFiles")) {
            isLocked = false
        }
    }

    /// Turning the lock on or off both require authentication, so it cannot be bypassed.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let reason = enabled
            ? String(localized: "Turn on the app lock")
            : String(localized: "Turn off the app lock")
        guard await authenticator.authenticate(reason: reason) else { return }
        isEnabled = enabled
        isLocked = false
        defaults.set(enabled, forKey: AppPreferenceKey.appLockEnabled)
    }
}
