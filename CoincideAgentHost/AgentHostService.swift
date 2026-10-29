import AppKit
import CoincideKit
import UserNotifications

/// Listens on the host's Mach service and hands each app connection to the engine (`AgentHostCore`).
final class AgentHostService: NSObject, NSXPCListenerDelegate {
    private let listener = NSXPCListener(machServiceName: AgentHostIdentity.machServiceName)
    /// Only apps signed by the host's own team may connect; a host without one accepts nobody.
    private nonisolated let team = AgentHostIdentity.currentTeam()
    private let notifier = AgentHostNotifier()
    private var timer: Timer?
    let core: AgentHostCore

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let providers = AgentHostProviders()
        core = AgentHostCore(
            logDirectory: AgentHostPaths.directory(), build: info["CFBundleVersion"] as? String ?? "0",
            version: info["CFBundleShortVersionString"] as? String ?? "0"
        ) { launch, account in providers.provider(for: account)?.makeSession(launch) }
        super.init()
        core.onAttention = { [notifier] in notifier.post($0) }
        core.onExit = {
            AgentHostCore.terminateChildProcesses()
            exit(0)
        }
    }

    func start() {
        notifier.start()
        listener.delegate = self
        listener.resume()
        // Background work ends without an event, and the idle grace runs out without one.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.core.evaluateLifecycle() }
        }
        // Started for nothing (a connection that went away at once): exit after the grace like any idle host.
        core.evaluateLifecycle()
    }

    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let team else { return false }
        connection.setCodeSigningRequirement(AgentHostIdentity.requirement(identifier: AgentHostIdentity.appBundleID, team: team))
        let handler = AgentHostConnection(connection: connection)
        connection.exportedInterface = NSXPCInterface(with: AgentHostXPC.self)
        connection.exportedObject = handler
        connection.remoteObjectInterface = NSXPCInterface(with: AgentHostClientXPC.self)
        connection.invalidationHandler = { DispatchQueue.main.async { MainActor.assumeIsolated { handler.close() } } }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        // Queued before the connection can deliver anything, so the engine knows the app before its first message.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler.open(core: self.core) }
        }
        connection.resume()
        return true
    }
}

/// The providers Coincide ships, one per account as the app's registry makes them. Sessions get everything else
/// (executable, environment, model, access) from the app in their `AgentLaunch`.
final class AgentHostProviders {
    private var byAccount: [String: AgentProvider] = [:]

    func provider(for account: ProviderAccount) -> AgentProvider? {
        let key = "\(account.provider.rawValue)/\(account.id)"
        if let existing = byAccount[key] { return existing }
        // Cursor reads the Keychain only to check usage, which the app does; sessions never need it.
        let made = ProviderRegistry.builtInProvider(
            for: account, dataDirectory: AppStore.defaultDirectory, cursorKeychainUsageAllowed: { false })
        byAccount[key] = made
        return made
    }
}

/// One app's connection: its messages go to the engine on the main actor, in the order they came.
final class AgentHostConnection: NSObject, AgentHostXPC, AgentHostSubscriber {
    // Set once, before the connection resumes; read on the main actor afterwards.
    nonisolated(unsafe) private weak var connection: NSXPCConnection?
    private var core: AgentHostCore?
    private var client: AgentHostCore.Client?

    nonisolated init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func open(core: AgentHostCore) {
        self.core = core
        client = core.connect(self)
    }

    func close() {
        guard let core, let client else { return }
        self.client = nil
        core.disconnect(client)
        connection?.exportedObject = nil
    }

    func deliver(_ push: AgentHostPush) {
        guard let data = try? AgentHostWire.encode(push) else { return }
        (connection?.remoteObjectProxy as? AgentHostClientXPC)?.receive(data)
    }

    nonisolated func hello(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let core = self.core, let hello = try? AgentHostWire.decode(AgentHostHello.self, from: request),
                    let data = try? AgentHostWire.encode(core.hello(hello))
                else { return reply(Data()) }
                reply(data)
            }
        }
    }

    nonisolated func perform(_ command: Data, reply: @escaping @Sendable (Data) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let core = self.core, let client = self.client else {
                    return reply(Self.encode(.failure(AgentHostError.disconnected.localizedDescription)))
                }
                guard let decoded = try? AgentHostWire.decode(AgentHostCommand.self, from: command) else {
                    // From a newer app: refused rather than misread.
                    return reply(Self.encode(.failure(String(localized: "This agent host doesn’t know that command."))))
                }
                // Started synchronously on the main actor, so commands reach their sessions in the order they came.
                Task { @MainActor in
                    reply(Self.encode(await core.perform(decoded, from: client)))
                }
            }
        }
    }

    nonisolated func retireWhenIdle() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.core?.retireWhenIdle() } }
    }

    private nonisolated static func encode(_ reply: AgentHostReply) -> Data {
        (try? AgentHostWire.encode(reply)) ?? Data()
    }
}

/// Tells the user what their agents need while Coincide is closed, and opens Coincide when a notification is clicked.
final class AgentHostNotifier: NSObject, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter { .current() }

    func start() {
        center.delegate = self
    }

    func post(_ attention: AgentHostAttention) {
        let agent = attention.key.provider.displayName
        let event: String
        var body: String?
        switch attention.kind {
        case .approval(let title):
            event = String(localized: "\(agent) needs approval")
            body = title
        case .question(let title):
            event = String(localized: "\(agent) has a question")
            body = title
        case .finished:
            event = String(localized: "\(agent) finished")
        case .failed(let message):
            event = String(localized: "\(agent) failed")
            body = message
        }
        let content = UNMutableNotificationContent()
        content.title = attention.thread.title.isEmpty ? String(localized: "Coincide") : attention.thread.title
        content.subtitle = attention.thread.projectName.map { String(localized: "\(event) in \($0)") } ?? event
        if let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            content.body = String(body.prefix(240))
        }
        content.sound = .default
        content.threadIdentifier = attention.key.threadID.uuidString
        let request = UNNotificationRequest(
            identifier: "\(attention.key.threadID.uuidString).\(attention.key.provider.rawValue)", content: content, trigger: nil)
        let center = center
        Task {
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: break
            case .notDetermined:
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            default: return
            }
            try? await center.add(request)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        // Coincide.app, three folders up from Contents/Helpers/CoincideAgentHost.app. It catches up on launch.
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
