import Darwin
import Foundation

/// One owned helper lifetime. Only explicit open launches a shell; every other
/// method observes or controls an exact existing process incarnation.
actor RemoteTerminalService {
    private final class Session: @unchecked Sendable {
        let request: RemoteTerminalOpenRequest
        var snapshot: RemoteTerminalSnapshot
        var output = Data()
        var driver: (any RemotePTYDriver)?
        var startup: Task<Void, Never>?
        var reader: Task<Void, Never>?
        var input: Task<Void, any Error>?
        var resize: Task<Void, any Error>?
        var close: Task<Void, Never>?
        var finalState: RemoteTerminalSnapshot.State?
        var receipts: [Int64: RemoteTerminalInputReceipt] = [:]
        init(request: RemoteTerminalOpenRequest, snapshot: RemoteTerminalSnapshot) { self.request = request; self.snapshot = snapshot }
    }
    private let workspace: RemoteWorkspaceService
    private let factory: RemotePTYDriverFactory
    private let journal: RemoteTerminalJournal
    private var sessions: [UUID: Session] = [:]
    private var closing = false
    private var failed = false
    private var closeTask: Task<Void, Never>?

    init(workspace: RemoteWorkspaceService, factory: @escaping RemotePTYDriverFactory, dataDirectory: URL) throws {
        self.workspace = workspace; self.factory = factory; journal = try .init(directory: dataDirectory)
    }
    private func sameTarget(_ lhs: RemoteWorkspaceTarget, _ rhs: RemoteWorkspaceTarget) -> Bool {
        lhs.environmentID == rhs.environmentID && lhs.projectID == rhs.projectID && lhs.threadID == rhs.threadID
            && lhs.rootID == rhs.rootID && lhs.workspacePath.utf8.elementsEqual(rhs.workspacePath.utf8)
    }
    private func check() throws { guard !closing, !failed else { throw RemoteTerminalFailure(.unavailable) } }
    private func dimensions(_ cols: Int, _ rows: Int) throws {
        guard (1...1_000).contains(cols), (1...500).contains(rows) else { throw RemoteTerminalFailure(.invalidRequest) }
    }
    func open(_ request: RemoteTerminalOpenRequest) async throws -> RemoteTerminalSnapshot {
        try check(); try dimensions(request.cols, request.rows)
        guard request.target.rootID != nil else { throw RemoteTerminalFailure(.invalidTarget) }
        if let known = try journal.lookup(request) { return sessions[request.terminalID]?.snapshot ?? known }
        guard sessions.values.filter({ [.starting, .running, .closing].contains($0.snapshot.state) }).count < 8 else { throw RemoteTerminalFailure(.limitExceeded) }
        let incarnation = UUID()
        do { try await workspace.acquireTerminalRoot(request.target, owner: incarnation) }
        catch { throw safe(error) }
        do {
            try check()
            // Recheck after the await: another concurrent open may have reserved
            // this client-chosen terminal or exhausted the active-session budget.
            if let known = try journal.lookup(request) {
                await workspace.releaseTerminalRoot(owner: incarnation)
                return sessions[request.terminalID]?.snapshot ?? known
            }
            guard sessions.values.filter({ [.starting, .running, .closing].contains($0.snapshot.state) }).count < 8 else { throw RemoteTerminalFailure(.limitExceeded) }
            let reference = RemoteTerminalReference(target: request.target, terminalID: request.terminalID, incarnation: incarnation)
            let snapshot = RemoteTerminalSnapshot(reference: reference, state: .starting, cols: request.cols, rows: request.rows)
            try journal.insert(request, snapshot: snapshot)
            while sessions.count >= 128, let old = sessions.first(where: { ![.starting, .running, .closing].contains($0.value.snapshot.state) })?.key {
                sessions.removeValue(forKey: old)
            }
            let session = Session(request: request, snapshot: snapshot); sessions[request.terminalID] = session
            session.startup = Task { await self.start(session) }
            return snapshot
        } catch {
            await workspace.releaseTerminalRoot(owner: incarnation)
            throw safe(error)
        }
    }
    private func start(_ session: Session) async {
        do {
            try Task.checkCancellation()
            try await workspace.validateTerminalRoot(session.request.target, owner: session.snapshot.reference.incarnation)
            let driver = try await factory(.init(directory: session.request.target.workspacePath, cols: session.snapshot.cols, rows: session.snapshot.rows))
            session.driver = driver
            guard !closing, !Task.isCancelled, session.close == nil else { await driver.close(); return }
            try await workspace.validateTerminalRoot(session.request.target, owner: session.snapshot.reference.incarnation)
            try check(); try Task.checkCancellation()
            session.snapshot.state = .running
            try journal.update(session.snapshot)
            let stream = driver.events
            session.reader = Task {
                for await event in stream { await self.consume(event, session: session) }
                self.streamEnded(session)
            }
        } catch {
            if session.close != nil { return }
            session.snapshot.state = .failed; session.snapshot.inputHalted = true
            _ = beginClose(session, final: .failed)
        }
    }
    private func consume(_ event: RemotePTYEvent, session: Session) async {
        guard sessions[session.request.terminalID] === session else { return }
        switch event {
        case .output(let data):
            guard [.starting, .running, .closing].contains(session.snapshot.state), !data.isEmpty else { return }
            guard data.count <= 1_048_576, session.snapshot.outputSequence <= Int64.max - Int64(data.count) else {
                session.snapshot.inputHalted = true; _ = beginClose(session, final: .failed); return
            }
            session.snapshot.outputSequence += Int64(data.count)
            session.output.append(data)
            if session.output.count > RemoteTerminalProtocol.maximumOutputBytes {
                session.output.removeFirst(session.output.count - RemoteTerminalProtocol.maximumOutputBytes)
            }
            session.snapshot.retainedStartSequence = session.snapshot.outputSequence - Int64(session.output.count)
        case .exited(let code, let signal):
            session.snapshot.exitCode = code; session.snapshot.exitSignal = signal
            if session.close == nil { _ = beginClose(session, final: .exited) }
        case .failed, .outputOverflow:
            session.snapshot.inputHalted = true
            _ = beginClose(session, final: .failed)
        }
    }
    private func streamEnded(_ session: Session) {
        if session.close == nil { session.snapshot.inputHalted = true; _ = beginClose(session, final: .failed) }
    }
    private func get(_ reference: RemoteTerminalReference) throws -> Session {
        try check()
        if let session = sessions[reference.terminalID] {
            guard sameTarget(session.snapshot.reference.target, reference.target) else { throw RemoteTerminalFailure(.invalidTarget) }
            guard session.snapshot.reference.incarnation == reference.incarnation else { throw RemoteTerminalFailure(.staleIncarnation) }
            return session
        }
        guard let saved = journal.snapshot(reference) else { throw RemoteTerminalFailure(.notFound) }
        guard sameTarget(saved.reference.target, reference.target) else { throw RemoteTerminalFailure(.invalidTarget) }
        guard saved.reference.incarnation == reference.incarnation else { throw RemoteTerminalFailure(.staleIncarnation) }
        guard let request = journal.request(reference.terminalID) else { throw RemoteTerminalFailure(.notFound) }
        while sessions.count >= 128, let old = sessions.first(where: { ![.starting, .running, .closing].contains($0.value.snapshot.state) })?.key {
            sessions.removeValue(forKey: old)
        }
        var unavailableHistory = saved
        unavailableHistory.retainedStartSequence = unavailableHistory.outputSequence
        let session = Session(request: request, snapshot: unavailableHistory)
        sessions[reference.terminalID] = session; return session
    }
    private func current(_ session: Session) async -> RemoteTerminalSnapshot {
        if session.snapshot.state == .running, let driver = session.driver {
            let foreground = await driver.hasForegroundCommand()
            if session.snapshot.state == .running { session.snapshot.hasForegroundCommand = foreground }
        } else { session.snapshot.hasForegroundCommand = false }
        return session.snapshot
    }
    func attach(_ reference: RemoteTerminalReference) async throws -> RemoteTerminalSnapshot {
        let session = try get(reference)
        if [.starting, .running, .closing].contains(session.snapshot.state) {
            do { try await workspace.validateTerminalRoot(reference.target, owner: reference.incarnation) }
            catch {
                if ![.starting, .running, .closing].contains(session.snapshot.state) { return await current(session) }
                _ = beginClose(session, final: .failed); throw safe(error)
            }
        }
        return await current(session)
    }
    func list(_ target: RemoteWorkspaceTarget) async throws -> [RemoteTerminalSnapshot] {
        try check()
        guard target.rootID != nil else { throw RemoteTerminalFailure(.invalidTarget) }
        // Binding is read-only and validates the registered physical workspace.
        do { _ = try await workspace.bind(target) } catch { throw safe(error) }
        try check()
        return journal.snapshots.filter { sameTarget($0.reference.target, target) }.map {
            if let live = sessions[$0.id] { return live.snapshot }
            var value = $0; value.retainedStartSequence = value.outputSequence; return value
        }
    }
    func read(_ request: RemoteTerminalReadRequest) async throws -> RemoteTerminalReadResult {
        guard request.afterSequence >= 0, (1...RemoteTerminalProtocol.maximumChunkBytes).contains(request.maxBytes) else { throw RemoteTerminalFailure(.invalidRequest) }
        _ = try await attach(request.reference)
        let session = try get(request.reference), snapshot = session.snapshot
        if snapshot.state == .lost {
            return .init(snapshot: snapshot, data: Data(), startSequence: 0, nextSequence: 0, gap: true)
        }
        guard request.afterSequence <= snapshot.outputSequence else { throw RemoteTerminalFailure(.invalidRequest) }
        let start = max(request.afterSequence, snapshot.retainedStartSequence)
        let offset = Int(start - snapshot.retainedStartSequence)
        // Data.removeFirst retains a nonzero startIndex; byte sequence offsets
        // are relative to the retained ring, not Foundation's storage indices.
        let lower = session.output.startIndex + offset
        let data = session.output.subdata(in: lower..<min(session.output.endIndex, lower + request.maxBytes))
        return .init(snapshot: snapshot, data: data, startSequence: start, nextSequence: start + Int64(data.count), gap: request.afterSequence < snapshot.retainedStartSequence)
    }
    func inputReceipt(_ request: RemoteTerminalInputReceiptRequest) throws -> RemoteTerminalInputReceipt? {
        let session = try get(request.reference)
        guard request.sequence > 0, request.digest.count == 64 else { throw RemoteTerminalFailure(.invalidRequest) }
        if let receipt = session.receipts[request.sequence] {
            guard receipt.digest == request.digest else { throw RemoteTerminalFailure(.inputCollision) }
            return receipt
        }
        if request.sequence < session.snapshot.nextInputSequence { throw RemoteTerminalFailure(.inputExpired) }
        return nil
    }
    func write(_ request: RemoteTerminalInputRequest) async throws -> RemoteTerminalInputReceipt {
        let session = try get(request.reference)
        guard request.sequence > 0, !request.data.isEmpty, request.data.count <= RemoteTerminalProtocol.maximumChunkBytes else { throw RemoteTerminalFailure(.invalidRequest) }
        let digest = RemoteTerminalProtocol.inputDigest(request.data)
        if let receipt = session.receipts[request.sequence] {
            guard receipt.digest == digest, receipt.byteCount == request.data.count else { throw RemoteTerminalFailure(.inputCollision) }
            return receipt
        }
        guard request.sequence >= session.snapshot.nextInputSequence else { throw RemoteTerminalFailure(.inputExpired) }
        guard !session.snapshot.inputHalted else { throw RemoteTerminalFailure(.inputUncertain) }
        guard request.sequence == session.snapshot.nextInputSequence, request.sequence < Int64.max,
              session.snapshot.state == .running, let driver = session.driver else { throw RemoteTerminalFailure(.invalidRequest) }
        guard session.input == nil else { throw RemoteTerminalFailure(.busy) }
        do { try await workspace.validateTerminalRoot(request.reference.target, owner: request.reference.incarnation) }
        catch { _ = beginClose(session, final: .failed); throw safe(error) }
        // The validation await may have admitted another input or a close.
        if let known = session.receipts[request.sequence] {
            guard known.digest == digest, known.byteCount == request.data.count else { throw RemoteTerminalFailure(.inputCollision) }
            return known
        }
        guard !closing, session.snapshot.state == .running, session.input == nil,
              !session.snapshot.inputHalted, request.sequence == session.snapshot.nextInputSequence else { throw RemoteTerminalFailure(.busy) }
        let chained = RemoteTerminalProtocol.chainedInputDigest(previous: session.snapshot.inputDigest, sequence: request.sequence, digest: digest)
        var receipt = RemoteTerminalInputReceipt(reference: request.reference, sequence: request.sequence, digest: digest,
            byteCount: request.data.count, inputDigest: chained, state: .accepted)
        session.snapshot.nextInputSequence += 1; session.snapshot.inputDigest = chained
        session.receipts[request.sequence] = receipt
        let data = request.data
        let task = Task { try await driver.write(data) }; session.input = task
        do {
            try await withTaskCancellationHandler { try await task.value; try Task.checkCancellation() } onCancel: { task.cancel() }
            receipt.state = .delivered
        } catch { receipt.state = .uncertain; session.snapshot.inputHalted = true }
        session.input = nil; session.receipts[request.sequence] = receipt
        while session.receipts.count > 64, let oldest = session.receipts.keys.min(), oldest != request.sequence { session.receipts.removeValue(forKey: oldest) }
        return receipt
    }
    func resize(_ request: RemoteTerminalResizeRequest) async throws -> RemoteTerminalSnapshot {
        try dimensions(request.cols, request.rows)
        let session = try get(request.reference)
        guard session.snapshot.state == .running, let driver = session.driver, session.resize == nil else { throw RemoteTerminalFailure(.busy) }
        do { try await workspace.validateTerminalRoot(request.reference.target, owner: request.reference.incarnation) }
        catch { _ = beginClose(session, final: .failed); throw safe(error) }
        guard !closing, session.snapshot.state == .running, session.resize == nil else { throw RemoteTerminalFailure(.busy) }
        let task = Task { try await driver.resize(cols: request.cols, rows: request.rows) }; session.resize = task
        do {
            try await withTaskCancellationHandler { try await task.value; try Task.checkCancellation() } onCancel: { task.cancel() }
            guard session.snapshot.state == .running else { throw RemoteTerminalFailure(.unavailable) }
            session.snapshot.cols = request.cols; session.snapshot.rows = request.rows
            try journal.update(session.snapshot); session.resize = nil; return await current(session)
        } catch { session.resize = nil; throw safe(error) }
    }
    func close(_ reference: RemoteTerminalReference) async throws -> RemoteTerminalSnapshot {
        let session = try get(reference)
        if [.starting, .running, .closing].contains(session.snapshot.state) { await beginClose(session, final: .exited).value }
        return session.snapshot
    }
    private func beginClose(_ session: Session, final: RemoteTerminalSnapshot.State) -> Task<Void, Never> {
        if let close = session.close {
            if final == .failed { session.finalState = .failed }
            return close
        }
        session.finalState = final
        session.snapshot.state = .closing; session.snapshot.inputHalted = true; session.snapshot.hasForegroundCommand = false
        session.startup?.cancel(); session.input?.cancel(); session.resize?.cancel()
        let task = Task { await self.finishClose(session, final: final) }
        session.close = task; return task
    }
    private func finishClose(_ session: Session, final: RemoteTerminalSnapshot.State) async {
        await session.startup?.value
        await session.driver?.close()
        _ = try? await session.input?.value; _ = try? await session.resize?.value
        await session.reader?.value
        await workspace.releaseTerminalRoot(owner: session.snapshot.reference.incarnation)
        session.driver = nil; session.snapshot.state = session.finalState ?? final; session.snapshot.hasForegroundCommand = false
        if session.snapshot.state == .failed { session.snapshot.exitCode = nil; session.snapshot.exitSignal = nil }
        do { try journal.update(session.snapshot) } catch { failed = true }
    }
    private func safe(_ error: any Error) -> RemoteTerminalFailure {
        if let error = error as? RemoteTerminalFailure { return error }
        if let error = error as? RemoteWorkspaceFailure, error.kind == .busy { return .init(.busy) }
        if error is CancellationError { return .init(.unavailable) }
        return .init(.invalidTarget)
    }
    func close() async {
        if let closeTask { await closeTask.value; return }
        closing = true
        let owned = sessions.values.filter { [.starting, .running, .closing].contains($0.snapshot.state) }.map { beginClose($0, final: .exited) }
        let task = Task { for value in owned { await value.value } }
        closeTask = task; await task.value
    }
}

