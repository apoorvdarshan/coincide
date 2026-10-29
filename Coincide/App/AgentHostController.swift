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
    private var settingsObservation: ObservationToken?
    private var notifiesWhileAppIsClosed: Bool?

    private let service = SMAppService.agent(plistName: AgentHostIdentity.plistName)
    private static let turnedOnKey = "AgentHostEnabled"
    private static let launchTimeout: TimeInterval = 1.5

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
            if let welcome = transport.helloSynchronously(hello, timeout: Self.launchTimeout) {
                connected(welcome, hello: hello, transport: transport)
            } else {
                failToConnect(transport)
            }
        } else {
            Task {
                if let welcome = try? await transport.hello(hello) {
                    connected(welcome, hello: hello, transport: transport)
                } else {
                    failToConnect(transport)
                }
            }
        }
    }

    private func connected(_ welcome: AgentHostWelcome, hello: AgentHostHello, transport: XPCAgentHostTransport) {
        guard self.transport === transport else { return }
        switch AgentHostCompatibility.evaluate(app: hello, host: welcome) {
        case .use:
            self.welcome = welcome
            mode = .background(version: welcome.version, isOtherBuild: false)
        case .useAndReplaceWhenIdle:
            // An update keeps the host it found running mid-turn; it gives way to this build's once idle.
            self.welcome = welcome
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
            mode = .inApp(.incompatibleHostBusy)
        }
    }

    private func failToConnect(_ transport: XPCAgentHostTransport) {
        guard self.transport === transport else { return }
        self.transport = nil
        transport.onDisconnect = nil
        transport.invalidate()
        mode = .inApp(.unreachable)
    }

    /// The host exited (idle, retired, or crashed): the next need connects again.
    private func disconnected(_ transport: XPCAgentHostTransport?) {
        guard let transport, self.transport === transport else { return }
        self.transport = nil
        welcome = nil
        mode = .connecting
        guard isTurnedOn else {
            mode = .inApp(.turnedOff)
            return
        }
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
            connect(waitingForHello: false)
            return
        }
        // Agents already in the host finish there, and it exits once idle. Unregistering would stop them at once,
        // so it waits for a host with nothing running; one that still has work stays listed until a later launch.
        let previous = mode
        mode = .inApp(.turnedOff)
        welcome = nil
        guard let transport else {
            if previous != .inApp(.incompatibleHostBusy), registrationStatus == .enabled { try? service.unregister() }
            return
        }
        self.transport = nil
        transport.onDisconnect = nil
        Task { [service] in
            var isBusy = true
            if case .sessions(let sessions) = try? await transport.perform(.list) {
                isBusy = sessions.contains { session in
                    session.isLive
                        && (session.isTurnActive || session.hasBackgroundWork || !session.pendingApprovals.isEmpty
                            || !session.pendingQuestions.isEmpty)
                }
            }
            transport.retireWhenIdle()
            transport.invalidate()
            if !isBusy { try? await service.unregister() }
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
