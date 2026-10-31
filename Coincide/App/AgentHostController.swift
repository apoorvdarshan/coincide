import AppKit
import CoincideKit
import ServiceManagement

/// Registers Coincide's background agent host (`AgentHostIdentity`) and connects to it, or explains why agents
/// run in the app instead (`AgentHostFallbackReason`). Settings › General shows which.
final class AgentHostController {
    static let shared = AgentHostController()
    /// Posted when `mode` changes.
    static let modeChanged = Notification.Name("coincide.agentHostModeChanged")

    enum Mode: Equatable {
        case connecting
        /// Agents run in the host. `version` is the host's; another build's host is replaced once idle.
        case background(version: String, isOtherBuild: Bool)
        case inApp(AgentHostFallbackReason)
    }

    private(set) var mode: Mode = .connecting {
        didSet {
            guard mode != oldValue else { return }
            NotificationCenter.default.post(name: Self.modeChanged, object: self)
        }
    }
    /// The connection while agents run in the host.
    private(set) var transport: XPCAgentHostTransport?
    /// What the host said when the app connected: its version and the sessions it kept running.
    private(set) var welcome: AgentHostWelcome?
    /// Makes and routes the sessions that run in the host, while connected.
    private(set) var client: AgentHostClient?
    /// Whether what's being applied now happened while the app was away (see `AgentHostClient.isApplyingBacklog`).
    var isApplyingBacklog: Bool { client?.isApplyingBacklog ?? false }
    private var settingsObservation: ObservationToken?
    private var notifiesWhileAppIsClosed: Bool?
    /// Which sessions another process runs (`AgentSessionLocks`), so the app never starts them a second time.
    private let ownership = AgentSessionOwnership()
    /// Routes waiting for the connection being made.
    private var connectionWaiters: [CheckedContinuation<Void, Never>] = []
    /// How long the next attempt to reach a host that didn't answer waits; doubles up to `maximumRetryDelay`.
    private var retryDelay: TimeInterval = 0
    private var isRetryScheduled = false

    private let service = SMAppService.agent(plistName: AgentHostIdentity.plistName)
    private static let turnedOnKey = "AgentHostEnabled"
    private static let launchTimeout: TimeInterval = 1.5
    /// How long a new session waits for a host being connected to before it starts in the app.
    private static let routeWait: TimeInterval = 8
    private static let maximumRetryDelay: TimeInterval = 30

    /// The user's choice in Settings; on unless they turned it off.
    var isTurnedOn: Bool {
        UserDefaults.standard.object(forKey: Self.turnedOnKey) as? Bool ?? true
    }

