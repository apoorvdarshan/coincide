import AppKit
import CoincideKit
import UserNotifications

/// Posts a system notification when a turn ends or an agent asks for approval while Coincide is in
/// the background (`AppSettings.notifyWhenInBackground`), and opens the thread when one is clicked.
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationController()

    private enum Kind: String {
        case approval
        case completed
        case failed
    }

    private var center: UNUserNotificationCenter { .current() }

    func start() {
        center.delegate = self
        let runner = ThreadRunner.shared
        // Keep any handler installed before ours.
        let previousFinished = runner.onTurnFinished
        runner.onTurnFinished = { [weak self] threadID, outcome in
            previousFinished?(threadID, outcome)
            ThreadActivity.shared.turnFinished(threadID, outcome: outcome)
            self?.turnFinished(threadID, outcome: outcome)
        }
        let previousApproval = runner.onApprovalRequested
        runner.onApprovalRequested = { [weak self] threadID, request in
            previousApproval?(threadID, request)
            self?.approvalRequested(threadID, request: request)
        }
    }

    /// Clears delivered notifications for a thread the user is now looking at.
    func clearDelivered(for threadID: UUID) {
        let ids = [Kind.approval, .completed, .failed].map { identifier(threadID, $0) }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    // MARK: Events

    private func turnFinished(_ threadID: UUID, outcome: TurnOutcome) {
        switch outcome {
        case .completed:
            post(.completed, threadID: threadID, title: String(localized: "Thread completed"), body: nil)
        case .failed(let message):
            post(.failed, threadID: threadID, title: String(localized: "Thread failed"), body: message)
        case .interrupted:
            break
        }
    }

    private func approvalRequested(_ threadID: UUID, request: ApprovalRequest) {
        post(.approval, threadID: threadID, title: String(localized: "Approval needed"), body: request.title)
    }

    private func post(_ kind: Kind, threadID: UUID, title: String, body: String?) {
        let store = AppStore.shared
        guard store.settings.notifyWhenInBackground, !NSApp.isActive, let thread = store.thread(threadID),
            !thread.isArchived
        else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let body, !body.isEmpty {
            content.subtitle = thread.title
            content.body = String(body.prefix(240))
        } else {
            content.body = thread.title
        }
        content.sound = .default
        content.threadIdentifier = threadID.uuidString
        content.userInfo = ["threadID": threadID.uuidString]
        let request = UNNotificationRequest(identifier: identifier(threadID, kind), content: content, trigger: nil)
        let center = center
        Task {
            guard await Self.isAuthorized(center) else { return }
            try? await center.add(request)
        }
    }

    private func identifier(_ threadID: UUID, _ kind: Kind) -> String { "\(threadID.uuidString).\(kind.rawValue)" }

    /// Asks for permission the first time a notification is due, rather than at launch.
    private static func isAuthorized(_ center: UNUserNotificationCenter) async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Coincide is in front; the sidebar and toolbar already show the change.
        []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let value = response.notification.request.content.userInfo["threadID"] as? String,
            let threadID = UUID(uuidString: value)
        else { return }
        await MainActor.run {
            NSApp.activate()
            AppEvents.openThread(threadID)
        }
    }
}
