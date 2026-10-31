import CoincideKit
import CoincideRemoteKit
import Foundation

/// How a session talks to its phone. The server's WebSocket connections are one; tests supply their own.
@MainActor
protocol RemoteTransport: AnyObject {
    /// The address the connection came from, for rate limiting.
    var peer: String { get }
    func send(_ data: Data)
    func close()
}

/// One phone's connection: authenticates it, answers its requests through the store adapter, and passes on what
/// changes in the threads it has open.
///
/// Nothing but `hello` or `pair` is accepted until the phone has authenticated; anything else, or no `hello` within
/// `authenticationTimeout`, closes the connection. Changes are batched: transcript updates go out at most every
/// `itemInterval` (streaming text arrives many times a second), the sidebar at most every `workspaceInterval`.
@MainActor
final class RemoteSession {
    enum State: Equatable {
        case awaitingAuthentication
        case authenticated(deviceID: String)
        case closed
    }

    static let authenticationTimeout: Duration = .seconds(10)
    var itemInterval: Duration = .milliseconds(80)
    var workspaceInterval: Duration = .milliseconds(300)

    private(set) var state = State.awaitingAuthentication
    private weak var transport: RemoteTransport?
    private let adapter: RemoteStoreAdapter
    private let pairing: RemotePairing
    private let serverInfo: () -> RemoteServerInfo
    /// Called once the session ends, so the server can forget it.
    var onClose: ((RemoteSession) -> Void)?
    /// Called after a phone pairs, so Settings can close its QR code.
    var onPaired: ((RemoteDevice) -> Void)?
    /// Called when the phone reports its presence, so the server can remember its lock-screen alert setting.
    var onPresence: ((RemoteSession, RemotePresence) -> Void)?
    /// The clock presence is stamped with; tests set their own.
    var now: () -> Date = Date.init

    /// What the phone last said about itself; nil from a phone that never did (one older than notification routing),
    /// which therefore never gets alerts or clears.
    private(set) var presence: DevicePresence?

    private var observation: ObservationHandle?
    private var openThreads: Set<UUID> = []
    private var includesArchived = false
    private var pendingItems: [UUID: Set<UUID>] = [:]
    private var pendingResets: Set<UUID> = []
    private var pendingTurns: Set<UUID> = []
    private var workspaceDirty = false
    private var serverDirty = false
    /// The phone asked for Settings, so it hears when they change.
    private var followsSettings = false
    private var lastSettings: RemoteSettingsSnapshot?
    private var itemFlush: Task<Void, Never>?
    private var workspaceFlush: Task<Void, Never>?
    private var lastWorkspace: RemoteWorkspace?
    private var authenticationTimer: Task<Void, Never>?

    /// Opens a thread in the Mac's window, for `showThread` on a local session.
    var onShowThread: ((UUID) -> Void)?
    /// A session over the Mac's own command-line socket (`LocalControlServer`): trusted from the start, since only the
    /// same user can connect, and allowed `showThread`.
    let isLocal: Bool

    init(transport: RemoteTransport, adapter: RemoteStoreAdapter, pairing: RemotePairing, serverInfo: @escaping () -> RemoteServerInfo) {
        self.transport = transport
        self.adapter = adapter
        self.pairing = pairing
        self.serverInfo = serverInfo
        isLocal = false
    }

    /// A local session, authenticated as `deviceID` without pairing.
    init(localTransport: RemoteTransport, adapter: RemoteStoreAdapter, deviceID: String, serverInfo: @escaping () -> RemoteServerInfo) {
        transport = localTransport
        self.adapter = adapter
        pairing = RemotePairing(storage: MemoryRemoteDeviceStorage())
        self.serverInfo = serverInfo
        isLocal = true
        state = .authenticated(deviceID: deviceID)
        observation = adapter.observe { [weak self] change in self?.note(change) }
    }

