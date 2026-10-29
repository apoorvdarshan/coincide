import AppKit
import CoincideKit
import CoincideRemoteKit
import UserNotifications

/// Tells the user when a turn ends, an agent asks for approval or a question, or an agent is slow to start
/// (`AppSettings.notifyWhenInBackground`), and opens the thread when a notification is clicked.
///
/// Each event goes to exactly one place, by `NotificationRouting`: this Mac, the phone or iPad in use through Coincide
/// Remote, or a phone's lock screen through CloudKit. Every event has a stable id (`RemoteAlerts.eventID`) that names
/// its notification everywhere, and `NotificationLedger` keeps one from being sent twice.
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationController()

    private var center: UNUserNotificationCenter { .current() }

    private lazy var dispatcher: NotificationDispatcher = {
        let directory = AppStore.shared.directory
        let push = PushAlertDelivery(
            pusher: CloudKitAlertPusher.shared, url: directory.appendingPathComponent("lock-screen-alerts.json"))
        return NotificationDispatcher(
            ledger: NotificationLedger(url: directory.appendingPathComponent("notified-events.json")), push: push,
            environment: NotificationDispatcher.Environment(
                isEnabled: { AppStore.shared.settings.notifyWhenInBackground },
                macActivity: { MacActivity.current(visibleThreadID: ThreadActivity.shared.visibleThreadID) },
                devices: { RemoteServer.shared.devicePresences },
                pushTargets: { RemoteServer.shared.pushTargets },
                postMac: { [weak self] alert in self?.postOnMac(alert) },
                sendLive: { RemoteServer.shared.deliver($0, to: $1) }))
    }()

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

    /// Clears what was posted about a thread the user is now looking at: on this Mac, by the background agent host,
    /// on connected phones and on phones' lock screens.
    func clearDelivered(for threadID: UUID) {
        let center = center
        Task {
            let ids = await center.deliveredNotifications()
                .filter { $0.request.content.threadIdentifier == threadID.uuidString }
                .map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
        // Those the background agent host posted while Coincide was closed are its own; ask it to remove them.
        if let transport = AgentHostController.shared.transport {
            Task { _ = try? await transport.perform(.clearNotifications(threadID: threadID)) }
        }
        RemoteServer.shared.clearNotifications(threadID)
        dispatcher.threadSeen(threadID)
    }

    // MARK: Events

    private func turnFinished(_ threadID: UUID, outcome: TurnOutcome) {
        let agent = agentName(threadID)
        // The turn's last item names the event: a later turn has a later one.
        let itemID = AppStore.shared.thread(threadID)?.items.last?.id
        switch outcome {
        case .completed:
            post(
                .completed, threadID: threadID, itemID: itemID, event: String(localized: "\(agent) finished"),
                body: lastReply(threadID))
        case .failed(let message):
            post(.failed, threadID: threadID, itemID: itemID, event: String(localized: "\(agent) failed"), body: message)
        case .interrupted:
            break
        }
    }

    private func approvalRequested(_ threadID: UUID, request: ApprovalRequest) {
        post(
            .approval, threadID: threadID, itemID: promptItem(threadID, kind: .approval, requestID: request.id),
            event: String(localized: "\(agentName(threadID)) needs approval"), body: request.title)
    }

    private func questionAsked(_ threadID: UUID, request: UserInputRequest) {
        let body = request.title ?? request.questions.first?.prompt
        post(
            .question, threadID: threadID, itemID: promptItem(threadID, kind: .question, requestID: request.id),
            event: String(localized: "\(agentName(threadID)) has a question"), body: body)
    }

    /// The transcript item showing an approval or question, which names its event.
    private func promptItem(_ threadID: UUID, kind: TranscriptItem.Kind, requestID: String) -> UUID? {
        AppStore.shared.thread(threadID)?.items.last { $0.kind == kind && $0.externalID == requestID }?.id
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
    /// This one is never sent to a phone: it is about the Mac itself.
    private func slowStart(_ threadID: UUID, provider: ProviderKind) {
        // Only the thread on screen is skipped: one you're not looking at still notifies while Coincide is in front.
        let isOnScreen = NSApp.isActive && ThreadActivity.shared.visibleThreadID == threadID
        guard AppStore.shared.settings.notifyWhenInBackground, !isOnScreen,
            var alert = content(
                threadID: threadID, kind: .unknown, itemID: nil,
                event: String(localized: "\(provider.displayName) is waiting to start"),
                body: String(localized: "Switch to Coincide in case macOS is asking for permission to access a folder."))
        else { return }
        alert.id = "\(threadID.uuidString).slowStart"
        postOnMac(alert)
    }

    /// Words the event and sends it where `NotificationRouting` says, unless it was sent before.
    private func post(_ kind: RemoteNotification.Kind, threadID: UUID, itemID: UUID?, event: String, body: String?) {
        // What the agent host recorded while Coincide was away was the host's to notify about; catching up on it
        // must not notify again.
        guard !AgentHostController.shared.isApplyingBacklog,
            let alert = content(threadID: threadID, kind: kind, itemID: itemID, event: event, body: body)
        else { return }
        dispatcher.dispatch(alert)
    }

    /// The notification named after the thread, with what happened under it and a line of detail. Nil for a thread
    /// that's gone or archived.
    private func content(
        threadID: UUID, kind: RemoteNotification.Kind, itemID: UUID?, event: String, body: String?
    ) -> AlertContent? {
        let store = AppStore.shared
        guard let thread = store.summary(threadID), !thread.isArchived else { return nil }
        let subtitle = store.project(thread.projectID).map { String(localized: "\(event) in \($0.name)") } ?? event
        let detail = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AlertContent(
            // Without an item, a fresh id: never mistaken for another event.
            id: RemoteAlerts.eventID(threadID: threadID, kind: kind, itemID: itemID ?? UUID()), threadID: threadID,
            kind: kind, title: thread.title, subtitle: subtitle,
            body: detail.flatMap { $0.isEmpty ? nil : String($0.prefix(240)) })
    }

    /// An agent needs the user in a thread's browser (to sign in, say) while they look at another thread or app.
    /// Only this Mac is told: the browser is here. Clicking opens the thread with its browser.
    func browserNeedsUser(_ threadID: UUID, message: String) {
        guard AppStore.shared.settings.notifyWhenInBackground, let thread = AppStore.shared.summary(threadID), !thread.isArchived
        else { return }
        postOnMac(
            AlertContent(
                id: "\(threadID.uuidString).browser", threadID: threadID, kind: .question, title: thread.title,
                subtitle: String(localized: "Your turn in the browser"), body: String(message.prefix(240))),
            opensBrowser: true)
    }

    /// Posts on this Mac, named by the event's id so a repeat replaces it.
    private func postOnMac(_ alert: AlertContent, opensBrowser: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.subtitle
        if let body = alert.body { content.body = body }
        content.sound = .default
        content.threadIdentifier = alert.threadID.uuidString
        content.userInfo = ["threadID": alert.threadID.uuidString, "opensBrowser": opensBrowser]
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        let center = center
        Task {
            guard await Self.isAuthorized(center) else { return }
            try? await center.add(request)
        }
    }

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
        // Coincide is in front but showing another thread, so the banner is how the user hears about this one.
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let value = response.notification.request.content.userInfo["threadID"] as? String,
            let threadID = UUID(uuidString: value)
        else { return }
        let opensBrowser = response.notification.request.content.userInfo["opensBrowser"] as? Bool == true
        await MainActor.run {
            NSApp.activate()
            AppEvents.openThread(threadID)
            if opensBrowser { _ = PreviewSessions.shared.reveal(threadID) }
        }
    }
}
