import CoincideCore
import CoincideTerminal
import Foundation
import Observation

struct RemoteTerminalTransport: Sendable {
    var bind: @Sendable (RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget
    var open: @Sendable (RemoteTerminalOpenRequest) async throws -> RemoteTerminalSnapshot
    var attach: @Sendable (RemoteTerminalReference) async throws -> RemoteTerminalSnapshot
    var list: @Sendable (RemoteWorkspaceTarget) async throws -> [RemoteTerminalSnapshot]
    var read: @Sendable (RemoteTerminalReadRequest) async throws -> RemoteTerminalReadResult
    var write: @Sendable (RemoteTerminalInputRequest) async throws -> RemoteTerminalInputReceipt
    var receipt: @Sendable (RemoteTerminalInputReceiptRequest) async throws -> RemoteTerminalInputReceipt?
    var resize: @Sendable (RemoteTerminalResizeRequest) async throws -> RemoteTerminalSnapshot
    var close: @Sendable (RemoteTerminalReference) async throws -> RemoteTerminalSnapshot
    static func live(_ client: RemoteEnvironmentClient) -> Self {
        .init(bind: { try await client.bindWorkspace($0) }, open: { try await client.openTerminal($0) },
            attach: { try await client.attachTerminal($0) }, list: { try await client.listTerminals($0) },
            read: { try await client.readTerminal($0) }, write: { try await client.writeTerminal($0) },
            receipt: { try await client.terminalInputReceipt($0) }, resize: { try await client.resizeTerminal($0) },
            close: { try await client.closeTerminal($0) })
    }
}

@MainActor @Observable
final class RemoteTerminalTab: Identifiable {
    let id: UUID
    let openRequest: RemoteTerminalOpenRequest
    let renderer: RemoteTerminalSession
    private(set) var snapshot: RemoteTerminalSnapshot?
    var isAttached = false
    var allowsInteraction = true
    var inputBlocked = false
    var openUnconfirmed = true
    var preparingClose = false
    var isClosing = false
    var errorMessage: String?
    var notice: String?
    var uncertainInput: RemoteTerminalInputReceiptRequest?
    @ObservationIgnored var inputQueue: [Data] = []
    @ObservationIgnored var queuedBytes = 0
    @ObservationIgnored var nextInputSequence: Int64 = 1
    @ObservationIgnored var inputDigest = ""
    @ObservationIgnored var afterSequence: Int64 = 0
    @ObservationIgnored var replayThrough: Int64?
    @ObservationIgnored var inputTask: Task<Void, Never>?
    @ObservationIgnored var readTask: Task<Void, Never>?
    @ObservationIgnored var resizeTask: Task<Void, Never>?
    @ObservationIgnored var pendingSize: (cols: Int, rows: Int)?
    @ObservationIgnored var lease = UUID()