    /// Starts the clock for authentication.
    func start() {
        guard state == .awaitingAuthentication else { return }
        authenticationTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.authenticationTimeout)
            guard let self, !Task.isCancelled, self.state == .awaitingAuthentication else { return }
            self.fail(nil, RemoteError(.unauthorized, String(localized: "Authentication timed out.")), closing: true)
        }
    }

    var deviceID: String? {
        if case .authenticated(let id) = state { return id }
        return nil
    }

    func close() {
        guard state != .closed else { return }
        state = .closed
        observation = nil
        itemFlush?.cancel()
        workspaceFlush?.cancel()
        authenticationTimer?.cancel()
        transport?.close()
        onClose?(self)
    }

    /// Tells a phone whose pairing was revoked to forget it, and hangs up.
    func revoke() {
        send(.event(.revoked))
        close()
    }

    // MARK: Receiving

    func receive(_ data: Data) {
        guard state != .closed else { return }
        let message: RemoteClientMessage
        do {
            message = try RemoteProtocol.makeDecoder().decode(RemoteClientMessage.self, from: data)
        } catch {
            let id = (try? JSONDecoder().decode(MessageID.self, from: data))?.id
            let remote: RemoteError
            switch error as? RemoteProtocolError {
            case .unsupported(let type)?: remote = RemoteError(.unsupported, "Unsupported request “\(type)”.")
            case .version(let version)?: remote = RemoteError(.unsupported, "Unsupported protocol version \(version).")
            default: remote = RemoteError(.badRequest, "The request couldn’t be read.")
            }
            // Before authentication, anything unreadable ends the connection.
            fail(id, remote, closing: state == .awaitingAuthentication)
            return
        }
        handle(message)
    }

    private struct MessageID: Decodable { var id: String }

    private func handle(_ message: RemoteClientMessage) {
        let id = message.id
        switch (state, message.request) {
        case (.awaitingAuthentication, .hello(let hello)):
            switch pairing.authenticate(deviceID: hello.deviceID, token: hello.token, peer: peer) {
            case .success(let device):
                authenticated(device)
                respond(id, .server(serverInfo()))
            case .failure(let error):
                fail(id, error, closing: true)
            }
        case (.awaitingAuthentication, .pair(let request)):
            switch pairing.pair(secret: request.secret, deviceName: request.deviceName, peer: peer) {
            case .success(let (device, token)):
                authenticated(device)
                respond(id, .paired(RemotePairResult(deviceID: device.id, token: token, server: serverInfo())))
                onPaired?(device)
            case .failure(let error):
                fail(id, error, closing: true)
            }
        case (.awaitingAuthentication, _):
            fail(id, RemoteError(.unauthorized, String(localized: "Pair this device first.")), closing: true)
        case (.authenticated, .hello), (.authenticated, .pair):
            fail(id, RemoteError(.badRequest, "Already authenticated."), closing: false)
        case (.authenticated, let request):
            perform(request, id: id)
        case (.closed, _):
            break
        }
    }

    private var peer: String { transport?.peer ?? "unknown" }

    private func authenticated(_ device: RemoteDevice) {
        authenticationTimer?.cancel()
        state = .authenticated(deviceID: device.id)
        observation = adapter.observe { [weak self] change in self?.note(change) }
    }

    // MARK: Requests

    private func perform(_ request: RemoteRequest, id: String) {
        do {
            switch request {
            case .hello, .pair:
                break
            case .ping:
                respond(id, .ok)
            case .workspace(let includeArchived):
                includesArchived = includeArchived
                let workspace = adapter.workspace(includeArchived: includeArchived)
                lastWorkspace = workspace
                workspaceDirty = false
                respond(id, .workspace(workspace))
            case .openThread(let threadID, let limit):
                guard let transcript = adapter.transcript(threadID, limit: limit) else { throw notFound }
                openThreads.insert(threadID)
                pendingItems[threadID] = nil
                pendingResets.remove(threadID)
                respond(id, .transcript(transcript))
            case .closeThread(let threadID):
                openThreads.remove(threadID)
                pendingItems[threadID] = nil
                respond(id, .ok)
            case .loadEarlier(let threadID, let beforeIndex, let limit):
                guard let page = adapter.items(threadID, before: beforeIndex, limit: limit) else { throw notFound }
                respond(id, .items(page))
            case .markSeen(let threadID):
                try adapter.markSeen(threadID)
                respond(id, .ok)
            case .send(let send):
                Task { [weak self] in
                    guard let self else { return }
                    do { self.respond(id, .delivery(try await self.adapter.send(send))) } catch { self.fail(id, Self.remote(error)) }
                }
            case .steerQueued(let threadID, let messageID):
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        self.respond(id, .delivery(try await self.adapter.steerQueued(threadID, messageID: messageID)))
                    } catch { self.fail(id, Self.remote(error)) }
                }
            case .removeQueued(let threadID, let messageID):
                try adapter.removeQueued(threadID, messageID: messageID)
                respond(id, .ok)
            case .stop(let threadID):
                try adapter.stop(threadID)
                respond(id, .ok)
            case .respond(let threadID, let itemID, let optionID, let text):
                try adapter.respond(threadID, itemID: itemID, optionID: optionID, text: text)
                respond(id, .ok)
            case .answer(let threadID, let itemID, let answers):
                try adapter.answer(threadID, itemID: itemID, answers: answers)
                respond(id, .ok)
            case .dismissQuestion(let threadID, let itemID):
                try adapter.dismissQuestion(threadID, itemID: itemID)
                respond(id, .ok)
            case .updateSettings(let settings):
                try adapter.updateSettings(settings)
                respond(id, .ok)
            case .newThread(let projectID):
                respond(id, .thread(try adapter.newThread(in: projectID)))
            case .threadAction(let threadID, let action):
                try adapter.perform(action, on: threadID)
                respond(id, .ok)
            case .diff(let threadID, let turnID):
                Task { [weak self] in
                    guard let self else { return }
                    do { self.respond(id, .diff(try await self.adapter.diff(threadID, turnID: turnID))) } catch {
                        self.fail(id, Self.remote(error))
                    }
                }
            case .runScript(let threadID, let scriptID):
                try adapter.runScript(threadID, scriptID: scriptID)
                respond(id, .ok)
            case .usageLimits:
                respond(id, .usage(adapter.usageLimits()))
            case .presence(let reported):
                updatePresence(reported)
                respond(id, .ok)
            case .newBotConversation(let botID):
                respond(id, .thread(try adapter.newBotConversation(botID)))
            case .saveBot(let draft):
                respond(id, .bot(try adapter.saveBot(draft)))
            case .deleteBot(let botID, let deletesConversations):
                try adapter.deleteBot(botID, deletingConversations: deletesConversations)
                respond(id, .ok)
            case .settings:
                followsSettings = true
                let snapshot = adapter.settingsSnapshot()
                lastSettings = snapshot
                respond(id, .settings(snapshot))
                refreshInstructions()
            case .settingsDocument(let key):
                respond(id, .settingsDocument(try adapter.instructions.document(key)))
            case .saveSettingsDocument(let document):
                respond(id, .settingsDocument(try adapter.instructions.save(document)))
                // A file saved for the first time exists now; the pane says so.
                refreshInstructions()
            case .changeSetting(let key, let value):
                try adapter.changeSetting(key, to: value)
                followsSettings = true
                let snapshot = adapter.settingsSnapshot()
                lastSettings = snapshot
                respond(id, .settings(snapshot))
            case .settingsAction(let key):
                try adapter.performSettingsAction(key)
                let snapshot = adapter.settingsSnapshot()
                lastSettings = snapshot
                respond(id, .settings(snapshot))
            case .media(let threadID, let itemID, let index, let full):
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        self.respond(id, .media(try await self.adapter.media(threadID, itemID: itemID, index: index, full: full)))
                    } catch { self.fail(id, Self.remote(error)) }
                }
            case .completions(let threadID, let trigger, let query):
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        self.respond(id, .completions(try await self.adapter.completions(threadID, trigger: trigger, query: query)))
                    } catch { self.fail(id, Self.remote(error)) }
                }
            case .usageDashboard(let query):
                Task { [weak self] in
                    guard let self else { return }
                    self.respond(id, .usageDashboard(await self.adapter.usageDashboard(query)))
                }
            case .checkout(let threadID):
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        self.respond(id, .checkout(try await self.adapter.checkout(threadID)))
                    } catch { self.fail(id, Self.remote(error)) }
                }
            case .changeCheckout(let threadID, let action):
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        self.respond(id, .checkout(try await self.adapter.changeCheckout(threadID, action)))
                    } catch { self.fail(id, Self.remote(error)) }
                }
            case .setProjectExpanded(let projectID, let expanded):
                try adapter.setProjectExpanded(projectID, expanded: expanded)
                respond(id, .ok)
            case .forkThread(let fork):
                respond(id, .thread(try adapter.forkThread(fork)))
            case .rewindOptions(let reference):
                respond(id, .rewindOptions(try adapter.rewindOptions(reference)))
            case .rewind(let rewind):
                run(id) { .rewind(try await $0.rewind(rewind)) }
            case .composerNotice(let threadID):
                respond(id, .composerNotice(try adapter.composerNotice(threadID)))
            case .usageWarningAction(let command):
                respond(id, .composerNotice(try adapter.perform(command)))
            case .setSidebarOptions(let options):
                try adapter.setSidebarOptions(options)
                respond(id, .ok)
            case .projectDefaults(let projectID):
                respond(id, .projectDefaults(try adapter.projectDefaults(projectID)))
            case .saveProjectDefaults(let defaults):
                respond(id, .projectDefaults(try adapter.saveProjectDefaults(defaults)))
            case .removeProject(let projectID):
                try adapter.removeProject(projectID)
                respond(id, .ok)
            case .scheduledTasks:
                respond(id, .scheduledTasks(adapter.scheduledTasks()))
            case .saveScheduledTask(let draft):
                respond(id, .scheduledTasks(try adapter.saveScheduledTask(draft)))
            case .scheduledTaskAction(let command):
                respond(id, .scheduledTasks(try adapter.perform(command)))
            case .gitState(let threadID):
                run(id) { .gitState(try await $0.gitState(threadID)) }
            case .gitAction(let action):
                run(id) { .gitAction(try await $0.gitAction(action)) }
            case .pullRequests(let query):
                run(id) { .pullRequests(try await $0.pullRequests(query)) }
            case .pullRequest(let reference):
                run(id) { .pullRequest(try await $0.pullRequest(reference)) }
            case .pullRequestAction(let command):
                run(id) { try await $0.perform(command) }
            case .showThread(let threadID):
                guard isLocal else { throw RemoteError(.unsupported, "Unsupported request “showThread”.") }
                guard adapter.hasThread(threadID) else { throw notFound }
                onShowThread?(threadID)
                respond(id, .ok)
            }
        } catch {
            fail(id, Self.remote(error))
        }
    }

    /// Answers a request that waits on git, a checkpoint or another slow call, without holding up the others.
    private func run(_ id: String, _ work: @escaping @MainActor (RemoteStoreAdapter) async throws -> RemoteResult) {
        Task { [weak self] in
            guard let self else { return }
            do { self.respond(id, try await work(self.adapter)) } catch { self.fail(id, Self.remote(error)) }
        }
    }

    private func updatePresence(_ reported: RemotePresence) {
        guard let deviceID else { return }
        let previous = presence
        let current = DevicePresence(deviceID: deviceID, presence: reported, receivedAt: now())
        presence = current
        // A thread on screen in front counts as seen, as on the Mac: its badge and its notifications everywhere go.
        if current.state == .active, let open = current.openThreadID,
            previous?.state != .active || previous?.openThreadID != open
        {
            try? adapter.markSeen(open)
        }
        onPresence?(self, reported)
    }

    private var notFound: RemoteError { RemoteError(.notFound, String(localized: "That thread no longer exists.")) }

    private static func remote(_ error: Error) -> RemoteError {
        (error as? RemoteError) ?? RemoteError(.failed, error.localizedDescription)
    }

    // MARK: Changes

    private func note(_ change: RemoteStoreAdapter.Change) {
        switch change {
        case .workspace:
            workspaceDirty = true
            scheduleWorkspace()
        case .server:
            serverDirty = true
            scheduleWorkspace()
        case .items(let threadID, let ids):
            guard openThreads.contains(threadID) else { return }
            pendingItems[threadID, default: []].formUnion(ids)
            scheduleItems()
        case .reset(let threadID):
            guard openThreads.contains(threadID) else { return }
            pendingResets.insert(threadID)
            pendingItems[threadID] = nil
            scheduleItems()
        case .turn(let threadID):
            guard openThreads.contains(threadID) else { return }
            pendingTurns.insert(threadID)
            scheduleItems()
        case .clearNotifications(let threadID):
            guard presence != nil else { return }
            send(.event(.clearNotifications(threadID: threadID)))
        }
    }

    private func scheduleItems() {
        guard itemFlush == nil else { return }
        itemFlush = Task { [weak self, itemInterval] in
            try? await Task.sleep(for: itemInterval)
            guard let self, !Task.isCancelled else { return }
            self.itemFlush = nil
            self.flushItems()
        }
    }

    private func scheduleWorkspace() {
        guard workspaceFlush == nil else { return }
        workspaceFlush = Task { [weak self, workspaceInterval] in
            try? await Task.sleep(for: workspaceInterval)
            guard let self, !Task.isCancelled else { return }
            self.workspaceFlush = nil
            self.flushWorkspace()
        }
    }

    /// Sends what changed in open threads. Public for tests, which don't wait for the batch.
    func flushItems() {
        guard case .authenticated = state else { return }
        for threadID in pendingResets {
            if let transcript = adapter.transcript(threadID, limit: 200) {
                send(.event(.transcript(transcript)))
            } else {
                openThreads.remove(threadID)
                send(.event(.threadRemoved(threadID)))
            }
        }
        for (threadID, ids) in pendingItems where !pendingResets.contains(threadID) {
            guard let (items, count) = adapter.items(threadID, ids: ids) else { continue }
            if !items.isEmpty { send(.event(.items(threadID: threadID, items: items, count: count))) }
        }
        for threadID in pendingTurns where adapter.store.hasThread(threadID) {
            send(.event(.turn(threadID: threadID, state: adapter.turnState(threadID))))
        }
        pendingResets = []
        pendingItems = [:]
        pendingTurns = []
    }

    /// Finds the instruction files again (they live on disk, outside the store), then sends Settings if the list changed.
    private func refreshInstructions() {
        Task { [weak self] in
            await self?.adapter.instructions.refresh()
            self?.sendSettingsIfChanged()
        }
    }

    /// Sends the Mac's Settings to a phone that follows them, when they changed since it last heard.
    private func sendSettingsIfChanged() {
        guard case .authenticated = state, followsSettings else { return }
        let snapshot = adapter.settingsSnapshot()
        guard snapshot != lastSettings else { return }
        lastSettings = snapshot
        send(.event(.settings(snapshot)))
    }

    func flushWorkspace() {
        guard case .authenticated = state else { return }
        if serverDirty {
            serverDirty = false
            send(.event(.server(serverInfo())))
        }
        if followsSettings, serverDirty || workspaceDirty || lastSettings != nil {
            sendSettingsIfChanged()
        }
        guard workspaceDirty else { return }
        workspaceDirty = false
        let workspace = adapter.workspace(includeArchived: includesArchived)
        guard workspace != lastWorkspace else { return }
        lastWorkspace = workspace
        send(.event(.workspace(workspace)))
        // Threads the phone has open that were deleted.
        for threadID in openThreads where !adapter.store.hasThread(threadID) {
            openThreads.remove(threadID)
            send(.event(.threadRemoved(threadID)))
        }
    }

    // MARK: Sending

    /// Sends an alert to this phone. False when it can't take one: closed, or never reported its presence.
    func deliver(_ notification: RemoteNotification) -> Bool {
        guard case .authenticated = state, presence != nil, transport != nil else { return false }
        send(.event(.notify(notification)))
        return true
    }

    /// Tells this phone whether the user is at the Mac, so it keeps its notifications to itself while they are.
    func sendMacPresence(_ presence: RemoteMacPresence) {
        guard case .authenticated = state else { return }
        send(.event(.macPresence(presence)))
    }

    private func respond(_ id: String, _ result: RemoteResult) {
        send(.response(id: id, result: result))
    }

    private func fail(_ id: String?, _ error: RemoteError, closing: Bool = false) {
        send(.failure(id: id, error: error))
        if closing { close() }
    }

    private func send(_ message: RemoteServerMessage) {
        guard state != .closed, let transport else { return }
        do {
            transport.send(try RemoteProtocol.makeEncoder().encode(message))
        } catch {
            NSLog("Coincide: couldn’t encode a remote message: \(error.localizedDescription)")
        }
    }
}