    private var isDevelopmentBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private var registrationStatus: AgentHostRegistrationStatus {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        default: .notRegistered
        }
    }

    // MARK: Launch

    /// Decides where agents run, before any window shows: the app must know which threads the host still runs
    /// agents for before it reads their transcripts. Waits at most `launchTimeout` for the host.
    func startAtLaunch() {
        let runner = ThreadRunner.shared
        // Before any transcript is read, and whether or not the host answers: a thread whose session another process
        // still runs keeps its unfinished items, which may still finish.
        AppStore.shared.threadsWithHostedAgents.formUnion(ownership.threadsRunningElsewhere())
        runner.sessionLocks = ownership.locks
        runner.sessionRoute = { [weak self] key in await self?.route(for: key) ?? .startInApp }
        connect(waitingForHello: true)
        settingsObservation = AppStore.shared.observe { [weak self] change in
            guard case .settings = change else { return }
            self?.sendHelloIfSettingsChanged()
        }
    }

    /// Checks again, for example after the user allowed Coincide in Login Items.
    func refresh() {
        switch mode {
        case .inApp(.needsApproval), .inApp(.unreachable), .inApp(.registrationFailed):
            connect(waitingForHello: false)
        default:
            break
        }
    }

    private func connect(waitingForHello: Bool) {
        let environment = ProcessInfo.processInfo.environment
        let team = AgentHostIdentity.currentTeam()
        let plan = AgentHostPlan.decide(
            isTurnedOn: isTurnedOn, isDevelopmentBuild: isDevelopmentBuild,
            developmentOptIn: environment["COINCIDE_AGENT_HOST"] == "1", team: team, status: registrationStatus)
        switch plan {
        case .runInApp(let reason):
            mode = .inApp(reason)
            return
        case .registerThenConnect:
            do {
                try service.register()
            } catch {
                // A registration the user turned off fails, and asks for their approval.
                if registrationStatus == .requiresApproval {
                    mode = .inApp(.needsApproval)
                } else if registrationStatus == .notFound {
                    mode = .inApp(.missingFromBundle)
                } else {
                    mode = .inApp(.registrationFailed(error.localizedDescription))
                }
                return
            }
            guard registrationStatus == .enabled else {
                mode = .inApp(registrationStatus == .requiresApproval ? .needsApproval : .missingFromBundle)
                return
            }
        case .connect:
            break
        }
        guard let team else { return }
        let transport = XPCAgentHostTransport(
            requirement: AgentHostIdentity.requirement(identifier: AgentHostIdentity.bundleID, team: team))
        transport.onDisconnect = { [weak self, weak transport] in self?.disconnected(transport) }
        self.transport = transport
        mode = .connecting
        let hello = makeHello()
        if waitingForHello {
            switch transport.helloSynchronously(hello, timeout: Self.launchTimeout) {
            case .welcome(let welcome): connected(welcome, hello: hello, transport: transport)
            case .refused: failToConnect(transport, refused: true)
            case .timedOut: failToConnect(transport, refused: false)
            }
        } else {
            Task {
                if let welcome = try? await transport.hello(hello) {
                    connected(welcome, hello: hello, transport: transport)
                } else {
                    failToConnect(transport, refused: true)
                }
            }
        }
    }

    // MARK: Routing

    /// Where a thread's new session runs (`AgentSessionRoute`). While the host is being connected to, it waits for it
    /// briefly rather than start the agent in the app, where quitting would stop it. A session another process still
    /// runs is never started again here.
    func route(for key: AgentSessionKey) async -> AgentSessionRoute {
        if mode == .connecting, isTurnedOn { await waitForConnection(timeout: Self.routeWait) }
        let host: AgentSessionRoute.Host = client?.isConnected == true && ThreadRunner.shared.hostedSession != nil
            ? .connected(nil) : .unavailable
        let elsewhere = host == .unavailable && ownership.ownerElsewhere(of: key) != nil
        return AgentSessionRoute.decide(host: host, runningElsewhere: elsewhere)
    }

    private func waitForConnection(timeout: TimeInterval) async {
        await withCheckedContinuation { continuation in
            connectionWaiters.append(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.resumeWaiters() }
        }
    }

    private func resumeWaiters() {
        let waiters = connectionWaiters
        connectionWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Tries again later, waiting longer each time, for as long as the host should be used and isn't.
    private func scheduleRetry(after delay: TimeInterval? = nil) {
        guard !isRetryScheduled else { return }
        retryDelay = delay ?? min(max(retryDelay * 2, 2), Self.maximumRetryDelay)
        isRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self else { return }
            self.isRetryScheduled = false
            guard self.transport == nil, self.isTurnedOn else { return }
            switch self.mode {
            case .inApp(.unreachable), .inApp(.incompatibleHostBusy): self.connect(waitingForHello: false)
            default: break
            }
        }
    }

    private func connected(_ welcome: AgentHostWelcome, hello: AgentHostHello, transport: XPCAgentHostTransport) {
        guard self.transport === transport else { return }
        defer { resumeWaiters() }
        retryDelay = 0
        switch AgentHostCompatibility.evaluate(app: hello, host: welcome) {
        case .use:
            use(transport, welcome: welcome)
            mode = .background(version: welcome.version, isOtherBuild: false)
        case .useAndReplaceWhenIdle:
            // An update keeps the host it found running mid-turn; it gives way to this build's once idle.
            use(transport, welcome: welcome)
            transport.retireWhenIdle()
            mode = .background(version: welcome.version, isOtherBuild: true)
        case .replaceNow:
            // Nothing runs in it: it exits at once, and launchd starts this build's host on the next message.
            transport.retireWhenIdle()
            self.transport = nil
            transport.onDisconnect = nil
            transport.invalidate()
            mode = .inApp(.unreachable)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect(waitingForHello: false) }
        case .runInProcessUntilIdle:
            transport.retireWhenIdle()
            self.transport = nil
            transport.onDisconnect = nil
            transport.invalidate()
            // Its sessions go on there (the locks keep the app from starting them again), and it exits once they
            // finish: then this build's host answers.
            mode = .inApp(.incompatibleHostBusy)
            scheduleRetry(after: Self.maximumRetryDelay)
        }
    }

    /// Runs new sessions in the host and takes up the ones it kept while the app was away.
    private func use(_ transport: XPCAgentHostTransport, welcome: AgentHostWelcome) {
        self.welcome = welcome
        let client = AgentHostClient(transport: transport)
        client.onDisconnect = { [weak self, weak transport] in self?.disconnected(transport) }
        self.client = client
        let store = AppStore.shared
        let runner = ThreadRunner.shared
        // Before their transcripts are read: their unfinished items may still finish.
        store.threadsWithHostedAgents.formUnion(welcome.sessions.map(\.key.threadID))
        runner.hostedSession = { [weak client] threadID, launch, account in
            client?.makeSession(
                key: AgentSessionKey(threadID: threadID, provider: launch.provider), launch: launch, account: account,
                thread: { Self.threadInfo(threadID) })
        }
        for info in welcome.sessions {
            let threadID = info.key.threadID
            guard store.hasThread(threadID) else {
                // Deleted while its agent went on: nothing to show it in.
                client.discard(info.key)
                continue
            }
            let session = client.adopt(info, thread: { Self.threadInfo(threadID) })
            // With events to catch up on, the turn's state is the one the app left off at; otherwise the current one.
            let turnWasActive = info.hasBacklog ? info.turnWasActiveAtAcknowledged : info.isTurnActive
            guard runner.adopt(session, threadID: threadID, turnWasActive: turnWasActive) else {
                // This run already has a session there (a reconnect after the app started one in-process).
                client.discard(info.key)
                continue
            }
            Task { await client.attach(session) }
        }
    }

    /// Names a thread for the host's notifications.
    private static func threadInfo(_ threadID: UUID) -> AgentHostThreadInfo {
        let store = AppStore.shared
        let summary = store.summary(threadID)
        return AgentHostThreadInfo(
            title: summary?.title ?? "", projectName: summary.flatMap { store.project($0.projectID)?.name })
    }

    /// Lets the host know how far the app got before it exits. Call after `ThreadRunner.shutdownAll()`.
    func prepareToQuit() {
        client?.flushAcknowledgements()
    }

    /// The host didn't answer, or answered in a way the app refused. The app keeps trying, and until it gets through,
    /// sessions another process still runs are left alone (`route`).
    private func failToConnect(_ transport: XPCAgentHostTransport, refused: Bool) {
        guard self.transport === transport else { return }
        self.transport = nil
        transport.onDisconnect = nil
        transport.invalidate()
        if refused, !AgentHostLegacyOwnership.runningHostPIDs().isEmpty {
            // A host runs, yet the app refused it: an update replaced its files while it ran (a host from before
            // hosts ran from their own copy), so its signature no longer checks out. It goes on running its agents;
            // asked to, it exits once they finish, and this build's host starts on the next attempt.
            XPCAgentHostTransport.retireUnverifiedHost()
            mode = .inApp(.incompatibleHostBusy)
        } else {
            mode = .inApp(.unreachable)
        }
        resumeWaiters()
        scheduleRetry()
    }

    /// The host exited (idle, retired, or crashed): the next need connects again.
    private func disconnected(_ transport: XPCAgentHostTransport?) {
        guard let transport, self.transport === transport else { return }
        self.transport = nil
        welcome = nil
        client = nil
        ThreadRunner.shared.hostedSession = nil
        guard isTurnedOn else {
            // Turned off, the host exited once nothing ran in it, so it can go without stopping an agent.
            mode = .inApp(.turnedOff)
            if registrationStatus == .enabled { Task { [service] in try? await service.unregister() } }
            return
        }
        mode = .connecting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.transport == nil, self.isTurnedOn else { return }
            self.connect(waitingForHello: false)
        }
    }

    private func makeHello() -> AgentHostHello {
        let info = Bundle.main.infoDictionary ?? [:]
        let notifies = AppStore.shared.settings.notifyWhenInBackground
        notifiesWhileAppIsClosed = notifies
        return AgentHostHello(
            build: info["CFBundleVersion"] as? String ?? "0", version: info["CFBundleShortVersionString"] as? String ?? "0",
            notifiesWhileAppIsClosed: notifies)
    }

    /// The host learns the notification setting from the hello, so a change is sent as a new one.
    private func sendHelloIfSettingsChanged() {
        guard let transport, AppStore.shared.settings.notifyWhenInBackground != notifiesWhileAppIsClosed else { return }
        let hello = makeHello()
        Task { _ = try? await transport.hello(hello) }
    }

    // MARK: Settings

    func setTurnedOn(_ isOn: Bool) {
        guard isOn != isTurnedOn else { return }
        UserDefaults.standard.set(isOn, forKey: Self.turnedOnKey)
        if isOn {
            // A host told to retire a moment ago exits once idle; the app connects to a fresh one then.
            if transport == nil { connect(waitingForHello: false) } else { mode = .connecting }
            return
        }
        // Agents already in the host finish there, still answered from here, and it exits once idle; unregistering
        // now would stop them. Once it exits (`disconnected`), it is unregistered.
        let previous = mode
        mode = .inApp(.turnedOff)
        ThreadRunner.shared.hostedSession = nil
        if let transport {
            transport.retireWhenIdle()
        } else if previous != .inApp(.incompatibleHostBusy), registrationStatus == .enabled {
            Task { [service] in try? await service.unregister() }
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
