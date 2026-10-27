import Foundation

/// Drives provider sessions for threads and turns their events into transcript items.
///
/// Each thread can have one live session per provider. Switching provider mid-thread keeps the
/// other sessions (and their native ids) around; the next provider receives a recap of the turns
/// it missed (see `Handoff`).
@MainActor
public final class ThreadRunner {
    public static let shared = ThreadRunner(store: .shared, registry: .shared)

    public struct TurnState: Sendable {
        public var provider: ProviderKind
        public var startedAt: Date
        public var userItemID: UUID
        var planItemID: UUID?
        var interruptRequested = false
    }

    private let store: AppStore
    private let registry: ProviderRegistry
    private var sessions: [UUID: [ProviderKind: AgentSession]] = [:]
    private var lastActivity: [UUID: [ProviderKind: Date]] = [:]
    /// Provider item id ("kind:id") to transcript item id, per thread.
    private var itemMaps: [UUID: [String: UUID]] = [:]
    public private(set) var turns: [UUID: TurnState] = [:]
    public private(set) var usage: [UUID: TokenUsage] = [:]
    private var starting: Set<UUID> = []
    private var idleTimer: Timer?

    /// Called when a turn ends. The app uses it for notifications.
    public var onTurnFinished: ((UUID, TurnOutcome) -> Void)?
    /// Called when an agent asks for approval.
    public var onApprovalRequested: ((UUID, ApprovalRequest) -> Void)?

