import Foundation

/// Drives provider sessions for threads and turns their events into transcript items.
///
/// Each thread can have one live session per provider. Switching provider mid-thread keeps the
/// other sessions (and their native ids) around; the next provider receives a recap of the turns
/// it missed (see `Handoff`).
@MainActor
public final class ThreadRunner {
    public static let shared = ThreadRunner(store: .shared, registry: .shared)

    /// How long a stopped turn waits for its provider to confirm before the runner ends it.
    nonisolated static let defaultStopTimeout: TimeInterval = 6

    public struct TurnState: Sendable {
        public var provider: ProviderKind
        public var startedAt: Date
        /// The item the turn started with, which identifies it: the user's message, or for a turn the
        /// agent started itself, the notice saying so.
        public var userItemID: UUID
        /// The agent started this turn on its own (`.agentTurnStarted`), not in answer to a message.
        public var isAgentInitiated = false
        var planItemID: UUID?
        var interruptRequested = false
        /// The session is being started or the turn prepared; the provider has no prompt yet.
        var isStarting = true
        /// `send` was called (or the agent started the turn), so the provider may be running it.
        var promptSent = false
        /// Once the turn ends, the provider's session has seen the whole thread: it got the prompt (`send`
        /// returned while the turn ran, or the turn produced output after the prompt was sent), or for a turn
        /// it started itself, it had already seen everything before. Only then are the turn's items counted as seen.
        var delivered = false
        /// The model the turn runs with, recorded on its items even if the thread's selection changes meanwhile.
        var modelID: String?
        /// The user's messages the turn took in while it ran (steering it), in order. Each is a user item
        /// after `userItemID`, marked `steered`, that belongs to this turn rather than opening one.
        public internal(set) var steeredItemIDs: [UUID] = []

        init(provider: ProviderKind, startedAt: Date, userItemID: UUID, modelID: String? = nil) {
            self.provider = provider
            self.startedAt = startedAt
            self.userItemID = userItemID
            self.modelID = modelID
        }
    }

    /// A message sent while a turn was running; it is sent when the turn completes.
    public struct QueuedMessage: Sendable, Identifiable, Hashable {
        public var id: UUID
        public var text: String
        public var imagePaths: [String]
        public var createdAt: Date
    }

    /// What became of a message the user sent (T3 Code's steer and queue).
    public enum FollowUpDelivery: Sendable, Hashable {
        /// No turn was running, so the message started one.
        case sent
        /// The running turn took it in.
        case steered
        /// It waits for the running turn to finish.
        case queued
    }

    /// A session whose `start()` is still running. Concurrent sends wait for it instead of spawning another.
    private struct Launch {
        let session: AgentSession
        let task: Task<Void, Error>
    }

    private let store: AppStore
    private let registry: ProviderRegistry
    private var sessions: [UUID: [ProviderKind: AgentSession]] = [:]
    private var launches: [UUID: [ProviderKind: Launch]] = [:]
    /// The native id each live session last reported, to notice when the thread forgot it (rewind).
    private var liveSessionIDs: [UUID: [ProviderKind: String]] = [:]
    private var lastActivity: [UUID: [ProviderKind: Date]] = [:]
    /// Provider item id ("kind:id") to transcript item id, per thread.
    private var itemMaps: [UUID: [String: UUID]] = [:]
    public private(set) var turns: [UUID: TurnState] = [:]
    public private(set) var usage: [UUID: TokenUsage] = [:]
    /// Which provider the stored usage belongs to, so a switch doesn't show the previous agent's context.
    public private(set) var usageProviders: [UUID: ProviderKind] = [:]
    /// The model of the latest turn, so another model's context window is not kept.
    private var usageModels: [UUID: String] = [:]
    public private(set) var queues: [UUID: [QueuedMessage]] = [:]
    /// Subscription usage each provider's sessions reported, merged over what an earlier check or report read.
    private var reportedUsageLimits: [ProviderKind: UsageLimits] = [:]
    private var idleTimer: Timer?
    /// Seconds a stopped turn waits for the provider's confirmation. Tests shorten it.
    var stopTimeout: TimeInterval = ThreadRunner.defaultStopTimeout
    /// Where turns' snapshots are kept. Tests use their own.
    var checkpoints = CheckpointService.shared
    /// Turns whose before snapshot is still being taken; their after snapshot waits for it.
    private var capturingBefore: Set<UUID> = []
    /// After snapshots being taken, so quitting can let them finish.
    private var pendingCaptures: [UUID: Task<Void, Never>] = [:]

    /// Posted when a turn ends. userInfo: "threadID" (UUID), "outcome" (TurnOutcome).
    public static let turnFinishedNotification = Notification.Name("coincide.turnFinished")
    /// Posted when an agent asks for approval or asks a question. userInfo: "threadID" (UUID).
    public static let attentionNeededNotification = Notification.Name("coincide.attentionNeeded")
    /// Posted when a provider's usage windows change. userInfo: "provider" (ProviderKind).
    public static let usageLimitsChangedNotification = Notification.Name("coincide.usageLimitsChanged")

    /// Called when a turn ends. The app shell owns this; other modules observe `turnFinishedNotification`.
    public var onTurnFinished: ((UUID, TurnOutcome) -> Void)?
    /// Called when an agent asks for approval.
    public var onApprovalRequested: ((UUID, ApprovalRequest) -> Void)?
    /// Called when an agent asks the user questions.
    public var onUserInputRequested: ((UUID, UserInputRequest) -> Void)?

