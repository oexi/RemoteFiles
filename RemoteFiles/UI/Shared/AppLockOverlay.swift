import SwiftUI
import UIKit

/// Covers every window of the app while it is locked, and hides the content
/// from the app switcher snapshot while the lock is on.
///
/// The cover lives in its own window above the alert level so that sheets and
/// alerts presented by the app are covered too.
@MainActor
struct AppLockCoverModifier: ViewModifier {
    @ObservedObject var appLock: AppLockManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @State private var windows = AppLockWindows()

    private var coverVisible: Bool {
        appLock.isLocked || (appLock.isEnabled && scenePhase != .active)
    }

    func body(content: Content) -> some View {
        content
            .onAppear { update() }
            .onChange(of: coverVisible) { _, _ in update() }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    appLock.didEnterBackground()
                case .active:
                    appLock.willEnterForeground()
                    if appLock.isLocked { Task { await appLock.unlock() } }
                default:
                    break
                }
            }
    }

    private func update() {
        if coverVisible {
            // The cover window is outside this view tree, so pass the in-app language along.
            windows.show(AnyView(AppLockScreen(appLock: appLock).environment(\.locale, locale)))
        } else {
            windows.hide()
        }
    }
}

@MainActor
private final class AppLockWindows {
    private var windows: [UIWindow] = []

    func show(_ screen: AnyView) {
        guard windows.isEmpty else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            let host = UIHostingController(rootView: screen)
            host.view.backgroundColor = .systemBackground
            window.rootViewController = host
            window.isHidden = false
            windows.append(window)
        }
    }

    func hide() {
        windows.forEach { $0.isHidden = true }
        windows.removeAll()
    }
}

private struct AppLockScreen: View {
    @ObservedObject var appLock: AppLockManager

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("RemoteFiles")
                .font(.title2.weight(.semibold))
            if appLock.isLocked {
                Button("Unlock") {
                    Task { await appLock.unlock() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .task {
            if appLock.isLocked { await appLock.unlock() }
        }
    }
}
