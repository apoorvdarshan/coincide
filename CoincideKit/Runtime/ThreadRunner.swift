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
        /// Only this turn's reports, without carrying the previous turn's context/cost into history.
        var reportedUsage = TokenUsage()
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
        public var context: [MessageContext] = []
        public var createdAt: Date
        /// The user asked for it to go into the running turn, which could not take it: it is sent when that turn
        /// ends however it ends, including when it is stopped, rather than waiting for the user.
        public var sendsAfterStop = false
    }

    /// What became of a message the user sent (T3 Code's steer and queue).
    public enum FollowUpDelivery: Sendable, Hashable {
        /// No turn was running, so the message started one.
        case sent
        /// The running turn took it in.
        case steered
        /// It waits for the running turn to finish.
        case queued
        /// The running turn is being stopped, and the message goes as the next turn once it has.
        case interrupting
    }

    /// A session whose `start()` is still running. Concurrent sends wait for it instead of spawning another.
    private struct Launch {
        let session: AgentSession
        let task: Task<Void, Error>
    }

    private let store: AppStore
    private let registry: ProviderRegistry
    public let usageHistory: UsageHistory
    /// The provider account of the last turn started, which the menu bar item follows.
    public let lastActiveAgent: LastActiveAgentStore
    private var sessions: [UUID: [ProviderKind: AgentSession]] = [:]
    private var launches: [UUID: [ProviderKind: Launch]] = [:]
    /// The native id each live session last reported, to notice when the thread forgot it (rewind).
    private var liveSessionIDs: [UUID: [ProviderKind: String]] = [:]
    private var lastActivity: [UUID: [ProviderKind: Date]] = [:]
    /// Provider item id ("kind:id") to transcript item id, per thread.
    private var itemMaps: [UUID: [String: UUID]] = [:]
    public private(set) var turns: [UUID: TurnState] = [:] {
        didSet { holdTranscriptsOfRunningTurns() }
    }
    /// Running turns keep their thread's transcript in memory (`AppStore.holdTranscript(_:)`).
    private var transcriptHolds: [UUID: TranscriptHold] = [:]
    public private(set) var usage: [UUID: TokenUsage] = [:]
    /// Which provider the stored usage belongs to, so a switch doesn't show the previous agent's context.
    public private(set) var usageProviders: [UUID: ProviderKind] = [:]
    /// The model of the latest turn, so another model's context window is not kept.
    private var usageModels: [UUID: String] = [:]
    public private(set) var queues: [UUID: [QueuedMessage]] = [:]
    /// Threads that continue on their own once a usage limit resets, and when (T3 Code's "Resume at reset").
    public private(set) var scheduledResumes: [UUID: Date] = [:]
    private var resumeTimers: [UUID: Timer] = [:]
    /// How long after a reset a thread resumes, so the provider has caught up. Tests shorten it.
    var resumeDelay: TimeInterval = 30
    /// What a thread is sent when it resumes after a usage limit, as in T3 Code.
    nonisolated static let resumePrompt = "Continue where you left off."
    /// The commands and skills each thread's sessions reported for its folder, by provider.
    private var sessionCommands: [UUID: [ProviderKind: [ProviderCommand]]] = [:]
    /// What each thread's agents run in the background, by provider (`AgentEvent.backgroundWork`).
    private var backgroundWork: [UUID: [ProviderKind: [BackgroundTask]]] = [:]
    /// Subscription usage each account's sessions reported, merged over what an earlier check or report read. Keyed
    /// by `ChatThread.accountSessionKey`, as each account has a plan of its own.
    private var reportedUsageLimits: [String: UsageLimits] = [:]
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
    /// Legacy single-source runtime context. New app modules register their own key in `ephemeralRuntimeContexts`.
    public var ephemeralRuntimeContext: ((UUID) -> String?)?
    /// Additive per-thread capabilities valid only for this running app, keyed by their owning module. Never
    /// saved as user text or queue metadata. Removing one module leaves the other capabilities in place.
    public var ephemeralRuntimeContexts: [String: (UUID) -> String?] = [:]
    /// Variables added to every agent process Coincide starts, by who adds them, read at each launch: the unlocked
    /// password managers' sessions (`PasswordVault.agentEnvironment`) and the command-line tool's folder and socket
    /// (`CommandLineControl`). A `PATH` goes in front of the process's own instead of replacing it.
    public var launchEnvironments: [String: (UUID) -> [String: String]] = [:]

    private var generatedImageCopies: Set<UUID> = []

    private func runtimeMessage(_ message: String, threadID: UUID) -> String {
        let contexts = ([ephemeralRuntimeContext?(threadID)] + ephemeralRuntimeContexts.keys.sorted().map {
            ephemeralRuntimeContexts[$0]?(threadID)
        }).compactMap { $0 }.filter { !$0.isEmpty }
        return contexts.isEmpty ? message : message + "\n\n" + contexts.joined(separator: "\n\n")
    }

    private func preserveGeneratedImage(toolID: UUID, output: String?, threadID: UUID, provider: ProviderKind, modelID: String?) {
        guard provider == .codex, let tool = store.item(toolID, in: threadID), tool.status == .completed,
            tool.title == String(localized: "Generate an image"), let output,
            generatedImageCopies.insert(toolID).inserted else { return }
        let directory = store.directory.appendingPathComponent("attachments", isDirectory: true)
        Task { [weak self] in
            let path = await AgentOutputMedia.preserveImage(path: output, toolID: toolID, directory: directory)
            guard let self else { return }
            self.generatedImageCopies.remove(toolID)
            guard let path, self.store.item(toolID, in: threadID) != nil else { return }
            let externalID = "generated-media:" + toolID.uuidString
            guard self.store.thread(threadID)?.items.contains(where: { $0.externalID == externalID }) == false else { return }
            var image = TranscriptItem(kind: .assistant, status: .completed, provider: provider, modelID: modelID,
                externalID: externalID, completedAt: Date())
            image.attachments = [path]
            self.store.append(image, to: threadID)
        }
    }

    /// Called when an agent is slow to start, which usually means macOS is waiting on a permission prompt.
    public var onSlowStart: ((UUID, ProviderKind) -> Void)?

    /// Makes the sessions that run in the background agent host while the app uses one (`AgentHostClient`), so they
    /// outlive the app. Nil, or a nil result, runs the session in the app.
    public var hostedSession: ((_ threadID: UUID, _ launch: AgentLaunch, _ account: ProviderAccount) -> AgentSession?)?

    public init(store: AppStore, registry: ProviderRegistry) {
        self.store = store
        self.registry = registry
        usageHistory = UsageHistory(directory: store.directory)
        lastActiveAgent = LastActiveAgentStore(directory: store.directory)
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutDownIdleSessions() }
        }
    }

    isolated deinit {
        idleTimer?.invalidate()
    }

    // MARK: State

    private func holdTranscriptsOfRunningTurns() {
        guard transcriptHolds.count != turns.count || transcriptHolds.keys.contains(where: { turns[$0] == nil }) else { return }
        transcriptHolds = transcriptHolds.filter { turns[$0.key] != nil }
        for threadID in turns.keys where transcriptHolds[threadID] == nil {
            transcriptHolds[threadID] = store.holdTranscript(threadID)
        }
    }

    public func isRunning(_ threadID: UUID) -> Bool { turns[threadID] != nil }

    /// True while the session is being spawned or the turn prepared, before the provider has the prompt.
    public func isStarting(_ threadID: UUID) -> Bool { turns[threadID]?.isStarting == true }

    public func turn(_ threadID: UUID) -> TurnState? { turns[threadID] }

    public var runningThreadIDs: [UUID] { Array(turns.keys) }

    /// Threads whose running turn stops when the app quits: its session runs in the app, not the agent host.
    public var runningInAppThreadIDs: [UUID] {
        turns.filter { threadID, turn in !(currentSession(threadID, turn.provider) is DetachableAgentSession) }.map(\.key)
    }

    /// Providers with a live process for the thread.
    public func liveProviders(_ threadID: UUID) -> [ProviderKind] {
        (sessions[threadID] ?? [:]).keys.sorted { $0.rawValue < $1.rawValue }
    }

    /// Messages waiting for the running turn to finish, oldest first.
    public func queuedMessages(_ threadID: UUID) -> [QueuedMessage] { queues[threadID] ?? [] }

    /// The work the thread's agents run in the background, such as subagents and long commands, which can go on
    /// after their turn ended.
    public func backgroundTasks(_ threadID: UUID) -> [(provider: ProviderKind, task: BackgroundTask)] {
        (backgroundWork[threadID] ?? [:]).sorted { $0.key.rawValue < $1.key.rawValue }
            .flatMap { provider, tasks in tasks.map { (provider, $0) } }
    }

    /// The time a usage limit that stops the provider's work resets, when the provider reported one in the future.
    public func blockingLimitReset(for provider: ProviderKind, account: String? = nil, now: Date = Date()) -> Date? {
        guard let warning = usageLimits(for: provider, account: account)?.current(at: now).warning, warning.blocksWork,
            let reset = warning.resetsAt,
            reset > now
        else { return nil }
        return reset
    }

    /// Continues the thread with `resumePrompt` at `date`, unless a turn runs then or the user cancels first.
    public func resumeAtReset(_ threadID: UUID, at date: Date) {
        resumeTimers.removeValue(forKey: threadID)?.invalidate()
        scheduledResumes[threadID] = date
        let timer = Timer(fire: date.addingTimeInterval(resumeDelay), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeNow(threadID) }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        resumeTimers[threadID] = timer
        store.notify(.runState(threadID))
    }

    public func cancelResume(_ threadID: UUID) {
        resumeTimers.removeValue(forKey: threadID)?.invalidate()
        guard scheduledResumes.removeValue(forKey: threadID) != nil else { return }
        store.notify(.runState(threadID))
    }

    private func resumeNow(_ threadID: UUID) {
        cancelResume(threadID)
        guard store.hasThread(threadID), !isRunning(threadID) else { return }
        Task { await send(threadID: threadID, text: Self.resumePrompt) }
    }

    /// The commands and skills an agent offers in the thread: what its session there reported, else what it offered
    /// elsewhere.
    public func commands(_ threadID: UUID, provider: ProviderKind) -> [ProviderCommand] {
        let account = store.thread(threadID)?.selection.provider == provider ? store.thread(threadID)?.selection.accountID : nil
        if let live = sessionCommands[threadID]?[provider] { return live }
        if let directory = store.workingDirectory(for: threadID) { return registry.commands(for: provider, account: account, in: directory) }
        return registry.commands(for: provider, account: account)
    }

    private func setBackgroundWork(_ tasks: [BackgroundTask], threadID: UUID, provider: ProviderKind) {
        guard (backgroundWork[threadID]?[provider] ?? []) != tasks else { return }
        backgroundWork[threadID, default: [:]][provider] = tasks.isEmpty ? nil : tasks
        if backgroundWork[threadID]?.isEmpty == true { backgroundWork[threadID] = nil }
        store.notify(.runState(threadID))
    }

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
    /// For an account of the provider (nil for its default account).
    public func usageLimits(for provider: ProviderKind, account: String? = nil) -> UsageLimits? {
        let account = registry.account(account, of: provider).id
        let checked = registry.status(provider, account: account).usageLimits
        guard let reported = reportedUsageLimits[ChatThread.accountSessionKey(provider, account)] else { return checked }
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

    /// Sends a user message on the thread's selected provider and model, with the images and context attached to it.
    /// While a turn is running the message is queued and sent when that turn completes.
    public func send(threadID: UUID, text: String, imagePaths: [String] = [], context: [MessageContext] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !imagePaths.isEmpty || !context.isEmpty else { return }
        if isRunning(threadID) {
            enqueue(threadID: threadID, text: trimmed, imagePaths: imagePaths, context: context)
            return
        }
        guard let thread = store.thread(threadID), store.project(thread.projectID) != nil else { return }
        let selection = thread.selection
        let provider = selection.provider

        // A thread the user named before its first message keeps that name.
        if !thread.hasUserMessages, !thread.isTitleCustom {
            let provisional = Self.title(from: trimmed.isEmpty ? context.first?.summary ?? "" : trimmed)
            store.updateThread(threadID) {
                $0.title = provisional
                // Started here, so the agent may look at the title again as the thread goes on.
                $0.titleRefreshes = []
            }
            if store.settings.generatesThreadTitles, !trimmed.isEmpty, let cwd = store.workingDirectory(for: threadID) {
                ThreadTitles.start(
                    threadID: threadID, message: trimmed, provisional: provisional, selection: selection, cwd: cwd,
                    store: store, registry: registry)
            }
        }
        let userItem = TranscriptItem(
            kind: .user, text: trimmed, provider: provider, modelID: selection.modelID,
            attachments: imagePaths.isEmpty ? nil : imagePaths, context: context.isEmpty ? nil : context)
        let turnID = userItem.id
        store.append(userItem, to: threadID)
        store.updateThread(threadID, touch: true) { $0.draft = nil; $0.draftContext = nil }
        itemMaps[threadID] = [:]
        turns[threadID] = TurnState(provider: provider, startedAt: Date(), userItemID: turnID, modelID: selection.modelID)
        lastActiveAgent.record(provider: provider, account: registry.account(selection.accountID, of: provider).id)
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
            // A bot working across the home folder is not snapshotted: a checkpoint would copy all of it into git.
            if store.settings.checkpointsEnabled, !Bot.isBroadFolder(cwd) {
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
            // A bot's persona reaches agents without a channel for it in front of the first message of each native
            // session: one that has not finished a turn yet, or one started because resuming the earlier one failed.
            // Agents with a channel got it at launch (`AgentLaunch.instructions`).
            let persona = provider.takesSessionInstructions ? nil : snapshot.botID.flatMap { store.bot($0) }?.instructionsBlock
            let isFreshSession = (snapshot.sessions[provider]?.seenItemCount ?? 0) <= 0
            let input = AgentTurnInput(
                message: runtimeMessage(MessageContext.prompt(message: trimmed, context: context, workingDirectory: cwd.path), threadID: threadID),
                handoffRecap: Self.joined(isFreshSession ? persona : nil, Handoff.recap(thread: snapshot, provider: provider)),
                newSessionRecap: Self.joined(persona, Handoff.newSessionRecap(thread: snapshot, provider: provider)),
                threadTitle: snapshot.title,
                imagePaths: imagePaths, filePaths: context.compactMap(\.filePath), selection: selection,
                accessMode: snapshot.accessMode, interactionMode: snapshot.interactionMode)
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

    /// The blocks that are there, one after another.
    private nonisolated static func joined(_ blocks: String?...) -> String? {
        let present = blocks.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: "\n\n")
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
    public func steer(threadID: UUID, text: String, imagePaths: [String] = [], context: [MessageContext] = []) async
        -> FollowUpDelivery?
    {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !imagePaths.isEmpty || !context.isEmpty else { return nil }
        guard isRunning(threadID) else {
            await send(threadID: threadID, text: trimmed, imagePaths: imagePaths, context: context)
            return .sent
        }
        let message = QueuedMessage(id: UUID(), text: trimmed, imagePaths: imagePaths, context: context, createdAt: Date())
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
            await send(threadID: threadID, text: message.text, imagePaths: message.imagePaths, context: message.context)
            return .sent
        }
        return await steerOrQueue(message, threadID: threadID, queueIndex: index)
    }

    /// Sends a queued message right away (the queue's "Send now"): into the running turn when it takes it, otherwise
    /// by stopping that turn and sending the message as the next one. Nil when no such message is queued.
    @discardableResult
    public func sendQueuedNow(threadID: UUID, id: UUID) async -> FollowUpDelivery? {
        let delivery = await steerQueued(threadID: threadID, id: id)
        guard delivery == .queued else { return delivery }
        return interruptAndSend(threadID: threadID, id: id)
    }

    /// Sends a message by stopping the running turn first (the composer's Interrupt): it goes as the next turn once
    /// the turn has stopped, ahead of anything queued. With no turn running it is sent at once, as `send` does.
    /// Nil when there is nothing to send.
    @discardableResult
    public func interrupt(threadID: UUID, text: String, imagePaths: [String] = [], context: [MessageContext] = []) async
        -> FollowUpDelivery?
    {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !imagePaths.isEmpty || !context.isEmpty else { return nil }
        guard isRunning(threadID) else {
            await send(threadID: threadID, text: trimmed, imagePaths: imagePaths, context: context)
            return .sent
        }
        let message = QueuedMessage(id: UUID(), text: trimmed, imagePaths: imagePaths, context: context, createdAt: Date())
        enqueue(message, threadID: threadID, at: 0)
        return interruptAndSend(threadID: threadID, id: message.id)
    }

    /// Stops the running turn and sends the queued message as the next turn once it has stopped. With no turn
    /// running, it is sent at once. Nil when no such message is queued.
    @discardableResult
    public func interruptAndSend(threadID: UUID, id: UUID) -> FollowUpDelivery? {
        guard var message = queues[threadID]?.first(where: { $0.id == id }) else { return nil }
        removeQueued(threadID: threadID, id: id)
        guard isRunning(threadID) else {
            Task { await send(threadID: threadID, text: message.text, imagePaths: message.imagePaths, context: message.context) }
            return .sent
        }
        message.sendsAfterStop = true
        enqueue(message, threadID: threadID, at: 0)
        stop(threadID: threadID)
        return .interrupting
    }

    /// Hands the message to the running turn's session, recording it as a user item of that turn once taken.
    /// A message the session refuses waits for the turn to end, or starts a turn if it already has.
    private func steerOrQueue(_ message: QueuedMessage, threadID: UUID, queueIndex: Int?) async -> FollowUpDelivery {
        var message = message
        message.sendsAfterStop = true
        guard canSteer(threadID), let turn = turns[threadID], let session = sessions[threadID]?[turn.provider],
            let thread = store.thread(threadID)
        else {
            enqueue(message, threadID: threadID, at: queueIndex)
            return .queued
        }
        // The session has seen the whole thread up to this turn, and nothing else can run meanwhile: no recap.
        let input = AgentTurnInput(
            text: runtimeMessage(MessageContext.prompt(
                message: message.text, context: message.context, workingDirectory: store.workingDirectory(for: threadID)?.path), threadID: threadID),
            imagePaths: message.imagePaths, filePaths: message.context.compactMap(\.filePath), selection: thread.selection,
            accessMode: thread.accessMode, interactionMode: thread.interactionMode)
        do {
            try await session.steer(input)
        } catch {
            // The turn could not take it (not started, ending, or being stopped): it goes after the turn.
            if isRunning(threadID) {
                enqueue(message, threadID: threadID, at: queueIndex)
                return .queued
            }
            await send(threadID: threadID, text: message.text, imagePaths: message.imagePaths, context: message.context)
            return .sent
        }
        // Marked as steered, so it stays part of the turn it went into instead of opening one.
        let item = TranscriptItem(
            kind: .user, text: message.text, provider: turn.provider, modelID: turn.modelID,
            attachments: message.imagePaths.isEmpty ? nil : message.imagePaths,
            context: message.context.isEmpty ? nil : message.context, steered: true)
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
    public func enqueue(threadID: UUID, text: String, imagePaths: [String] = [], context: [MessageContext] = []) {
        enqueue(
            QueuedMessage(id: UUID(), text: text, imagePaths: imagePaths, context: context, createdAt: Date()),
            threadID: threadID, at: nil)
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

    /// Whether the running turn is being stopped: the user asked, and its agent has not confirmed yet.
    public func isStopping(_ threadID: UUID) -> Bool { turns[threadID]?.interruptRequested == true }

    /// Stops the running turn on the thread. The thread shows it as stopping at once; the agent is asked to stop
    /// right away, and the turn ends anyway if it does not confirm within `stopTimeout`.
    public func stop(threadID: UUID) {
        guard let turn = turns[threadID], !turn.interruptRequested else { return }
        turns[threadID]?.interruptRequested = true
        store.notify(.runState(threadID))
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
        setBackgroundWork([], threadID: threadID, provider: provider)
        live?.shutdown()
        launching?.session.shutdown()
        declineOpenPrompts(threadID, provider: provider, since: nil)
    }

    /// Ends every session and stops every agent process and what it started, waiting briefly for them
    /// to exit. Call when quitting.
    public func shutdownAll() {
        detachHostedSessions()
        let threadIDs = Set(sessions.keys).union(launches.keys).union(turns.keys)
        for threadID in threadIDs { shutdown(threadID: threadID) }
        // Sessions stop their processes asynchronously, which a quitting app does not wait for.
        ChildProcesses.terminateAllAndWait()
        // The turns just ended still need their after snapshots, or their changes could never be shown.
        waitForCheckpoints(timeout: 3)
    }

    /// Lets go of the sessions that run in the agent host without ending them, and leaves their threads as they are:
    /// the host keeps the agents working and logs what they do, and the next launch catches up (`adopt`).
    public func detachHostedSessions() {
        for (threadID, providers) in sessions {
            for (provider, session) in providers {
                guard let hosted = session as? DetachableAgentSession else { continue }
                hosted.detach()
                sessions[threadID]?[provider] = nil
                if turns[threadID]?.provider == provider { turns[threadID] = nil }
            }
        }
        for (threadID, providers) in launches {
            for (provider, launch) in providers {
                guard let hosted = launch.session as? DetachableAgentSession else { continue }
                hosted.detach()
                launches[threadID]?[provider] = nil
                if turns[threadID]?.provider == provider { turns[threadID] = nil }
            }
        }
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
    /// The account each thread's provider session was launched with (`ProviderAccount.id`).
    private var launchedAccounts: [UUID: [ProviderKind: String]] = [:]

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
            store.summary(threadID)?.accessMode == .approval
        {
            shutdown(threadID: threadID, provider: provider)
        }
        // Another account of the provider runs as another agent would: its own process and native session, with a
        // recap of what the previous account did. The previous account's session is set aside for when it returns.
        let account = registry.account(store.thread(threadID)?.selection.accountID, of: provider).id
        if currentSession(threadID, provider) != nil, launchedAccount(threadID, provider) != account {
            shutdown(threadID: threadID, provider: provider)
            sessionCommands[threadID]?[provider] = nil
        }
        if store.thread(threadID)?.session(provider, account: account) != store.thread(threadID)?.sessions[provider] {
            store.updateThread(threadID) { $0.activateAccount(account, for: provider) }
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
        guard let factory = registry.provider(provider, account: account) else { throw AgentError.notInstalled(provider) }
        guard let executable = await registry.executable(for: provider) else { throw AgentError.notInstalled(provider) }
        var environment = await registry.environment(for: provider, account: account)
        for key in launchEnvironments.keys.sorted() {
            for (name, value) in launchEnvironments[key]?(threadID) ?? [:] {
                if name == "PATH", let path = environment["PATH"], !path.isEmpty {
                    environment[name] = value + ":" + path
                } else {
                    environment[name] = value
                }
            }
        }
        // Another send may have started (or finished starting) the session while this one waited.
        if let existing = sessions[threadID]?[provider] { return existing }
        if let launch = launches[threadID]?[provider] { return try await join(launch, threadID, provider) }
        guard let thread = store.thread(threadID) else { throw AgentError.notRunning }
        // The thread may have moved to another account while the environment was read; the next send starts that one.
        let resumed = thread.sessions[provider].flatMap { $0.account == account ? $0.sessionID : nil }
        let launch = AgentLaunch(
            provider: provider, executable: executable, environment: environment, workingDirectory: cwd,
            resumeSessionID: resumed, selection: thread.selection,
            accessMode: thread.accessMode, interactionMode: thread.interactionMode,
            instructions: provider.takesSessionInstructions ? thread.botID.flatMap { store.bot($0) }?.instructions : nil)
        let session =
            hostedSession?(threadID, launch, registry.account(account, of: provider)) ?? factory.makeSession(launch)
        launchedAccess[threadID, default: [:]][provider] = launch.accessMode
        launchedAccounts[threadID, default: [:]][provider] = account
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session, self.isCurrent(session, threadID, provider) else { return }
            self.handle(event, threadID: threadID, provider: provider, session: session)
        }
        let task = Task { try await session.start() }
        launches[threadID, default: [:]][provider] = Launch(session: session, task: task)
        lastActivity[threadID, default: [:]][provider] = Date()
        noteSlowStart(of: session, threadID: threadID, provider: provider)
        return try await join(Launch(session: session, task: task), threadID, provider)
    }

    /// How long an agent may take to start before the thread explains the likely reasons.
    var slowStartNoticeDelay: Duration = .seconds(15)

    /// Agents launched by Coincide read their own settings (for example `~/.claude/CLAUDE.md`), which often
    /// live in folders macOS protects. Their reads then wait for the user to let Coincide access that folder,
    /// and macOS shows that prompt only while Coincide is the active app, so a launch that hangs usually means
    /// a prompt is waiting, or was declined.
    private func noteSlowStart(of session: AgentSession, threadID: UUID, provider: ProviderKind) {
        Task { [weak self] in
            try? await Task.sleep(for: self?.slowStartNoticeDelay ?? .seconds(15))
            guard let self, self.launches[threadID]?[provider]?.session === session else { return }
            self.store.append(
                TranscriptItem(
                    kind: .notice,
                    text: String(
                        localized: "\(provider.displayName) is taking a while to start. macOS may be waiting for you to let Coincide access a folder such as Documents, where agent settings often live, and it asks only while Coincide is the active app. You can also grant access in System Settings › Privacy & Security › Files and Folders."),
                    provider: provider),
                to: threadID)
            self.onSlowStart?(threadID, provider)
        }
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

    /// Takes up a session that went on while the app was closed (in the agent host), as if this run had started it.
    /// With `turnWasActive`, the turn it ran when the app left off runs again, opened by the thread's last message:
    /// the events that follow (`AgentHostClient.attach`) continue that turn's items and end it.
    @discardableResult
    public func adopt(_ session: AgentSession, threadID: UUID, turnWasActive: Bool) -> Bool {
        let provider = session.provider
        guard let thread = store.thread(threadID), currentSession(threadID, provider) == nil else { return false }
        sessions[threadID, default: [:]][provider] = session
        launchedAccess[threadID, default: [:]][provider] = thread.accessMode
        launchedAccounts[threadID, default: [:]][provider] = thread.sessions[provider]?.account ?? ProviderAccount.defaultID
        if let id = session.sessionID { liveSessionIDs[threadID, default: [:]][provider] = id }
        lastActivity[threadID, default: [:]][provider] = Date()
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session, self.isCurrent(session, threadID, provider) else { return }
            self.handle(event, threadID: threadID, provider: provider, session: session)
        }
        if turnWasActive, turns[threadID] == nil,
            let start = thread.items.lastIndex(where: { $0.kind == .user && $0.steered != true }),
            thread.items[start].provider == provider
        {
            let user = thread.items[start]
            var state = TurnState(provider: provider, startedAt: user.createdAt, userItemID: user.id, modelID: user.modelID)
            state.isStarting = false
            state.promptSent = true
            state.delivered = true
            let later = thread.items[(start + 1)...]
            state.steeredItemIDs = later.filter { $0.kind == .user && $0.steered == true }.map(\.id)
            // Deltas for the turn's items continue them rather than opening new ones.
            var map: [String: UUID] = [:]
            for item in later where item.provider == provider && [.assistant, .reasoning, .tool].contains(item.kind) {
                if let externalID = item.externalID { map[key(item.kind, externalID)] = item.id }
            }
            itemMaps[threadID] = map
            turns[threadID] = state
        }
        store.notify(.runState(threadID))
        return true
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
            let account = launchedAccount(threadID, provider)
            store.updateThread(threadID) { thread in
                let previous = thread.sessions[provider]
                // A different id means a fresh native session that has seen nothing yet.
                let same = previous?.sessionID == id && previous?.account == account
                thread.sessions[provider] = ProviderSessionRef(
                    sessionID: id, seenItemCount: same ? previous?.seenItemCount ?? 0 : 0, accountID: account,
                    foreignItemsBefore: same ? previous?.foreignItemsBefore : nil)
            }

        case .sessionContinued(let id):
            liveSessionIDs[threadID, default: [:]][provider] = id
            let account = launchedAccount(threadID, provider)
            store.updateThread(threadID) { thread in
                let previous = thread.sessions[provider]
                thread.sessions[provider] = ProviderSessionRef(
                    sessionID: id, seenItemCount: previous?.seenItemCount ?? 0, accountID: account,
                    foreignItemsBefore: previous?.foreignItemsBefore)
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
            preserveGeneratedImage(toolID: existing, output: output, threadID: threadID, provider: provider, modelID: modelID)

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
            if turnOfProvider, var turn = turns[threadID] {
                turn.reportedUsage = value.merged(with: turn.reportedUsage)
                turns[threadID] = turn
            }
            if usageProviders[threadID] != provider { usage[threadID] = nil }
            usageProviders[threadID] = provider
            usage[threadID] = value.merged(with: usage[threadID] ?? TokenUsage())
            store.notify(.runState(threadID))
        case .rateLimits(let windows):
            recordUsageLimits(windows, for: provider, account: launchedAccount(threadID, provider))
        case .modelResolved:
            break
        case .modelsDiscovered(let models):
            registry.updateModels(models, for: provider, account: launchedAccount(threadID, provider))
        case .notice(let text):
            store.append(TranscriptItem(kind: .notice, text: text, provider: provider), to: threadID)
        case .backgroundWork(let tasks):
            setBackgroundWork(tasks, threadID: threadID, provider: provider)
        case .commandsDiscovered(let commands):
            sessionCommands[threadID, default: [:]][provider] = commands
            registry.updateCommands(commands, for: provider, account: launchedAccount(threadID, provider))

        case .agentTurnStarted(let note):
            startAgentTurn(threadID, provider: provider, note: note)
        case .turnCompleted(let outcome):
            // A completion before the prompt was handed over can only be a late one from an abandoned turn.
            guard let turn = turns[threadID], turn.provider == provider, turn.promptSent else { return }
            finishTurn(threadID, turn.userItemID, outcome: outcome)
        case .sessionExited(let error):
            let wasLive = sessions[threadID]?[provider] === session
            if wasLive {
                setBackgroundWork([], threadID: threadID, provider: provider)
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
    func recordUsageLimits(
        _ windows: [UsageLimitWindow], for provider: ProviderKind, account: String? = nil, at date: Date = Date()
    ) -> Bool {
        guard !windows.isEmpty else { return false }
        let account = registry.account(account, of: provider).id
        let current = usageLimits(for: provider, account: account)
        let updated = (current ?? UsageLimits(windows: [], checkedAt: date)).applying(windows, at: date)
        reportedUsageLimits[ChatThread.accountSessionKey(provider, account)] = updated
        guard updated.windows != current?.windows else { return false }
        NotificationCenter.default.post(
            name: Self.usageLimitsChangedNotification, object: self, userInfo: ["provider": provider, "accountID": account])
        return true
    }

    /// The account the thread's live (or starting) session of `provider` runs with.
    private func launchedAccount(_ threadID: UUID, _ provider: ProviderKind) -> String {
        launchedAccounts[threadID]?[provider] ?? ProviderAccount.defaultID
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
        if let projectID = store.summary(threadID)?.projectID {
            let result: UsageRecord.Outcome
            switch outcome {
            case .completed: result = .completed
            case .interrupted: result = .interrupted
            case .failed: result = .failed
            }
            usageHistory.record(UsageRecord(id: turnID, threadID: threadID, projectID: projectID,
                provider: provider, accountID: launchedAccount(threadID, provider), modelID: turn.modelID, startedAt: turn.startedAt, finishedAt: Date(),
                outcome: result, usage: turn.reportedUsage))
        }
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
            // A turn stopped by a usage limit picks up again once it resets, when the user asked for that.
            if store.settings.resumesAfterUsageLimit, scheduledResumes[threadID] == nil,
                let reset = blockingLimitReset(for: provider, account: launchedAccount(threadID, provider))
            {
                resumeAtReset(threadID, at: reset)
            }
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
        if outcome == .completed, !turn.isAgentInitiated {
            ThreadTitles.refreshIfDue(threadID: threadID, store: store, registry: registry)
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
        // A message the user meant for the turn itself is sent even after a stop: it was never meant to wait.
        let proceed =
            outcome == .completed || (turn.isAgentInitiated && !turn.interruptRequested)
            || (outcome == .interrupted && queues[threadID]?.first?.sendsAfterStop == true)
        if proceed, let next = queues[threadID]?.first {
            removeQueued(threadID: threadID, id: next.id)
            Task { await send(threadID: threadID, text: next.text, imagePaths: next.imagePaths, context: next.context) }
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