    public init(store: AppStore, registry: ProviderRegistry) {
        self.store = store
        self.registry = registry
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutDownIdleSessions() }
        }
    }

    isolated deinit {
        idleTimer?.invalidate()
    }

    // MARK: State

    public func isRunning(_ threadID: UUID) -> Bool { turns[threadID] != nil }

    /// True while the session is being spawned or the turn prepared, before the provider has the prompt.
    public func isStarting(_ threadID: UUID) -> Bool { turns[threadID]?.isStarting == true }

    public func turn(_ threadID: UUID) -> TurnState? { turns[threadID] }

    public var runningThreadIDs: [UUID] { Array(turns.keys) }

    /// Providers with a live process for the thread.
    public func liveProviders(_ threadID: UUID) -> [ProviderKind] {
        (sessions[threadID] ?? [:]).keys.sorted { $0.rawValue < $1.rawValue }
    }

    /// Messages waiting for the running turn to finish, oldest first.
    public func queuedMessages(_ threadID: UUID) -> [QueuedMessage] { queues[threadID] ?? [] }

    /// Whether a message can go into the running turn now: its agent has the prompt, takes messages while it
    /// works, and is still the thread's agent. A turn the agent started itself, or one being stopped, cannot.
    public func canSteer(_ threadID: UUID) -> Bool {
        guard let turn = turns[threadID], !turn.isStarting, turn.promptSent, !turn.interruptRequested,
            !turn.isAgentInitiated, store.thread(threadID)?.selection.provider == turn.provider,
            let session = sessions[threadID]?[turn.provider]
        else { return false }
        return session.supportsSteering
    }

    /// What the provider's plan allows, as its sessions last reported or its last check read, whichever is newer.
    public func usageLimits(for provider: ProviderKind) -> UsageLimits? {
        let checked = registry.status(provider).usageLimits
        guard let reported = reportedUsageLimits[provider] else { return checked }
        guard let checked else { return reported }
        // A newer check reads every window afresh.
        if checked.checkedAt >= reported.checkedAt, !checked.windows.isEmpty { return checked }
        return checked.applying(reported.windows, at: reported.checkedAt)
    }

    /// Approval items still waiting for an answer.
    public func pendingApprovals(_ threadID: UUID) -> [TranscriptItem] {
        store.thread(threadID)?.items.filter { $0.kind == .approval && $0.status == .waiting } ?? []
    }

    /// Question items still waiting for an answer.
    public func pendingQuestions(_ threadID: UUID) -> [TranscriptItem] {
        store.thread(threadID)?.items.filter { $0.kind == .question && $0.status == .waiting } ?? []
    }

    // MARK: Turns

    /// Sends a user message on the thread's selected provider and model.
    /// While a turn is running the message is queued and sent when that turn completes.
    public func send(threadID: UUID, text: String, imagePaths: [String] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !imagePaths.isEmpty else { return }
        if isRunning(threadID) {
            enqueue(threadID: threadID, text: trimmed, imagePaths: imagePaths)
            return
        }
        guard let thread = store.thread(threadID), store.project(thread.projectID) != nil else { return }
        let selection = thread.selection
        let provider = selection.provider

        if !thread.hasUserMessages {
            store.updateThread(threadID) { $0.title = Self.title(from: trimmed) }
        }
        let userItem = TranscriptItem(
            kind: .user, text: trimmed, provider: provider, modelID: selection.modelID,
            attachments: imagePaths.isEmpty ? nil : imagePaths)
        let turnID = userItem.id
        store.append(userItem, to: threadID)
        store.updateThread(threadID, touch: true) { $0.draft = nil }
        itemMaps[threadID] = [:]
        turns[threadID] = TurnState(provider: provider, startedAt: Date(), userItemID: turnID, modelID: selection.modelID)
        resetTurnUsage(threadID, provider: provider, modelID: selection.modelID)
        store.notify(.runState(threadID))

        var isDirectory: ObjCBool = false
        guard let cwd = store.workingDirectory(for: threadID),
            FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            finishTurn(threadID, turnID, outcome: .failed(String(localized: "The project folder is missing.")))
            return
        }

        do {
            let session = try await session(for: threadID, provider: provider, cwd: cwd)
            guard isActive(threadID, turnID) else { return }
            guard turns[threadID]?.interruptRequested == false else {
                finishTurn(threadID, turnID, outcome: .interrupted)
                return
            }
            if store.settings.checkpointsEnabled {
                capturingBefore.insert(turnID)
                await checkpoints.captureBeforeTurn(threadID: threadID, userItemID: turnID, cwd: cwd)
                capturingBefore.remove(turnID)
                guard isActive(threadID, turnID) else {
                    // The turn ended meanwhile (a Stop timed out, or quitting), and `finishTurn` left its after
                    // snapshot to this, as there was nothing to complete yet.
                    captureAfterTurn(threadID, turnID, cwd: cwd)
                    return
                }
                guard turns[threadID]?.interruptRequested == false else {
                    finishTurn(threadID, turnID, outcome: .interrupted)
                    return
                }
            }
            // The recap covers what this provider missed before the new message. It is built once the
            // session is up, because starting it may have replaced the native session.
            guard let current = store.thread(threadID), let userIndex = current.items.firstIndex(where: { $0.id == turnID })
            else {
                finishTurn(threadID, turnID, outcome: .interrupted)
                return
            }
            var snapshot = current
            snapshot.items = Array(current.items.prefix(userIndex))
            let input = AgentTurnInput(
                message: trimmed, handoffRecap: Handoff.recap(thread: snapshot, provider: provider),
                newSessionRecap: Handoff.newSessionRecap(thread: snapshot, provider: provider), threadTitle: snapshot.title,
                imagePaths: imagePaths, selection: selection, accessMode: snapshot.accessMode,
                interactionMode: snapshot.interactionMode)
            turns[threadID]?.isStarting = false
            turns[threadID]?.promptSent = true
            store.notify(.runState(threadID))
            try await session.send(input)
            if isActive(threadID, turnID) { turns[threadID]?.delivered = true }
        } catch {
            // The turn may already have ended (for example on Stop) before the error surfaced.
            guard isActive(threadID, turnID) else { return }
            finishTurn(threadID, turnID, outcome: .failed(error.localizedDescription))
        }
    }

    /// Usage reports fill in each other's missing fields, so a turn starts without the previous turn's
    /// per-turn counts, and a different model without the previous model's context window.
    private func resetTurnUsage(_ threadID: UUID, provider: ProviderKind, modelID: String) {
        if usageProviders[threadID] == provider, var current = usage[threadID] {
            current.outputTokens = nil
            current.cachedInputTokens = nil
            if usageModels[threadID] != modelID { current.contextWindow = nil }
            usage[threadID] = current
        }
        usageModels[threadID] = modelID
    }

    /// Sends a message into the running turn (T3 Code's steer), when its agent can take one now; otherwise
    /// the message is queued for after the turn. With no turn running it starts one, as `send` does.
    /// Nil when there is nothing to send.
    @discardableResult
    public func steer(threadID: UUID, text: String, imagePaths: [String] = []) async -> FollowUpDelivery? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !imagePaths.isEmpty else { return nil }
        guard isRunning(threadID) else {
            await send(threadID: threadID, text: trimmed, imagePaths: imagePaths)
            return .sent
        }
        let message = QueuedMessage(id: UUID(), text: trimmed, imagePaths: imagePaths, createdAt: Date())
        return await steerOrQueue(message, threadID: threadID, queueIndex: nil)
    }

    /// Sends a queued message now: into the running turn when it can take one, or as a new turn when none runs.
    /// A message the turn cannot take keeps its place in the queue. Nil when no such message is queued.
    @discardableResult
    public func steerQueued(threadID: UUID, id: UUID) async -> FollowUpDelivery? {
        guard let index = queues[threadID]?.firstIndex(where: { $0.id == id }),
            let message = removeQueued(threadID: threadID, id: id)
        else { return nil }
        guard isRunning(threadID) else {
            await send(threadID: threadID, text: message.text, imagePaths: message.imagePaths)
            return .sent
        }
        return await steerOrQueue(message, threadID: threadID, queueIndex: index)
    }

    /// Hands the message to the running turn's session, recording it as a user item of that turn once taken.
    /// A message the session refuses waits for the turn to end, or starts a turn if it already has.
    private func steerOrQueue(_ message: QueuedMessage, threadID: UUID, queueIndex: Int?) async -> FollowUpDelivery {
        guard canSteer(threadID), let turn = turns[threadID], let session = sessions[threadID]?[turn.provider],
            let thread = store.thread(threadID)
        else {
            enqueue(message, threadID: threadID, at: queueIndex)
            return .queued
        }
        // The session has seen the whole thread up to this turn, and nothing else can run meanwhile: no recap.
        let input = AgentTurnInput(
            text: message.text, imagePaths: message.imagePaths, selection: thread.selection, accessMode: thread.accessMode,
            interactionMode: thread.interactionMode)
        do {
            try await session.steer(input)
        } catch {
            // The turn could not take it (not started, ending, or being stopped): it goes after the turn.
            if isRunning(threadID) {
                enqueue(message, threadID: threadID, at: queueIndex)
                return .queued
            }
            await send(threadID: threadID, text: message.text, imagePaths: message.imagePaths)
            return .sent
        }
        // Marked as steered, so it stays part of the turn it went into instead of opening one.
        let item = TranscriptItem(
            kind: .user, text: message.text, provider: turn.provider, modelID: turn.modelID,
            attachments: message.imagePaths.isEmpty ? nil : message.imagePaths, steered: true)
        let countBefore = store.thread(threadID)?.items.count ?? 0
        store.append(item, to: threadID)
        if isActive(threadID, turn.userItemID) {
            turns[threadID]?.steeredItemIDs.append(item.id)
            store.updateThread(threadID, touch: true) { _ in }
        } else {
            // The turn ended while the message was on its way, yet its agent took it; it has seen the message.
            store.updateThread(threadID, touch: true) { thread in
                guard var ref = thread.sessions[turn.provider], ref.seenItemCount == countBefore else { return }
                ref.seenItemCount = thread.items.count
                thread.sessions[turn.provider] = ref
            }
        }
        lastActivity[threadID, default: [:]][turn.provider] = Date()
        store.notify(.runState(threadID))
        return .steered
    }

    /// Queues a message to send after the running turn.
    public func enqueue(threadID: UUID, text: String, imagePaths: [String] = []) {
        enqueue(QueuedMessage(id: UUID(), text: text, imagePaths: imagePaths, createdAt: Date()), threadID: threadID, at: nil)
    }

    private func enqueue(_ message: QueuedMessage, threadID: UUID, at index: Int?) {
        var queue = queues[threadID] ?? []
        queue.insert(message, at: min(index ?? queue.count, queue.count))
        queues[threadID] = queue
        store.notify(.runState(threadID))
    }

    /// Removes a queued message, for example to edit it in the composer.
    @discardableResult
    public func removeQueued(threadID: UUID, id: UUID) -> QueuedMessage? {
        guard let index = queues[threadID]?.firstIndex(where: { $0.id == id }) else { return nil }
        let message = queues[threadID]?.remove(at: index)
        if queues[threadID]?.isEmpty == true { queues[threadID] = nil }
        store.notify(.runState(threadID))
        return message
    }

    /// Stops the running turn on the thread.
    public func stop(threadID: UUID) {
        guard let turn = turns[threadID], !turn.interruptRequested else { return }
        turns[threadID]?.interruptRequested = true
        // The session cancels the turn's open prompts when interrupted, so they must not stay clickable.
        declineOpenPrompts(threadID, provider: turn.provider, since: turn.userItemID)
        if turn.promptSent, let session = sessions[threadID]?[turn.provider] {
            session.interrupt()
        }
        // Providers confirm with `.turnCompleted(.interrupted)`; don't wait forever.
        let turnID = turn.userItemID
        DispatchQueue.main.asyncAfter(deadline: .now() + stopTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let current = self.turns[threadID], current.userItemID == turnID else { return }
                self.finishTurn(threadID, turnID, outcome: .interrupted)
                // The provider never confirmed, so it may still be running the turn and report it later,
                // into the next one. Its process is ended; the next turn resumes the native session.
                if current.promptSent { self.shutdown(threadID: threadID, provider: current.provider) }
            }
        }
    }

    /// Answers an approval item. `text` is sent along when the approval asked for text input.
    public func respond(threadID: UUID, itemID: UUID, optionID: String, text: String? = nil) {
        guard let item = store.item(itemID, in: threadID), let approval = item.approval, item.status == .waiting,
            let provider = item.provider
        else { return }
        guard let session = currentSession(threadID, provider) else {
            closeOrphanedPrompt(itemID, in: threadID)
            return
        }
        let option = approval.options.first { $0.id == optionID }
        if approval.textInput != nil {
            session.respond(to: approval.requestID, optionID: optionID, text: text)
        } else {
            session.respond(to: approval.requestID, optionID: optionID)
        }
        store.updateItem(itemID, in: threadID) { item in
            item.approval?.resolution = option?.label ?? optionID
            if approval.textInput != nil { item.approval?.responseText = text }
            item.status = (option?.kind == .deny || option?.kind == .cancel) ? .declined : .completed
            item.completedAt = Date()
        }
    }

    /// Answers a question item. `answers` maps question ids to the chosen labels or typed text.
    public func answer(threadID: UUID, itemID: UUID, answers: [String: [String]]) {
        guard let item = store.item(itemID, in: threadID), let request = item.questions, item.status == .waiting,
            let provider = item.provider
        else { return }
        guard let session = currentSession(threadID, provider) else {
            closeOrphanedPrompt(itemID, in: threadID)
            return
        }
        session.answer(userInput: request.id, answers: answers)
        let secretIDs = Set(request.questions.filter(\.isSecret).map(\.id))
        store.updateItem(itemID, in: threadID) { item in
            // Secret answers are sent to the agent but never stored.
            item.answers = answers.reduce(into: [:]) { result, entry in
                result[entry.key] = secretIDs.contains(entry.key) ? ["••••"] : entry.value
            }
            item.status = .completed
            item.completedAt = Date()
        }
    }

    /// Dismisses a question item without answering.
    public func dismissQuestion(threadID: UUID, itemID: UUID) {
        guard let item = store.item(itemID, in: threadID), let request = item.questions, item.status == .waiting,
            let provider = item.provider
        else { return }
        currentSession(threadID, provider)?.answer(userInput: request.id, answers: [:])
        store.updateItem(itemID, in: threadID) { item in
            item.status = .declined
            item.completedAt = Date()
        }
    }

    /// Ends every session of a thread (for example when it is deleted or its folder changes).
    public func shutdown(threadID: UUID) {
        queues[threadID] = nil
        if let turn = turns[threadID] { finishTurn(threadID, turn.userItemID, outcome: .interrupted) }
        let providers = Set((sessions[threadID] ?? [:]).keys).union((launches[threadID] ?? [:]).keys)
        for provider in providers { shutdown(threadID: threadID, provider: provider) }
        sessions[threadID] = nil
        launches[threadID] = nil
        liveSessionIDs[threadID] = nil
        lastActivity[threadID] = nil
        itemMaps[threadID] = nil
    }

    /// Ends one provider's session for a thread; its id is kept so the next turn resumes it.
    /// Prompts it left open can no longer be answered and are closed.
    public func shutdown(threadID: UUID, provider: ProviderKind) {
        let live = sessions[threadID]?.removeValue(forKey: provider)
        let launching = launches[threadID]?.removeValue(forKey: provider)
        liveSessionIDs[threadID]?[provider] = nil
        guard live != nil || launching != nil else { return }
        live?.shutdown()
        launching?.session.shutdown()
        declineOpenPrompts(threadID, provider: provider, since: nil)
    }

    /// Ends every session and stops every agent process and what it started, waiting briefly for them
    /// to exit. Call when quitting.
    public func shutdownAll() {
        let threadIDs = Set(sessions.keys).union(launches.keys).union(turns.keys)
        for threadID in threadIDs { shutdown(threadID: threadID) }
        // Sessions stop their processes asynchronously, which a quitting app does not wait for.
        ChildProcesses.terminateAllAndWait()
        // The turns just ended still need their after snapshots, or their changes could never be shown.
        waitForCheckpoints(timeout: 3)
    }

    /// True while snapshots of ended turns are still being taken.
    var isCapturingCheckpoints: Bool { !capturingBefore.isEmpty || !pendingCaptures.isEmpty }

    /// Lets the snapshots of ended turns finish, for at most `timeout` seconds. They run on the main actor,
    /// so the main run loop keeps turning meanwhile. That serves the main queue when quitting from a menu,
    /// key command or Apple event; called from a main-queue block, this just waits out the timeout.
    private func waitForCheckpoints(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while isCapturingCheckpoints, Date() < deadline {
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
        }
    }

    // MARK: Sessions

    /// The access mode each thread's provider session was launched with.
    private var launchedAccess: [UUID: [ProviderKind: AccessMode]] = [:]

    /// The live session, or the one still starting.
    private func currentSession(_ threadID: UUID, _ provider: ProviderKind) -> AgentSession? {
        sessions[threadID]?[provider] ?? launches[threadID]?[provider]?.session
    }

    private func isCurrent(_ session: AgentSession, _ threadID: UUID, _ provider: ProviderKind) -> Bool {
        currentSession(threadID, provider) === session
    }

    private func isActive(_ threadID: UUID, _ turnID: UUID) -> Bool { turns[threadID]?.userItemID == turnID }

    private func session(for threadID: UUID, provider: ProviderKind, cwd: URL) async throws -> AgentSession {
        // A session launched with full access must not run a turn the user now wants to approve; providers
        // that only read the mode at launch would otherwise keep running unprompted. Restart it instead.
        if sessions[threadID]?[provider] != nil, launchedAccess[threadID]?[provider] == .fullAccess,
            store.thread(threadID)?.accessMode == .approval
        {
            shutdown(threadID: threadID, provider: provider)
        }
        if let existing = sessions[threadID]?[provider] {
            // The thread no longer knows this native session (it was rewound), so it must not continue it.
            if let live = liveSessionIDs[threadID]?[provider], store.thread(threadID)?.sessions[provider]?.sessionID != live {
                shutdown(threadID: threadID, provider: provider)
            } else {
                return existing
            }
        }
        if let launch = launches[threadID]?[provider] { return try await join(launch, threadID, provider) }
        guard let factory = registry.provider(provider) else { throw AgentError.notInstalled(provider) }
        guard let executable = await registry.executable(for: provider) else { throw AgentError.notInstalled(provider) }
        let environment = await registry.environment(for: provider)
        // Another send may have started (or finished starting) the session while this one waited.
        if let existing = sessions[threadID]?[provider] { return existing }
        if let launch = launches[threadID]?[provider] { return try await join(launch, threadID, provider) }
        guard let thread = store.thread(threadID) else { throw AgentError.notRunning }
        let launch = AgentLaunch(
            provider: provider, executable: executable, environment: environment, workingDirectory: cwd,
            resumeSessionID: thread.sessions[provider]?.sessionID, selection: thread.selection,
            accessMode: thread.accessMode, interactionMode: thread.interactionMode)
        let session = factory.makeSession(launch)
        launchedAccess[threadID, default: [:]][provider] = launch.accessMode
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session, self.isCurrent(session, threadID, provider) else { return }
            self.handle(event, threadID: threadID, provider: provider, session: session)
        }
        let task = Task { try await session.start() }
        launches[threadID, default: [:]][provider] = Launch(session: session, task: task)
        lastActivity[threadID, default: [:]][provider] = Date()
        return try await join(Launch(session: session, task: task), threadID, provider)
    }

    /// Waits for a session to start and makes it the thread's live session for its provider.
    private func join(_ launch: Launch, _ threadID: UUID, _ provider: ProviderKind) async throws -> AgentSession {
        do {
            try await launch.task.value
        } catch {
            if launches[threadID]?[provider]?.session === launch.session {
                launches[threadID]?[provider] = nil
                launch.session.shutdown()
            }
            throw error
        }
        if launches[threadID]?[provider]?.session === launch.session {
            launches[threadID]?[provider] = nil
            sessions[threadID, default: [:]][provider] = launch.session
        }
        // Shut down while starting, or it exited right away.
        guard sessions[threadID]?[provider] === launch.session else { throw AgentError.notRunning }
        return launch.session
    }

    func shutDownIdleSessions(now: Date = Date()) {
        let limit = TimeInterval(max(1, store.settings.idleSessionTimeoutMinutes) * 60)
        for (threadID, providers) in sessions {
            for (provider, session) in providers {
                if turns[threadID]?.provider == provider { continue }
                // Ending the session would kill the agent's background work (a dev server, a long test run).
                // Its idle time counts from when that work ends, which emits no event.
                if (session as? BackgroundWorkReporting)?.hasBackgroundWork == true {
                    lastActivity[threadID, default: [:]][provider] = now
                    continue
                }
                let last = lastActivity[threadID]?[provider] ?? .distantPast
                if now.timeIntervalSince(last) > limit { shutdown(threadID: threadID, provider: provider) }
            }
        }
    }

    // MARK: Events

    private func handle(_ event: AgentEvent, threadID: UUID, provider: ProviderKind, session: AgentSession) {
        lastActivity[threadID, default: [:]][provider] = Date()
        let modelID = self.modelID(for: provider, in: threadID)
        // Output from the provider of the running turn shows it has the prompt, once the prompt was sent.
        // Before that it comes from something else, such as a turn the agent started on its own meanwhile.
        let turnOfProvider = turns[threadID]?.provider == provider
        if turnOfProvider, let turn = turns[threadID], !turn.isAgentInitiated, turn.promptSent, Self.showsDelivery(event) {
            turns[threadID]?.delivered = true
        }
        switch event {
        case .sessionStarted(let id):
            liveSessionIDs[threadID, default: [:]][provider] = id
            store.updateThread(threadID) { thread in
                let previous = thread.sessions[provider]
                // A different id means a fresh native session that has seen nothing yet.
                let seen = previous?.sessionID == id ? previous?.seenItemCount ?? 0 : 0
                thread.sessions[provider] = ProviderSessionRef(sessionID: id, seenItemCount: seen)
            }

        case .sessionContinued(let id):
            liveSessionIDs[threadID, default: [:]][provider] = id
            store.updateThread(threadID) { thread in
                let seen = thread.sessions[provider]?.seenItemCount ?? 0
                thread.sessions[provider] = ProviderSessionRef(sessionID: id, seenItemCount: seen)
            }

        case .assistantTextDelta(let itemID, let delta):
            appendText(delta, kind: .assistant, externalID: itemID, threadID: threadID, provider: provider, modelID: modelID)
        case .assistantText(let itemID, let text):
            setText(text, kind: .assistant, externalID: itemID, threadID: threadID, provider: provider, modelID: modelID)
        case .reasoningDelta(let itemID, let delta):
            appendText(delta, kind: .reasoning, externalID: itemID, threadID: threadID, provider: provider, modelID: modelID)
        case .reasoningText(let itemID, let text):
            setText(text, kind: .reasoning, externalID: itemID, threadID: threadID, provider: provider, modelID: modelID)

        case .toolStarted(let info):
            if let existing = mappedItem(.tool, info.id, threadID) {
                store.updateItem(existing, in: threadID) { item in
                    item.title = info.title
                    item.detail = info.detail ?? item.detail
                    item.category = info.category
                }
            } else {
                let item = TranscriptItem(
                    kind: .tool, title: info.title, detail: info.detail, category: info.category, status: .running,
                    provider: provider, modelID: modelID, externalID: info.id)
                map(.tool, info.id, to: item.id, threadID)
                store.append(item, to: threadID)
            }
        case .toolUpdated(let info):
            guard let existing = mappedItem(.tool, info.id, threadID) else {
                handle(.toolStarted(info), threadID: threadID, provider: provider, session: session)
                return
            }
            store.updateItem(existing, in: threadID) { item in
                item.title = info.title
                if let detail = info.detail { item.detail = detail }
                item.category = info.category
            }
        case .toolOutput(let id, let delta):
            guard !delta.isEmpty, let existing = toolItem(id, provider: provider, threadID) else { return }
            store.updateItem(existing, in: threadID) { item in
                item.text += delta
                item.text = TextClip.keepingTail(item.text, limit: Self.toolOutputLimit, clipTo: Self.toolOutputKept)
            }
        case .toolCompleted(let id, let status, let output):
            guard let existing = toolItem(id, provider: provider, threadID) else { return }
            store.updateItem(existing, in: threadID) { item in
                item.status = status
                item.completedAt = Date()
                if let output, !output.isEmpty {
                    item.text = TextClip.keepingTail(output, limit: Self.toolOutputLimit, clipTo: Self.toolOutputKept)
                }
            }

        case .approvalRequested(let request):
            let info = ApprovalInfo(requestID: request.id, options: request.options, textInput: request.textInput)
            if let existing = waitingPrompt(.approval, requestID: request.id, provider: provider, threadID: threadID) {
                // A provider repeating a request (for example after reconnecting) updates the open one.
                store.updateItem(existing, in: threadID) { item in
                    item.title = request.title
                    item.detail = request.detail
                    item.category = request.category
                    item.approval = info
                }
                return
            }
            let item = TranscriptItem(
                kind: .approval, title: request.title, detail: request.detail, category: request.category,
                status: .waiting, provider: provider, modelID: modelID, externalID: request.id, approval: info)
            store.append(item, to: threadID)
            onApprovalRequested?(threadID, request)
            NotificationCenter.default.post(name: Self.attentionNeededNotification, object: self, userInfo: ["threadID": threadID])
        case .approvalResolved(let id):
            guard let itemID = waitingPrompt(.approval, requestID: id, provider: provider, threadID: threadID) else { return }
            store.updateItem(itemID, in: threadID) { item in
                item.status = .completed
                item.approval?.resolution = String(localized: "Closed by the agent")
                item.completedAt = Date()
            }

        case .userInputRequested(let request):
            if let existing = waitingPrompt(.question, requestID: request.id, provider: provider, threadID: threadID) {
                store.updateItem(existing, in: threadID) { item in
                    item.title = request.title
                    item.questions = request
                }
                return
            }
            let item = TranscriptItem(
                kind: .question, title: request.title, status: .waiting, provider: provider, modelID: modelID,
                externalID: request.id, questions: request)
            store.append(item, to: threadID)
            onUserInputRequested?(threadID, request)
            NotificationCenter.default.post(name: Self.attentionNeededNotification, object: self, userInfo: ["threadID": threadID])
        case .userInputResolved(let id):
            guard let itemID = waitingPrompt(.question, requestID: id, provider: provider, threadID: threadID) else { return }
            store.updateItem(itemID, in: threadID) { item in
                item.status = .completed
                item.completedAt = Date()
            }

        case .plan(let text):
            if turnOfProvider, let planID = turns[threadID]?.planItemID, store.item(planID, in: threadID) != nil {
                store.updateItem(planID, in: threadID) { $0.text = text }
            } else {
                let item = TranscriptItem(kind: .plan, text: text, provider: provider, modelID: modelID)
                if turnOfProvider { turns[threadID]?.planItemID = item.id }
                store.append(item, to: threadID)
            }

        case .usage(let value):
            if usageProviders[threadID] != provider { usage[threadID] = nil }
            usageProviders[threadID] = provider
            usage[threadID] = value.merged(with: usage[threadID] ?? TokenUsage())
            store.notify(.runState(threadID))
        case .rateLimits(let windows):
            recordUsageLimits(windows, for: provider)
        case .modelResolved:
            break
        case .modelsDiscovered(let models):
            registry.updateModels(models, for: provider)
        case .notice(let text):
            store.append(TranscriptItem(kind: .notice, text: text, provider: provider), to: threadID)

        case .agentTurnStarted(let note):
            startAgentTurn(threadID, provider: provider, note: note)
        case .turnCompleted(let outcome):
            // A completion before the prompt was handed over can only be a late one from an abandoned turn.
            guard let turn = turns[threadID], turn.provider == provider, turn.promptSent else { return }
            finishTurn(threadID, turn.userItemID, outcome: outcome)
        case .sessionExited(let error):
            let wasLive = sessions[threadID]?[provider] === session
            if wasLive {
                sessions[threadID]?[provider] = nil
                liveSessionIDs[threadID]?[provider] = nil
                declineOpenPrompts(threadID, provider: provider, since: nil)
            }
            // A session that exits while starting fails its `start()` instead.
            if let turn = turns[threadID], turn.provider == provider, wasLive || turn.promptSent {
                let message = error ?? String(localized: "\(provider.displayName) exited unexpectedly.")
                finishTurn(threadID, turn.userItemID, outcome: .failed(message))
            }
        }
    }

    /// Merges a provider's report of its usage windows and tells observers when anything changed. Agents repeat
    /// unchanged windows with every token count, which changes nothing. Returns whether anything changed.
    @discardableResult
    func recordUsageLimits(_ windows: [UsageLimitWindow], for provider: ProviderKind, at date: Date = Date()) -> Bool {
        guard !windows.isEmpty else { return false }
        let current = usageLimits(for: provider)
        let updated = (current ?? UsageLimits(windows: [], checkedAt: date)).applying(windows, at: date)
        reportedUsageLimits[provider] = updated
        guard updated.windows != current?.windows else { return false }
        NotificationCenter.default.post(
            name: Self.usageLimitsChangedNotification, object: self, userInfo: ["provider": provider])
        return true
    }

    /// The model `provider` works with on the thread: its running turn's, or the one it was last sent a message
    /// with. The thread's selection may have moved on to another model or provider meanwhile.
    private func modelID(for provider: ProviderKind, in threadID: UUID) -> String? {
        if let turn = turns[threadID], turn.provider == provider, let modelID = turn.modelID { return modelID }
        return store.thread(threadID)?.items.last { $0.provider == provider && $0.modelID != nil }?.modelID
    }

    /// Events that only arrive once the provider is working on the prompt.
    private static func showsDelivery(_ event: AgentEvent) -> Bool {
        switch event {
        case .assistantTextDelta, .assistantText, .reasoningDelta, .reasoningText, .toolStarted, .toolUpdated,
            .toolOutput, .toolCompleted, .approvalRequested, .userInputRequested, .plan, .turnCompleted(.completed):
            true
        default:
            false
        }
    }

    /// Shows a turn the agent started by itself as running, so it can be stopped and is settled when it ends.
    private func startAgentTurn(_ threadID: UUID, provider: ProviderKind, note: String?) {
        // One turn at a time: a running turn already covers whatever the agent does.
        guard turns[threadID] == nil, let thread = store.thread(threadID) else { return }
        // The turn continues the native session as it stands, so the session has seen the whole thread
        // afterwards only if it had seen everything before.
        let upToDate = thread.sessions[provider] != nil && Handoff.missedItems(in: thread, for: provider).isEmpty
        let text = note ?? String(localized: "\(provider.displayName) continued on its own.")
        let notice = TranscriptItem(kind: .notice, text: text, provider: provider)
        store.append(notice, to: threadID)
        var state = TurnState(
            provider: provider, startedAt: Date(), userItemID: notice.id, modelID: modelID(for: provider, in: threadID))
        state.isAgentInitiated = true
        state.isStarting = false
        state.promptSent = true
        state.delivered = upToDate
        turns[threadID] = state
        store.notify(.runState(threadID))
    }

    private func finishTurn(_ threadID: UUID, _ turnID: UUID, outcome: TurnOutcome) {
        guard let turn = turns[threadID], turn.userItemID == turnID else { return }
        let provider = turn.provider
        turns[threadID] = nil
        lastActivity[threadID, default: [:]][provider] = Date()
        if let thread = store.thread(threadID) {
            let start = thread.items.firstIndex { $0.id == turnID } ?? thread.items.endIndex
            for (index, item) in thread.items.enumerated() {
                switch item.status {
                case .running:
                    // Also settles items that streamed in after an earlier turn had ended.
                    break
                case .waiting where index >= start && item.provider == provider:
                    // Prompts of other providers, or from between turns, stay open until answered.
                    break
                default:
                    continue
                }
                store.updateItem(item.id, in: threadID) { item in
                    switch item.kind {
                    case .approval, .question: item.status = .declined
                    case .tool: item.status = outcome == .completed || index < start ? .completed : .failed
                    default: item.status = .completed
                    }
                    item.completedAt = item.completedAt ?? Date()
                }
            }
        }
        switch outcome {
        case .completed:
            break
        case .interrupted:
            store.append(TranscriptItem(kind: .notice, text: String(localized: "Interrupted"), provider: provider), to: threadID)
        case .failed(let message):
            store.append(TranscriptItem(kind: .error, text: message, provider: provider), to: threadID)
        }
        // A provider that never got the prompt has not seen the turn, nor what other agents did before it.
        if turn.delivered {
            store.updateThread(threadID, touch: true) { thread in
                if var ref = thread.sessions[provider] {
                    ref.seenItemCount = thread.items.count
                    thread.sessions[provider] = ref
                }
            }
        } else {
            store.updateThread(threadID, touch: true) { _ in }
        }
        store.notify(.runState(threadID))
        // A before snapshot still being taken has nothing to complete yet; `send` takes the after one once it is done.
        if store.settings.checkpointsEnabled, !capturingBefore.contains(turnID),
            let cwd = store.workingDirectory(for: threadID)
        {
            captureAfterTurn(threadID, turnID, cwd: cwd)
        }
        onTurnFinished?(threadID, outcome)
        NotificationCenter.default.post(
            name: Self.turnFinishedNotification, object: self, userInfo: ["threadID": threadID, "outcome": outcome])
        // Queued follow-ups only continue a turn that finished normally; after a stop or error the user decides.
        // Messages typed while the agent worked on its own are sent unless the user stopped it.
        let proceed = outcome == .completed || (turn.isAgentInitiated && !turn.interruptRequested)
        if proceed, let next = queues[threadID]?.first {
            removeQueued(threadID: threadID, id: next.id)
            Task { await send(threadID: threadID, text: next.text, imagePaths: next.imagePaths) }
        }
    }

    /// Snapshots the folder after a turn ended, recording what the turn changed. Quitting waits for it.
    private func captureAfterTurn(_ threadID: UUID, _ turnID: UUID, cwd: URL) {
        let id = UUID()
        pendingCaptures[id] = Task {
            await checkpoints.captureAfterTurn(threadID: threadID, userItemID: turnID, cwd: cwd)
            pendingCaptures[id] = nil
        }
    }

    // MARK: Prompts

    /// The open approval or question with this request id from the provider, newest first.
    private func waitingPrompt(_ kind: TranscriptItem.Kind, requestID: String, provider: ProviderKind, threadID: UUID)
        -> UUID?
    {
        store.thread(threadID)?.items.last { item in
            guard item.kind == kind, item.status == .waiting, item.provider == provider else { return false }
            return kind == .approval ? item.approval?.requestID == requestID : item.questions?.id == requestID
        }?.id
    }

    /// Closes the provider's open approvals and questions, all of them or those since a turn's user message.
    private func declineOpenPrompts(_ threadID: UUID, provider: ProviderKind, since turnID: UUID?) {
        guard let items = store.thread(threadID)?.items else { return }
        let start = turnID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        for item in items[start...]
        where (item.kind == .approval || item.kind == .question) && item.status == .waiting && item.provider == provider {
            store.updateItem(item.id, in: threadID) { item in
                item.status = .declined
                item.completedAt = Date()
            }
        }
    }

    /// An approval or question whose session is gone cannot be answered any more.
    private func closeOrphanedPrompt(_ itemID: UUID, in threadID: UUID) {
        store.updateItem(itemID, in: threadID) { item in
            item.status = .declined
            item.approval?.resolution = String(localized: "The agent session ended")
            item.completedAt = Date()
        }
    }

    // MARK: Item mapping

    /// Tool output kept per item: once it grows past the limit, only the newest part is kept.
    nonisolated static let toolOutputLimit = 200_000
    nonisolated static let toolOutputKept = 150_000

    private func key(_ kind: TranscriptItem.Kind, _ externalID: String) -> String { "\(kind.rawValue):\(externalID)" }

    private func mappedItem(_ kind: TranscriptItem.Kind, _ externalID: String, _ threadID: UUID) -> UUID? {
        guard let id = itemMaps[threadID]?[key(kind, externalID)], store.item(id, in: threadID) != nil else { return nil }
        return id
    }

    /// The tool item a provider's tool id refers to: one from this turn, or from an earlier turn that the
    /// provider updates late (a background command or subagent finishing after its call returned). The map
    /// only covers the current turn, since text ids can repeat across turns and sessions.
    private func toolItem(_ externalID: String, provider: ProviderKind, _ threadID: UUID) -> UUID? {
        mappedItem(.tool, externalID, threadID)
            ?? store.thread(threadID)?.items.last { item in
                item.kind == .tool && item.provider == provider && item.externalID == externalID
            }?.id
    }

    private func map(_ kind: TranscriptItem.Kind, _ externalID: String, to itemID: UUID, _ threadID: UUID) {
        itemMaps[threadID, default: [:]][key(kind, externalID)] = itemID
    }

    private func appendText(
        _ delta: String, kind: TranscriptItem.Kind, externalID: String, threadID: UUID, provider: ProviderKind,
        modelID: String?
    ) {
        guard !delta.isEmpty else { return }
        if let existing = mappedItem(kind, externalID, threadID) {
            store.updateItem(existing, in: threadID) { $0.text += delta }
        } else {
            // Text streaming in while no turn of this provider runs has no turn end to settle it.
            let idle = turns[threadID]?.provider != provider
            let item = TranscriptItem(
                kind: kind, text: delta, status: idle ? .completed : .running, provider: provider, modelID: modelID,
                externalID: externalID, completedAt: idle ? Date() : nil)
            map(kind, externalID, to: item.id, threadID)
            store.append(item, to: threadID)
        }
    }

    private func setText(
        _ text: String, kind: TranscriptItem.Kind, externalID: String, threadID: UUID, provider: ProviderKind,
        modelID: String?
    ) {
        if let existing = mappedItem(kind, externalID, threadID) {
            store.updateItem(existing, in: threadID) { item in
                item.text = text
                item.status = .completed
                item.completedAt = Date()
            }
        } else if !text.isEmpty {
            let item = TranscriptItem(
                kind: kind, text: text, status: .completed, provider: provider, modelID: modelID, externalID: externalID,
                completedAt: Date())
            map(kind, externalID, to: item.id, threadID)
            store.append(item, to: threadID)
        }
    }

    // MARK: Helpers

    static func title(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > 60 else { return collapsed.isEmpty ? String(localized: "New thread") : collapsed }
        return String(collapsed.prefix(57)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