    init(_ request: RemoteTerminalOpenRequest) {
        id = request.terminalID; openRequest = request
        renderer = .init(id: request.terminalID)
    }
    var reference: RemoteTerminalReference? { snapshot?.reference }
    var isLive: Bool { isAttached && (snapshot.map { [.starting, .running, .closing].contains($0.state) } ?? openUnconfirmed) }
    var canInput: Bool { isAttached && allowsInteraction && snapshot?.state == .running && !inputBlocked && !preparingClose && !isClosing && replayThrough == nil }
    var status: String {
        if openUnconfirmed { return "Open result unconfirmed. Inspect it before opening another terminal." }
        if !isAttached { return "Read-only transcript. Reconnect and attach explicitly to inspect the same remote session." }
        if inputBlocked { return "Input is paused. It may have reached the remote process and will not be repeated." }
        switch snapshot?.state {
        case .starting: return "Starting remote shell…"
        case .running: return replayThrough == nil ? "Connected to remote shell" : "Restoring missed output without sending terminal replies…"
        case .closing: return "Closing remote terminal…"
        case .exited: return snapshot?.exitCode.map { "Remote shell exited (\($0))." } ?? "Remote shell stopped."
        case .failed: return "Remote terminal failed. Its retained output may be incomplete."
        case .lost: return "The previous remote process is unavailable. Nothing was restarted."
        case nil: return "Remote terminal is unavailable."
        }
    }
    func publish(_ value: RemoteTerminalSnapshot) {
        if let current = snapshot, [.exited, .failed, .lost].contains(current.state), [.starting, .running, .closing].contains(value.state) { return }
        if let current = snapshot, current.outputSequence > value.outputSequence, value.state != .lost { return }
        snapshot = value
        if value.inputHalted { inputBlocked = true; inputQueue = []; queuedBytes = 0 }
        renderer.setInteractive(canInput)
    }
}

@MainActor @Observable
final class RemoteTerminalWorkspace: Identifiable {
    let id = UUID()
    let target: RemoteWorkspaceTarget
    var tabs: [RemoteTerminalTab] = []
    var selectedID: UUID?
    init(target: RemoteWorkspaceTarget) { self.target = target }
    var selected: RemoteTerminalTab? { tabs.first { $0.id == selectedID } ?? tabs.first }
}

@MainActor @Observable
final class RemoteTerminalStore {
    private(set) var workspaces: [RemoteTerminalWorkspace] = []
    private(set) var current: RemoteTerminalWorkspace?
    private(set) var isBinding = false
    private(set) var isOpening = false
    private(set) var errorMessage: String?
    var panelVisible = false
    @ObservationIgnored private var transport: RemoteTerminalTransport?
    @ObservationIgnored private var clientIdentity: ObjectIdentifier?
    @ObservationIgnored private var environmentID: UUID?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var selection = UUID()
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var eligibleTarget: RemoteWorkspaceTarget?
    @ObservationIgnored private var boundSelection: RemoteWorkspaceTarget?
    var sessions: [RemoteTerminalTab] { current?.tabs ?? [] }
    var selected: RemoteTerminalTab? { current?.selected }
    var hasLiveTerminals: Bool { workspaces.contains { $0.tabs.contains { $0.isLive || ($0.openUnconfirmed && transport != nil && $0.openRequest.target.environmentID == environmentID) } } }
    var canOpen: Bool {
        !stopping && !isBinding && !isOpening && transport != nil && eligibleTarget != nil &&
            !workspaces.contains { $0.tabs.contains { $0.openUnconfirmed && $0.openRequest.target.environmentID == environmentID } }
    }
    func hasLiveTerminals(in target: RemoteWorkspaceTarget) -> Bool {
        workspaces.contains { workspace in
            workspace.target.environmentID == target.environmentID &&
                (workspace.target.rootID == target.rootID && target.rootID != nil || workspace.target.workspacePath.utf8.elementsEqual(target.workspacePath.utf8)) &&
                workspace.tabs.contains { $0.isLive || ($0.openUnconfirmed && transport != nil && $0.openRequest.target.environmentID == environmentID) }
        }
    }

    func select(target: RemoteWorkspaceTarget?, client: RemoteEnvironmentClient?) async {
        guard !stopping else { return }
        if let client {
            let identity = ObjectIdentifier(client)
            if clientIdentity != identity { disconnect(); transport = .live(client); clientIdentity = identity }
        } else { disconnect() }
        await select(target: target, transport: transport)
    }

    /// Injectable typed seam used by offscreen lifecycle/order tests.
    func select(target: RemoteWorkspaceTarget?, transport: RemoteTerminalTransport?) async {
        guard !stopping else { return }
        selection = UUID(); let owner = selection
        eligibleTarget = nil
        boundSelection = nil
        suspendInteraction()
        guard let target else { current = nil; return }
        environmentID = target.environmentID
        guard let transport else {
            current = workspaces.last { Self.sameWorkspace($0.target, target) }; return
        }
        self.transport = transport; isBinding = true
        defer { if selection == owner { isBinding = false } }
        do {
            let bound = try await transport.bind(target)
            guard selection == owner, !stopping else { return }
            guard Self.sameWorkspace(bound, target), bound.rootID != nil,
                  target.rootID == nil || bound.rootID == target.rootID else { throw RemoteTerminalFailure(.invalidTarget) }
            if let existing = workspaces.first(where: { Self.sameWorkspace($0.target, bound) && $0.target.rootID == bound.rootID }) { current = existing }
            else {
                if workspaces.count >= 16 {
                    guard let unused = workspaces.first(where: { $0.tabs.isEmpty }) else { throw RemoteTerminalFailure(.limitExceeded) }
                    workspaces.removeAll { $0 === unused }
                }
                let workspace = RemoteTerminalWorkspace(target: bound); workspaces.append(workspace); current = workspace
            }
            eligibleTarget = bound; boundSelection = bound; errorMessage = nil
            for tab in current?.tabs ?? [] { tab.allowsInteraction = true; tab.renderer.setInteractive(tab.canInput) }
            // No attach, output polling, input, or open occurs during selection.
        } catch { if selection == owner { errorMessage = Self.safeMessage(error) } }
    }