    public init(store: AppStore, registry: ProviderRegistry) {
        self.store = store
        self.registry = registry
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutDownIdleSessions() }
        }
    }

    // MARK: State

    public func isRunning(_ threadID: UUID) -> Bool { turns[threadID] != nil || starting.contains(threadID) }

    /// True while the session is being spawned, before the turn is accepted.
    public func isStarting(_ threadID: UUID) -> Bool { starting.contains(threadID) }

    public func turn(_ threadID: UUID) -> TurnState? { turns[threadID] }

    public var runningThreadIDs: [UUID] { Array(Set(turns.keys).union(starting)) }

    /// Providers with a live process for the thread.
    public func liveProviders(_ threadID: UUID) -> [ProviderKind] {
        (sessions[threadID] ?? [:]).keys.sorted { $0.rawValue < $1.rawValue }
    }

    /// Approval items still waiting for an answer.
    public func pendingApprovals(_ threadID: UUID) -> [TranscriptItem] {
        store.thread(threadID)?.items.filter { $0.kind == .approval && $0.status == .waiting } ?? []
    }

    // MARK: Turns

    /// Sends a user message on the thread's selected provider and model.
    public func send(threadID: UUID, text: String, imagePaths: [String] = []) async {
        guard !isRunning(threadID), let thread = store.thread(threadID), store.project(thread.projectID) != nil else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !imagePaths.isEmpty else { return }
        let selection = thread.selection
        let provider = selection.provider

        if !thread.hasUserMessages {
            store.updateThread(threadID) { $0.title = Self.title(from: trimmed) }
        }
        let userItem = TranscriptItem(
            kind: .user, text: trimmed, provider: provider, modelID: selection.modelID,
            attachments: imagePaths.isEmpty ? nil : imagePaths)
        let userIndex = store.thread(threadID)?.items.count ?? 0
        store.append(userItem, to: threadID)
        store.updateThread(threadID, touch: true) { $0.draft = nil }
        itemMaps[threadID] = [:]
        starting.insert(threadID)
        turns[threadID] = TurnState(provider: provider, startedAt: Date(), userItemID: userItem.id)
        store.notify(.runState(threadID))

        guard let cwd = store.workingDirectory(for: threadID) else {
            starting.remove(threadID)
            finishTurn(threadID, provider: provider, outcome: .failed(String(localized: "The project folder is missing.")))
            return
        }

        do {
            let session = try await session(for: threadID, provider: provider, cwd: cwd)
            if store.settings.checkpointsEnabled {
                await CheckpointService.shared.captureBeforeTurn(threadID: threadID, userItemID: userItem.id, cwd: cwd)
            }
            // The recap covers what this provider missed before the new message.
            guard var snapshot = store.thread(threadID) else { return }
            snapshot.items = Array(snapshot.items.prefix(userIndex))
            let prompt = Handoff.prompt(for: trimmed, thread: snapshot, provider: provider)
            let input = AgentTurnInput(
                text: prompt, imagePaths: imagePaths, selection: selection, accessMode: snapshot.accessMode,
                interactionMode: snapshot.interactionMode)
            starting.remove(threadID)
            store.notify(.runState(threadID))
            guard turns[threadID]?.userItemID == userItem.id, turns[threadID]?.interruptRequested == false else {
                finishTurn(threadID, provider: provider, outcome: .interrupted)
                return
            }
            try await session.send(input)
        } catch {
            starting.remove(threadID)
            finishTurn(threadID, provider: provider, outcome: .failed(error.localizedDescription))
        }
    }

    /// Stops the running turn on the thread.
    public func stop(threadID: UUID) {
        guard let turn = turns[threadID] else { return }
        turns[threadID]?.interruptRequested = true
        if let session = sessions[threadID]?[turn.provider], !starting.contains(threadID) {
            session.interrupt()
        }
        // Providers should confirm with `.turnCompleted(.interrupted)`; don't wait forever.
        let startedAt = turn.startedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, let current = self.turns[threadID], current.startedAt == startedAt else { return }
            self.finishTurn(threadID, provider: current.provider, outcome: .interrupted)
        }
    }

    /// Answers an approval item.
    public func respond(threadID: UUID, itemID: UUID, optionID: String) {
        guard let item = store.item(itemID, in: threadID), let approval = item.approval, item.status == .waiting,
            let provider = item.provider
        else { return }
        let option = approval.options.first { $0.id == optionID }
        sessions[threadID]?[provider]?.respond(to: approval.requestID, optionID: optionID)
        store.updateItem(itemID, in: threadID) { item in
            item.approval?.resolution = option?.label ?? optionID
            item.status = (option?.kind == .deny || option?.kind == .cancel) ? .declined : .completed
            item.completedAt = Date()
        }
    }

    /// Ends every session of a thread (for example when it is deleted or its folder changes).
    public func shutdown(threadID: UUID) {
        if let turn = turns[threadID] { finishTurn(threadID, provider: turn.provider, outcome: .interrupted) }
        for session in (sessions[threadID] ?? [:]).values { session.shutdown() }
        sessions[threadID] = nil
        lastActivity[threadID] = nil
        itemMaps[threadID] = nil
    }

    /// Ends one provider's session for a thread; its id is kept so the next turn resumes it.
    public func shutdown(threadID: UUID, provider: ProviderKind) {
        sessions[threadID]?[provider]?.shutdown()
        sessions[threadID]?[provider] = nil
    }

    public func shutdownAll() {
        for threadID in Array(sessions.keys) { shutdown(threadID: threadID) }
    }

    // MARK: Sessions

    private func session(for threadID: UUID, provider: ProviderKind, cwd: URL) async throws -> AgentSession {
        if let existing = sessions[threadID]?[provider] { return existing }
        guard let factory = registry.provider(provider) else { throw AgentError.notInstalled(provider) }
        guard let executable = await registry.executable(for: provider) else { throw AgentError.notInstalled(provider) }
        let environment = await registry.environment(for: provider)
        guard let thread = store.thread(threadID) else { throw AgentError.notRunning }
        let launch = AgentLaunch(
            provider: provider, executable: executable, environment: environment, workingDirectory: cwd,
            resumeSessionID: thread.sessions[provider]?.sessionID, selection: thread.selection,
            accessMode: thread.accessMode, interactionMode: thread.interactionMode)
        let session = factory.makeSession(launch)
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session else { return }
            self.handle(event, threadID: threadID, provider: provider, session: session)
        }
        sessions[threadID, default: [:]][provider] = session
        lastActivity[threadID, default: [:]][provider] = Date()
        do {
            try await session.start()
        } catch {
            if sessions[threadID]?[provider] === session { sessions[threadID]?[provider] = nil }
            session.shutdown()
            throw error
        }
        return session
    }

    private func shutDownIdleSessions() {
        let limit = TimeInterval(max(1, store.settings.idleSessionTimeoutMinutes) * 60)
        let now = Date()
        for (threadID, providers) in sessions {
            for (provider, session) in providers {
                if turns[threadID]?.provider == provider { continue }
                let last = lastActivity[threadID]?[provider] ?? .distantPast
                if now.timeIntervalSince(last) > limit {
                    session.shutdown()
                    sessions[threadID]?[provider] = nil
                }
            }
        }
    }

    // MARK: Events

    private func handle(_ event: AgentEvent, threadID: UUID, provider: ProviderKind, session: AgentSession) {
        lastActivity[threadID, default: [:]][provider] = Date()
        let modelID = store.thread(threadID)?.selection.modelID
        switch event {
        case .sessionStarted(let id):
            store.updateThread(threadID) { thread in
                let previous = thread.sessions[provider]
                // A different id means a fresh native session that has seen nothing yet.
                let seen = previous?.sessionID == id ? previous?.seenItemCount ?? 0 : 0
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
            guard let existing = mappedItem(.tool, id, threadID) else { return }
            store.updateItem(existing, in: threadID) { item in
                item.text += delta
                if item.text.count > 200_000 { item.text = String(item.text.suffix(150_000)) }
            }
        case .toolCompleted(let id, let status, let output):
            guard let existing = mappedItem(.tool, id, threadID) else { return }
            store.updateItem(existing, in: threadID) { item in
                item.status = status
                item.completedAt = Date()
                if let output, !output.isEmpty { item.text = output }
            }

        case .approvalRequested(let request):
            let item = TranscriptItem(
                kind: .approval, title: request.title, detail: request.detail, category: request.category,
                status: .waiting, provider: provider, modelID: modelID, externalID: request.id,
                approval: ApprovalInfo(requestID: request.id, options: request.options))
            store.append(item, to: threadID)
            onApprovalRequested?(threadID, request)
        case .approvalResolved(let id):
            guard
                let item = store.thread(threadID)?.items.last(where: {
                    $0.kind == .approval && $0.approval?.requestID == id && $0.status == .waiting
                })
            else { return }
            store.updateItem(item.id, in: threadID) { item in
                item.status = .completed
                item.approval?.resolution = String(localized: "Resolved by the agent")
                item.completedAt = Date()
            }

        case .plan(let text):
            if let planID = turns[threadID]?.planItemID, store.item(planID, in: threadID) != nil {
                store.updateItem(planID, in: threadID) { $0.text = text }
            } else {
                let item = TranscriptItem(kind: .plan, text: text, provider: provider, modelID: modelID)
                turns[threadID]?.planItemID = item.id
                store.append(item, to: threadID)
            }

        case .usage(let value):
            usage[threadID] = value.merged(with: usage[threadID] ?? TokenUsage())
            store.notify(.runState(threadID))
        case .modelResolved:
            break
        case .modelsDiscovered(let models):
            registry.updateModels(models, for: provider)
        case .notice(let text):
            store.append(TranscriptItem(kind: .notice, text: text, provider: provider), to: threadID)

        case .turnCompleted(let outcome):
            guard turns[threadID]?.provider == provider else { return }
            finishTurn(threadID, provider: provider, outcome: outcome)
        case .sessionExited(let error):
            if sessions[threadID]?[provider] === session { sessions[threadID]?[provider] = nil }
            if turns[threadID]?.provider == provider, !starting.contains(threadID) {
                let message = error ?? String(localized: "\(provider.displayName) exited unexpectedly.")
                finishTurn(threadID, provider: provider, outcome: .failed(message))
            }
        }
    }

    private func finishTurn(_ threadID: UUID, provider: ProviderKind, outcome: TurnOutcome) {
        guard let turn = turns[threadID] else { return }
        turns[threadID] = nil
        starting.remove(threadID)
        if let thread = store.thread(threadID), let start = thread.items.firstIndex(where: { $0.id == turn.userItemID }) {
            for item in thread.items[start...] {
                guard item.status == .running || item.status == .waiting else { continue }
                store.updateItem(item.id, in: threadID) { item in
                    switch item.kind {
                    case .approval: item.status = .declined
                    case .tool: item.status = outcome == .completed ? .completed : .failed
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
        store.updateThread(threadID, touch: true) { thread in
            if var ref = thread.sessions[provider] {
                ref.seenItemCount = thread.items.count
                thread.sessions[provider] = ref
            }
        }
        store.notify(.runState(threadID))
        if store.settings.checkpointsEnabled, let cwd = store.workingDirectory(for: threadID) {
            let userItemID = turn.userItemID
            Task { await CheckpointService.shared.captureAfterTurn(threadID: threadID, userItemID: userItemID, cwd: cwd) }
        }
        onTurnFinished?(threadID, outcome)
    }

    // MARK: Item mapping

    private func key(_ kind: TranscriptItem.Kind, _ externalID: String) -> String { "\(kind.rawValue):\(externalID)" }

    private func mappedItem(_ kind: TranscriptItem.Kind, _ externalID: String, _ threadID: UUID) -> UUID? {
        guard let id = itemMaps[threadID]?[key(kind, externalID)], store.item(id, in: threadID) != nil else { return nil }
        return id
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
            let item = TranscriptItem(
                kind: kind, text: delta, status: .running, provider: provider, modelID: modelID, externalID: externalID)
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
