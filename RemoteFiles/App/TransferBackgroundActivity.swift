import Combine
import Foundation
import UIKit
import UserNotifications

/// Keeps transfers running briefly after the app moves to the background and
/// tells the user when they finish there.
///
/// iOS grants a limited amount of background time (typically a few minutes at
/// most); when it runs out, unfinished transfers stop with the app and can be
/// resumed or retried from the Transfers tab.
@MainActor
final class TransferBackgroundActivity: ObservableObject {
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var cancellable: AnyCancellable?
    private var previousStates: [UUID: TransferState] = [:]
    private var requestedAuthorization = false

    func attach(to engine: TransferEngine) {
        guard cancellable == nil else { return }
        previousStates = Dictionary(uniqueKeysWithValues: engine.records.map { ($0.id, $0.state) })
        cancellable = engine.$records.sink { [weak self] records in
            self?.recordsChanged(records)
        }
    }

    private func recordsChanged(_ records: [TransferRecord]) {
        let active = records.contains { $0.state == .running || $0.state == .queued }
        if active {
            beginBackgroundTask()
            requestNotificationAuthorizationIfNeeded()
        }

        if UIApplication.shared.applicationState != .active {
            for record in records {
                guard let previous = previousStates[record.id],
                      previous == .running || previous == .queued,
                      record.state == .completed || record.state == .failed else { continue }
                notify(record)
            }
        }
        previousStates = Dictionary(records.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })

        if !active { endBackgroundTask() }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "RemoteFiles transfers") { [weak self] in
            // The expiration handler runs on the main thread and must end the
            // task before returning, or iOS terminates the app.
            MainActor.assumeIsolated {
                self?.backgroundTimeExpired()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func backgroundTimeExpired() {
        post(
            title: String(localized: "Transfers paused"),
            body: String(localized: "iOS suspended RemoteFiles. Open the app to resume or retry unfinished transfers.")
        )
        endBackgroundTask()
    }

    private func requestNotificationAuthorizationIfNeeded() {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ record: TransferRecord) {
        if record.state == .completed {
            post(title: String(localized: "Transfer complete"), body: record.fileName)
        } else {
            post(title: String(localized: "Transfer failed"), body: record.fileName)
        }
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