    func clearSelection() { selection = UUID(); eligibleTarget = nil; boundSelection = nil; current = nil; isBinding = false; suspendInteraction() }
    var canShowCurrentWorkspace: Bool { boundSelection != nil }
    func showCurrentWorkspace() {
        guard let target = boundSelection, let workspace = workspaces.first(where: { Self.sameWorkspace($0.target, target) && $0.target.rootID == target.rootID }) else { return }
        showRetained(workspace)
    }
    func showRetained(_ workspace: RemoteTerminalWorkspace) {
        guard workspaces.contains(where: { $0 === workspace }) else { return }
        selection = UUID(); eligibleTarget = nil; suspendInteraction(); current = workspace
        if let target = boundSelection, Self.sameWorkspace(target, workspace.target), target.rootID == workspace.target.rootID { eligibleTarget = target }
        for tab in workspace.tabs { tab.allowsInteraction = true; tab.renderer.setInteractive(tab.canInput) }
    }

    func newTerminal() async {
        guard canOpen, let transport, let target = eligibleTarget, let current,
              current.tabs.count < 8, workspaces.reduce(0, { $0 + $1.tabs.count }) < 32 else { return }
        let owner = generation
        isOpening = true; defer { if generation == owner { isOpening = false } }
        let request = RemoteTerminalOpenRequest(target: target)
        let tab = RemoteTerminalTab(request)
        current.tabs.append(tab); current.selectedID = tab.id
        configure(tab)
        do {
            let value = try await transport.open(request)
            guard generation == owner else { return }
            guard Self.sameReference(value.reference, target: target, terminalID: request.terminalID) else { throw RemoteTerminalFailure(.invalidTarget) }
            tab.openUnconfirmed = false; tab.isAttached = true
            tab.nextInputSequence = value.nextInputSequence; tab.inputDigest = value.inputDigest
            tab.publish(value); startReading(tab)
        } catch {
            guard generation == owner else { return }
            tab.errorMessage = Self.safeMessage(error)
            tab.notice = "The shell may have started. Inspect this open result; it will not be opened again automatically."
        }
    }

    func inspectOpenResult(_ tab: RemoteTerminalTab) async {
        guard !stopping, tab.openUnconfirmed, let transport, environmentID == tab.openRequest.target.environmentID else { return }
        let owner = generation
        do {
            let matches = try await transport.list(tab.openRequest.target).filter { $0.id == tab.id }
            guard generation == owner else { return }
            guard matches.count <= 1 else { throw RemoteTerminalFailure(.invalidTarget) }
            tab.openUnconfirmed = false
            if let found = matches.first {
                guard Self.sameReference(found.reference, target: tab.openRequest.target, terminalID: tab.id) else { throw RemoteTerminalFailure(.invalidTarget) }
                tab.nextInputSequence = found.nextInputSequence; tab.inputDigest = found.inputDigest; tab.publish(found)
                tab.notice = "The exact remote session was found. Attach explicitly to inspect it."
            } else { tab.notice = "No retained session was found. New Terminal starts a separate shell only when you choose it." }
        } catch { if generation == owner { tab.errorMessage = Self.safeMessage(error) } }
    }

