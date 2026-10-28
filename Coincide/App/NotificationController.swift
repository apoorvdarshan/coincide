import AppKit
import CoincideKit
import UserNotifications

/// Posts a system notification when a turn ends, an agent asks for approval or an agent is slow to start
/// while Coincide is in the background (`AppSettings.notifyWhenInBackground`), and opens the thread when one is clicked.
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationController()

    private enum Kind: String {
        case approval
        case question
        case completed
        case failed
        case slowStart
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
        let previousQuestion = runner.onUserInputRequested
        runner.onUserInputRequested = { [weak self] threadID, request in
            previousQuestion?(threadID, request)
            self?.questionAsked(threadID, request: request)
        }
        let previousSlowStart = runner.onSlowStart
        runner.onSlowStart = { [weak self] threadID, provider in
            previousSlowStart?(threadID, provider)
            self?.slowStart(threadID, provider: provider)
        }
    }

    /// Clears delivered notifications for a thread the user is now looking at.
    func clearDelivered(for threadID: UUID) {
        let ids = [Kind.approval, .question, .completed, .failed, .slowStart].map { identifier(threadID, $0) }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    // MARK: Events

    private func turnFinished(_ threadID: UUID, outcome: TurnOutcome) {
        let agent = agentName(threadID)
        switch outcome {
        case .completed:
            post(.completed, threadID: threadID, event: String(localized: "\(agent) finished"), body: lastReply(threadID))
        case .failed(let message):
            post(.failed, threadID: threadID, event: String(localized: "\(agent) failed"), body: message)
        case .interrupted:
            break
        }
    }

    private func approvalRequested(_ threadID: UUID, request: ApprovalRequest) {
        post(.approval, threadID: threadID, event: String(localized: "\(agentName(threadID)) needs approval"), body: request.title)
    }

    private func questionAsked(_ threadID: UUID, request: UserInputRequest) {
        let body = request.title ?? request.questions.first?.prompt
        post(.question, threadID: threadID, event: String(localized: "\(agentName(threadID)) has a question"), body: body)
    }

    /// The agent that ran the thread's latest turn, or the one selected for it.
    private func agentName(_ threadID: UUID) -> String {
        let store = AppStore.shared
        let provider =
            store.thread(threadID)?.items.last { $0.kind == .assistant }?.provider ?? store.summary(threadID)?.selection.provider
        return provider?.displayName ?? String(localized: "The agent")
    }

    /// The opening of the agent's last reply in the latest turn.
    private func lastReply(_ threadID: UUID) -> String? {
        guard let items = AppStore.shared.thread(threadID)?.items else { return nil }
        let turn = items.reversed().prefix { $0.kind != .user || $0.steered == true }
        guard let reply = turn.first(where: { $0.kind == .assistant && !$0.text.isEmpty }) else { return nil }
        return Self.excerpt(reply.text)
    }

    /// The first line of prose in Markdown, without its markup, short enough for one line of a notification. A
    /// heading stands in only when there is no prose.
    static func excerpt(_ markdown: String, limit: Int = 140) -> String? {
        var inCode = false
        var heading: String?
        for raw in markdown.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inCode.toggle()
                continue
            }
            if inCode || line.isEmpty || line.hasPrefix("|") || line.allSatisfy({ "-*_=".contains($0) }) { continue }
            let isHeading = line.hasPrefix("#")
            if isHeading || line.hasPrefix(">") {
                line = String(line.drop { $0 == "#" || $0 == ">" || $0 == " " })
            } else {
                for marker in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where line.hasPrefix(marker) {
                    line = String(line.dropFirst(marker.count))
                    break
                }
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
                line = String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
            // Links keep their text.
            line = line.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let shortened = line.count > limit ? String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : line
            if isHeading {
                heading = heading ?? shortened
                continue
            }
            return shortened
        }
        return heading
    }

    /// macOS shows folder permission prompts only while Coincide is active, so a stalled start needs the user here.
    private func slowStart(_ threadID: UUID, provider: ProviderKind) {
        post(
            .slowStart, threadID: threadID,
            event: String(localized: "\(provider.displayName) is waiting to start"),
            body: String(localized: "Switch to Coincide in case macOS is asking for permission to access a folder."))
    }

    /// Posts a notification named after the thread, with what happened under it and a line of detail.
    private func post(_ kind: Kind, threadID: UUID, event: String, body: String?) {
        let store = AppStore.shared
        guard store.settings.notifyWhenInBackground, !NSApp.isActive, let thread = store.summary(threadID),
            !thread.isArchived
        else { return }
        let content = UNMutableNotificationContent()
        content.title = thread.title
        if let project = store.project(thread.projectID)?.name {
            content.subtitle = String(localized: "\(event) in \(project)")
        } else {
            content.subtitle = event
        }
        if let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            content.body = String(body.prefix(240))
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
