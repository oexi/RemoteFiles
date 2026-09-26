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
    /// Transfers that finished while the app was in the background, reported
    /// together once everything is done instead of one notification each.
    private var finishedInBackground: (completed: Int, failed: Int, lastName: String?) = (0, 0, nil)

    func attach(to engine: TransferEngine) {
        guard cancellable == nil else { return }
        previousStates = Dictionary(uniqueKeysWithValues: engine.records.map { ($0.id, $0.state) })
        cancellable = engine.$records.combineLatest(engine.$activeBatches).sink { [weak self] records, batches in
            self?.transfersChanged(records, activeBatches: batches)
        }
    }

    private func transfersChanged(_ records: [TransferRecord], activeBatches: Int) {
        // A folder upload or copy has no active record between two files;
        // the batch counter keeps it active for its whole run.
        let active = activeBatches > 0 || records.contains { $0.state == .running || $0.state == .queued }
        if active {
            beginBackgroundTask()
            requestNotificationAuthorizationIfNeeded()
        }

        if UIApplication.shared.applicationState == .active {
            finishedInBackground = (0, 0, nil)
        } else {
            for record in records {
                guard let previous = previousStates[record.id],
                      previous == .running || previous == .queued else { continue }
                if record.state == .completed {
                    finishedInBackground.completed += 1
                    finishedInBackground.lastName = record.fileName
                } else if record.state == .failed {
                    finishedInBackground.failed += 1
                    finishedInBackground.lastName = record.fileName
                }
            }
        }
        previousStates = Dictionary(records.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })

        if !active {
            notifyFinished()
            endBackgroundTask()
        }
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
        notifyFinished()
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

    private func notifyFinished() {
        let (completed, failed, lastName) = finishedInBackground
        finishedInBackground = (0, 0, nil)
        switch (completed, failed) {
        case (0, 0):
            return
        case (1, 0):
            post(title: String(localized: "Transfer complete"), body: lastName ?? "")
        case (0, 1):
            post(title: String(localized: "Transfer failed"), body: lastName ?? "")
        case (_, 0):
            post(
                title: String(localized: "Transfers complete"),
                body: String(localized: "\(completed) transfers completed.")
            )
        default:
            post(
                title: String(localized: "Transfers finished"),
                body: String(localized: "\(completed) completed, \(failed) failed. See Transfers for details.")
            )
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