    func attach(_ tab: RemoteTerminalTab) async {
        guard !stopping, !tab.isClosing, let reference = tab.reference, let transport,
              environmentID == reference.target.environmentID else { return }
        let owner = generation
        do {
            let value = try await transport.attach(reference)
            guard generation == owner else { return }
            guard value.reference == reference else { throw RemoteTerminalFailure(.staleIncarnation) }
            tab.isAttached = true; tab.openUnconfirmed = false
            tab.nextInputSequence = value.nextInputSequence; tab.inputDigest = value.inputDigest
            tab.replayThrough = value.outputSequence
            tab.renderer.prepareForReplay(); tab.publish(value)
            tab.notice = "Attached to the same remote session. Missed output is restored without terminal automation."
            startReading(tab)
        } catch { if generation == owner { tab.errorMessage = Self.safeMessage(error); freeze(tab) } }
    }

    func enqueue(_ data: Data, for tab: RemoteTerminalTab) {
        guard !data.isEmpty, !stopping, tab.canInput, transport != nil else { return }
        guard data.count <= 262_144, tab.queuedBytes + data.count <= 262_144, tab.inputQueue.count + (data.count + 4_095) / 4_096 <= 64 else {
            haltInput(tab, message: "The input queue filled. Input is paused to avoid sending an incomplete command."); return
        }
        var offset = 0
        while offset < data.count {
            let end = min(offset + 4_096, data.count)
            tab.inputQueue.append(data.subdata(in: offset..<end)); tab.queuedBytes += end - offset; offset = end
        }
        startInput(tab)
    }

    func resize(_ tab: RemoteTerminalTab, cols: Int, rows: Int) {
        guard !stopping, tab.isAttached, tab.snapshot?.state == .running, !tab.isClosing else { return }
        tab.pendingSize = (min(1_000, max(1, cols)), min(500, max(1, rows)))
        guard tab.resizeTask == nil, let transport, let reference = tab.reference else { return }
        let owner = generation, lease = tab.lease
        tab.resizeTask = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            defer { if tab.lease == lease { tab.resizeTask = nil } }
            do {
                while self.generation == owner, tab.lease == lease, tab.isAttached, let size = tab.pendingSize {
                    tab.pendingSize = nil
                    let result = try await transport.resize(.init(reference: reference, cols: size.cols, rows: size.rows))
                    guard self.generation == owner, tab.lease == lease else { return }
                    tab.publish(result)
                }
            } catch { if self.generation == owner, tab.lease == lease { tab.errorMessage = Self.safeMessage(error) } }
        }
    }

    func checkInputResult(_ tab: RemoteTerminalTab) async {
        guard let request = tab.uncertainInput, let transport, environmentID == request.reference.target.environmentID else { return }
        let owner = generation
        do {
            let receipt = try await transport.receipt(request)
            guard generation == owner else { return }
            tab.notice = receipt?.state == .delivered ? "That input reached the remote PTY. Input remains paused; nothing was repeated." :
                "Input delivery is still unconfirmed. It will not be repeated. Close this terminal before starting a new shell."
        } catch { if generation == owner { tab.errorMessage = Self.safeMessage(error) } }
    }

    /// Returns false only when the caller must show the foreground confirmation.
    @discardableResult func close(_ tab: RemoteTerminalTab, confirmed: Bool = false) async -> Bool {
        guard !tab.isClosing else { return true }
        if tab.openUnconfirmed, transport != nil {
            await inspectOpenResult(tab)
            if tab.openUnconfirmed { tab.notice = "Inspect the open result or disconnect before removing this tab. Its shell may still be running."; return true }
        }
        guard let transport, let reference = tab.reference, environmentID == reference.target.environmentID else {
            if tab.openUnconfirmed, !confirmed { return false }
            remove(tab); return true
        }
        let owner = generation
        tab.preparingClose = true; tab.renderer.setInteractive(false)
        // Closing the host driver is what unblocks a stalled PTY write. Never
        // await that input before issuing close, and never flush queued keys.
        if tab.inputTask != nil || !tab.inputQueue.isEmpty { tab.inputBlocked = true }
        tab.inputQueue = []; tab.queuedBytes = 0
        do {
            let fresh = try await transport.attach(reference)
            guard generation == owner else { return true }
            tab.publish(fresh)
            if !confirmed, fresh.hasForegroundCommand || tab.inputBlocked { return false }
            tab.isClosing = true; tab.renderer.setInteractive(false)
            let result = try await transport.close(reference)
            guard generation == owner else { return true }
            tab.publish(result)
            freeze(tab)
            remove(tab)
            return true
        } catch {
            guard generation == owner else { return true }
            tab.errorMessage = Self.safeMessage(error)
            if !confirmed { return false }
            freeze(tab); tab.notice = "Close could not be confirmed. The transcript was retained; disconnecting closes the owned remote host."
            tab.isClosing = false; tab.preparingClose = false
            return true
        }
    }
    func cancelClose(_ tab: RemoteTerminalTab) { tab.preparingClose = false; tab.renderer.setInteractive(tab.canInput) }