/// Only open identity/lifecycle metadata is durable. No raw terminal input or
/// output is written here. Process loss cannot silently recreate a shell.
private final class RemoteTerminalJournal {
    private struct Record: Codable { let request: RemoteTerminalOpenRequest; var snapshot: RemoteTerminalSnapshot }
    private struct Document: Codable { let version: Int; let records: [Record] }
    private let directory: GitWorktreeDirectory
    private var records: [UUID: Record] = [:]
    init(directory: URL) throws {
        self.directory = try .init(path: directory.path)
        guard let bytes = try self.directory.read("remote-terminal-identities.json", maximum: 8 * 1_024 * 1_024) else { return }
        let document = try JSONDecoder().decode(Document.self, from: bytes)
        guard document.version == 1, document.records.count <= 1_024,
              Set(document.records.map { $0.request.id }).count == document.records.count,
              Set(document.records.map { $0.request.terminalID }).count == document.records.count else { throw RemoteTerminalFailure(.unavailable) }
        for var record in document.records {
            guard record.snapshot.reference.terminalID == record.request.terminalID,
                  record.snapshot.reference.target == record.request.target else { throw RemoteTerminalFailure(.unavailable) }
            record.snapshot.state = .lost
            record.snapshot.exitCode = nil; record.snapshot.exitSignal = nil
            record.snapshot.inputHalted = true; record.snapshot.inputDigest = ""; record.snapshot.nextInputSequence = 1
            record.snapshot.outputSequence = 0; record.snapshot.retainedStartSequence = 0; record.snapshot.hasForegroundCommand = false
            records[record.request.id] = record
        }
        try persist()
    }
    private func payload(_ request: RemoteTerminalOpenRequest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(request)
        guard bytes.count <= RemoteEnvironmentProtocol.maximumRequestBytes else { throw RemoteTerminalFailure(.limitExceeded) }
        return bytes
    }
    func lookup(_ request: RemoteTerminalOpenRequest) throws -> RemoteTerminalSnapshot? {
        if let record = records[request.id] {
            guard try payload(record.request) == payload(request) else { throw RemoteTerminalFailure(.openCollision) }
            return record.snapshot
        }
        guard !records.values.contains(where: { $0.request.terminalID == request.terminalID }) else { throw RemoteTerminalFailure(.openCollision) }
        return nil
    }
    func insert(_ request: RemoteTerminalOpenRequest, snapshot: RemoteTerminalSnapshot) throws {
        _ = try payload(request)
        guard records.count < 1_024 else { throw RemoteTerminalFailure(.limitExceeded) }
        records[request.id] = .init(request: request, snapshot: snapshot)
        do { try persist() } catch { records.removeValue(forKey: request.id); throw error }
    }
    func update(_ snapshot: RemoteTerminalSnapshot) throws {
        guard let id = records.first(where: { $0.value.request.terminalID == snapshot.id })?.key, var record = records[id] else { throw RemoteTerminalFailure(.notFound) }
        let previous = record; record.snapshot = snapshot; records[id] = record
        do { try persist() } catch { records[id] = previous; throw error }
    }
    func request(_ terminalID: UUID) -> RemoteTerminalOpenRequest? { records.values.first { $0.request.terminalID == terminalID }?.request }
    func snapshot(_ reference: RemoteTerminalReference) -> RemoteTerminalSnapshot? { records.values.first { $0.request.terminalID == reference.terminalID }?.snapshot }
    var snapshots: [RemoteTerminalSnapshot] { records.values.map(\.snapshot).sorted { $0.id.uuidString < $1.id.uuidString } }
    private func persist() throws {
        try directory.validate()
        let sanitized = records.values.map { record -> Record in
            var value = record
            value.snapshot.inputDigest = ""; value.snapshot.nextInputSequence = 1; value.snapshot.inputHalted = true
            value.snapshot.outputSequence = 0; value.snapshot.retainedStartSequence = 0; value.snapshot.hasForegroundCommand = false
            return value
        }
        let bytes = try JSONEncoder().encode(Document(version: 1, records: sanitized))
        guard bytes.count <= 8 * 1_024 * 1_024 else { throw RemoteTerminalFailure(.limitExceeded) }
        let name = ".remote-terminal-" + UUID().uuidString
        let fd = openat(directory.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RemoteTerminalFailure(.unavailable) }
        defer { Darwin.close(fd); _ = unlinkat(directory.fd, name, 0) }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw RemoteTerminalFailure(.unavailable) }; offset += count
        }
        guard fsync(fd) == 0 else { throw RemoteTerminalFailure(.unavailable) }
        try directory.validate()
        guard renameat(directory.fd, name, directory.fd, "remote-terminal-identities.json") == 0, fsync(directory.fd) == 0 else { throw RemoteTerminalFailure(.unavailable) }
    }
}