    func disconnect() {
        generation = UUID(); selection = UUID()
        transport = nil; clientIdentity = nil; environmentID = nil; eligibleTarget = nil; boundSelection = nil
        isOpening = false; isBinding = false
        for workspace in workspaces { for tab in workspace.tabs { freeze(tab) } }
    }
    func shutdown() async {
        stopping = true
        let active = workspaces.flatMap(\.tabs), transport = transport
        generation = UUID(); selection = UUID(); eligibleTarget = nil
        for tab in active { freeze(tab) }
        if let transport {
            for tab in active {
                if let reference = tab.reference {
                    if let result = try? await transport.close(reference) { tab.publish(result) }
                }
            }
        }
        self.transport = nil; clientIdentity = nil; environmentID = nil
    }
    func cancelShutdown() { stopping = false }

    private func configure(_ tab: RemoteTerminalTab) {
        tab.renderer.onInput = { [weak self, weak tab] data in if let tab { self?.enqueue(data, for: tab) } }
        tab.renderer.onResize = { [weak self, weak tab] cols, rows in if let tab { self?.resize(tab, cols: cols, rows: rows) } }
    }
    private func startInput(_ tab: RemoteTerminalTab) {
        guard tab.inputTask == nil, let transport, let reference = tab.reference else { return }
        let owner = generation, lease = tab.lease
        tab.inputTask = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            defer { if tab.lease == lease { tab.inputTask = nil } }
            while self.generation == owner, tab.lease == lease, tab.isAttached, !tab.inputBlocked, !tab.preparingClose, !tab.isClosing, !tab.inputQueue.isEmpty {
                let bytes = tab.inputQueue.removeFirst(); tab.queuedBytes -= bytes.count
                let request = RemoteTerminalInputRequest(reference: reference, sequence: tab.nextInputSequence, data: bytes)
                let digest = RemoteTerminalProtocol.inputDigest(bytes)
                let receiptRequest = RemoteTerminalInputReceiptRequest(reference: reference, sequence: request.sequence, digest: digest)
                let previousDigest = tab.inputDigest
                tab.uncertainInput = receiptRequest
                do {
                    let receipt = try await transport.write(request)
                    guard self.generation == owner, tab.lease == lease else { return }
                    guard receipt.reference == reference, receipt.sequence == request.sequence, receipt.digest == digest,
                          receipt.byteCount == bytes.count, receipt.state == .delivered,
                          receipt.inputDigest == RemoteTerminalProtocol.chainedInputDigest(previous: previousDigest, sequence: request.sequence, digest: digest) else {
                        throw RemoteTerminalFailure(.inputUncertain)
                    }
                    tab.nextInputSequence = request.sequence + 1; tab.inputDigest = receipt.inputDigest; tab.uncertainInput = nil
                } catch {
                    guard self.generation == owner, tab.lease == lease else { return }
                    self.haltInput(tab, message: Self.safeMessage(error)); return
                }
            }
        }
    }
    private func startReading(_ tab: RemoteTerminalTab) {
        guard tab.readTask == nil, let transport, let reference = tab.reference else { return }
        let owner = generation, lease = tab.lease
        tab.readTask = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            defer { if tab.lease == lease { tab.readTask = nil } }
            do {
                while !Task.isCancelled, self.generation == owner, tab.lease == lease, tab.isAttached {
                    let previous = tab.afterSequence
                    let result = try await transport.read(.init(reference: reference, afterSequence: previous))
                    guard self.generation == owner, tab.lease == lease else { return }
                    try self.acceptOutput(result, for: tab, after: previous)
                    if [.exited, .failed, .lost].contains(result.snapshot.state), result.nextSequence >= result.snapshot.outputSequence { return }
                    if result.data.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
                    else { await Task.yield() }
                }
            } catch is CancellationError { }
            catch {
                guard self.generation == owner, tab.lease == lease else { return }
                tab.errorMessage = Self.safeMessage(error); self.freeze(tab)
            }
        }
    }
    private func acceptOutput(_ result: RemoteTerminalReadResult, for tab: RemoteTerminalTab, after: Int64) throws {
        guard result.snapshot.reference == tab.reference, result.data.count <= 65_536,
              result.nextSequence >= result.startSequence,
              result.nextSequence - result.startSequence == Int64(result.data.count), result.nextSequence <= result.snapshot.outputSequence else {
            throw RemoteTerminalFailure(.invalidRequest)
        }
        if result.snapshot.state == .lost {
            guard result.gap, result.data.isEmpty, result.nextSequence == 0 else { throw RemoteTerminalFailure(.invalidRequest) }
            tab.publish(result.snapshot); tab.renderer.setInteractive(false); return
        }
        guard result.gap ? result.startSequence > after && result.startSequence == result.snapshot.retainedStartSequence : result.startSequence == after else {
            throw RemoteTerminalFailure(.outputGap)
        }
        if result.gap {
            tab.notice = "Some output expired. The retained tail was restored as inert text."
            tab.replayThrough = max(tab.replayThrough ?? 0, result.snapshot.outputSequence)
            tab.renderer.setInteractive(false)
        }
        tab.renderer.acceptOutput(result.data, reset: result.gap, inert: tab.replayThrough != nil)
        tab.afterSequence = result.nextSequence
        if let end = tab.replayThrough, result.nextSequence >= end { tab.replayThrough = nil }
        tab.publish(result.snapshot)
    }
    private func haltInput(_ tab: RemoteTerminalTab, message: String) {
        tab.inputBlocked = true; tab.inputQueue = []; tab.queuedBytes = 0
        tab.renderer.setInteractive(false); tab.errorMessage = message
    }
    private func suspendInteraction() {
        for workspace in workspaces { for tab in workspace.tabs { tab.allowsInteraction = false; tab.renderer.setInteractive(false) } }
    }
    private func freeze(_ tab: RemoteTerminalTab) {
        if tab.inputTask != nil || !tab.inputQueue.isEmpty { tab.inputBlocked = true }
        tab.lease = UUID(); tab.isAttached = false; tab.renderer.setInteractive(false)
        tab.inputQueue = []; tab.queuedBytes = 0; tab.pendingSize = nil
        tab.readTask?.cancel(); tab.readTask = nil
        tab.inputTask?.cancel(); tab.inputTask = nil
        tab.resizeTask?.cancel(); tab.resizeTask = nil
    }
    private func remove(_ tab: RemoteTerminalTab) {
        freeze(tab)
        for workspace in workspaces {
            workspace.tabs.removeAll { $0 === tab }
            if workspace.selectedID == tab.id { workspace.selectedID = workspace.tabs.first?.id }
        }
    }
    private static func sameWorkspace(_ lhs: RemoteWorkspaceTarget, _ rhs: RemoteWorkspaceTarget) -> Bool {
        lhs.environmentID == rhs.environmentID && lhs.threadID == rhs.threadID && lhs.projectID == rhs.projectID && lhs.workspacePath.utf8.elementsEqual(rhs.workspacePath.utf8)
    }
    private static func sameReference(_ reference: RemoteTerminalReference, target: RemoteWorkspaceTarget, terminalID: UUID) -> Bool {
        reference.terminalID == terminalID && reference.target.rootID == target.rootID && sameWorkspace(reference.target, target)
    }
    private static func safeMessage(_ error: any Error) -> String {
        if let failure = error as? RemoteTerminalFailure { return failure.localizedDescription }
        if let failure = error as? RemoteEnvironmentClientError { return failure.localizedDescription }
        if let failure = error as? RemoteWorkspaceFailure { return failure.localizedDescription }
        return "The remote terminal request failed. No input or shell was replayed."
    }
}
