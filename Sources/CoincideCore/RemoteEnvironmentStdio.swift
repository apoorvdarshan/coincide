import Darwin
import Foundation

/// Native helper entrypoint. Stdio carries only bounded JSON-RPC frames; all
/// diagnostics use fixed text on stderr. There is no listener or login flow.
public enum RemoteEnvironmentStdio {
    public static func run(arguments: [String], driverFactory: RemotePTYDriverFactory? = nil) async -> Int32 {
        var service: RemoteEnvironmentService?
        do {
            let parsed = try Arguments(arguments)
            let current = try RemoteEnvironmentService(dataDirectory: parsed.directory, label: parsed.label,
                expectedEnvironmentID: parsed.expected, options: parsed.options, driverFactory: driverFactory)
            service = current
            let input = try RemoteEnvironmentStdioInput(), writer = try RemoteEnvironmentStdioWriter()
            let workspaceReads = RemoteWorkspaceReadResponses()
            signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGPIPE, SIG_IGN)
            let signals = [SIGTERM, SIGINT].map { number in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
                source.setEventHandler { input.stop() }; source.resume(); return source
            }
            var subscription: Task<Void, Never>?
            var status: Int32 = 0
            do {
                requestLoop: for try await received in input.frames {
                    let frame = received.value
                    input.consumed(received.byteCount)
                    var id: JSONValue = .null
                    do {
                        guard let object = frame.object,
                              Set(object.keys).isSubset(of: ["jsonrpc", "id", "method", "params"]),
                              frame["jsonrpc"] == .null || frame["jsonrpc"] == .string("2.0"),
                              let supplied = object["id"], validID(supplied), let method = frame["method"].string,
                              method.utf8.count <= 128 else { throw RemoteEnvironmentError(.invalidRequest) }
                        id = supplied
                        let workspaceMethod = [RemoteEnvironmentProtocol.workspaceBindMethod, RemoteEnvironmentProtocol.workspaceReadMethod,
                            RemoteEnvironmentProtocol.workspaceBeginMethod, RemoteEnvironmentProtocol.workspaceOperationMethod,
                            RemoteEnvironmentProtocol.workspaceCancelMethod].contains(method)
                        guard received.byteCount <= (workspaceMethod ? RemoteEnvironmentProtocol.maximumWorkspaceRequestBytes : RemoteEnvironmentProtocol.maximumRequestBytes) else {
                            throw RemoteEnvironmentError(.limitExceeded)
                        }
                        let params = object["params"] ?? .object([:])
                        guard params.object != nil else { throw RemoteEnvironmentError(.invalidRequest) }
                        let result: JSONValue
                        switch method {
                        case RemoteEnvironmentProtocol.describeMethod:
                            guard params.object?.isEmpty == true else { throw RemoteEnvironmentError(.invalidRequest) }
                            result = try RemoteEnvironmentProtocol.encode(await current.descriptor())
                        case RemoteEnvironmentProtocol.snapshotMethod:
                            let request = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentSnapshotRequest.self, from: params)
                            result = try RemoteEnvironmentProtocol.encode(try await current.snapshot(request))
                        case RemoteEnvironmentProtocol.subscribeMethod:
                            let request = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentSnapshotRequest.self, from: params)
                            let snapshot = try await current.snapshot(request)
                            let updates = try await current.updates()
                            subscription?.cancel()
                            if let subscription { await subscription.value }
                            subscription = Task {
                                await forwardSubscription(updates, send: { value in
                                    try await writer.send(.object(["jsonrpc": .string("2.0"),
                                        "method": .string(RemoteEnvironmentProtocol.snapshotNotification),
                                        "params": try RemoteEnvironmentProtocol.encode(value)]))
                                }, disconnect: { input.stop() })
                            }
                            result = try RemoteEnvironmentProtocol.encode(snapshot)
                        case RemoteEnvironmentProtocol.commandMethod:
                            let request = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentCommandRequest.self, from: params)
                            result = try RemoteEnvironmentProtocol.encode(try await current.command(request))
                        case RemoteEnvironmentProtocol.receiptMethod:
                            let request = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentCommandRequest.self, from: params)
                            result = try RemoteEnvironmentProtocol.encode(try await current.receipt(request))
                        case RemoteEnvironmentProtocol.workspaceBindMethod:
                            let target = try RemoteEnvironmentProtocol.decode(RemoteWorkspaceTarget.self, from: params)
                            result = try RemoteEnvironmentProtocol.encode(try await current.bindWorkspace(target))
                        case RemoteEnvironmentProtocol.workspaceReadMethod:
                            let request = try RemoteEnvironmentProtocol.decode(RemoteWorkspaceReadRequest.self, from: params)
                            try await workspaceReads.submit(id: id, operation: {
                                try RemoteEnvironmentProtocol.encode(try await current.readWorkspace(request))
                            }, writer: writer, disconnect: { input.stop() })
                            continue requestLoop
                        case RemoteEnvironmentProtocol.workspaceBeginMethod:
                            let request = try RemoteEnvironmentProtocol.decode(RemoteWorkspaceMutationRequest.self, from: params)
                            result = try RemoteEnvironmentProtocol.encode(try await current.beginWorkspaceOperation(request))
                        case RemoteEnvironmentProtocol.workspaceOperationMethod:
                            let request = try RemoteEnvironmentProtocol.decode(RemoteWorkspaceMutationRequest.self, from: params)
                            result = try RemoteEnvironmentProtocol.encode(try await current.workspaceOperation(request))
                        case RemoteEnvironmentProtocol.workspaceCancelMethod:
                            let request = try RemoteEnvironmentProtocol.decode(RemoteWorkspaceMutationRequest.self, from: params)
                            try await workspaceReads.submit(id: id, operation: {
                                try RemoteEnvironmentProtocol.encode(try await current.cancelWorkspaceOperation(request))
                            }, writer: writer, disconnect: { input.stop() })
                            continue requestLoop
                        case RemoteEnvironmentProtocol.terminalOpenMethod:
                            let request = try RemoteEnvironmentProtocol.decode(RemoteTerminalOpenRequest.self, from: params)
                            try await workspaceReads.submit(id: id, operation: {
                                try RemoteEnvironmentProtocol.encode(try await current.openTerminal(request))
                            }, writer: writer, disconnect: { input.stop() })
                            continue requestLoop
                        case RemoteEnvironmentProtocol.terminalAttachMethod:
                            let reference = try RemoteEnvironmentProtocol.decode(RemoteTerminalReference.self, from: params)
                            try await workspaceReads.submit(id: id, operation: {
                                try RemoteEnvironmentProtocol.encode(try await current.attachTerminal(reference))
                            }, writer: writer, disconnect: { input.stop() })
                            continue requestLoop
                        case RemoteEnvironmentProtocol.terminalReadMethod:
                            let request = try RemoteEnvironmentProtocol.decode(RemoteTerminalReadRequest.self, from: params)
                            try await workspaceReads.submit(id: id, operation: {
                                try RemoteEnvironmentProtocol.encode(try await current.readTerminal(request))
                            }, writer: writer, disconnect: { input.stop() })
                            continue requestLoop
                        case RemoteEnvironmentProtocol.terminalWriteMethod:
                            let request = try RemoteEnvironmentProtocol.decode(RemoteTerminalInputRequest.self, from: params)
                            try await workspaceReads.submit(id: id, operation: {
                                try RemoteEnvironmentProtocol.encode(try await current.writeTerminal(request))
                            }, writer: writer, disconnect: { input.stop() })
                            continue requestLoop
                        case RemoteEnvironmentProtocol.terminalInputReceiptMethod:
                            let request = try RemoteEnvironmentProtocol.decode(RemoteTerminalInputReceiptRequest.self, from: params)
                            try await workspaceReads.submit(id: id, operation: {
                                try RemoteEnvironmentProtocol.encode(try await current.terminalInputReceipt(request))
                            }, writer: writer, disconnect: { input.stop() })
                            continue requestLoop
                        case RemoteEnvironmentProtocol.terminalResizeMethod:
                            let request = try RemoteEnvironmentProtocol.decode(RemoteTerminalResizeRequest.self, from: params)
                            try await workspaceReads.submit(id: id, operation: {
                                try RemoteEnvironmentProtocol.encode(try await current.resizeTerminal(request))
                            }, writer: writer, disconnect: { input.stop() })
                            continue requestLoop
                        case RemoteEnvironmentProtocol.terminalCloseMethod:
                            let reference = try RemoteEnvironmentProtocol.decode(RemoteTerminalReference.self, from: params)
                            try await workspaceReads.submit(id: id, operation: {
                                try RemoteEnvironmentProtocol.encode(try await current.closeTerminal(reference))
                            }, writer: writer, disconnect: { input.stop() })
                            continue requestLoop
                        case RemoteEnvironmentProtocol.terminalListMethod:
                            let target = try RemoteEnvironmentProtocol.decode(RemoteWorkspaceTarget.self, from: params)
                            try await workspaceReads.submit(id: id, operation: {
                                try RemoteEnvironmentProtocol.encode(try await current.listTerminals(target))
                            }, writer: writer, disconnect: { input.stop() })
                            continue requestLoop
                        case RemoteEnvironmentProtocol.closeMethod:
                            let request = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentSnapshotRequest.self, from: params)
                            guard request.environmentID == current.environmentID else { throw RemoteEnvironmentError(.wrongEnvironment) }
                            subscription?.cancel()
                            if let subscription { await subscription.value }
                            subscription = nil
                            async let serviceClose: Void = current.close()
                            await workspaceReads.close()
                            await serviceClose
                            result = try RemoteEnvironmentProtocol.encode(RemoteEnvironmentCloseResult(environmentID: current.environmentID))
                            try await writer.send(response(id: id, result: result))
                            break requestLoop
                        default: throw RemoteEnvironmentError(.unsupported)
                        }
                        try await writer.send(response(id: id, result: result))
                    } catch {
                        try await writer.send(errorResponse(id: id, error: error))
                    }
                }
            } catch { status = 1 }
            subscription?.cancel()
            input.stop(); await input.join()
            async let serviceClose: Void = current.close()
            await workspaceReads.close()
            await serviceClose
            if let subscription { await subscription.value }
            for source in signals { source.cancel() }
            return status
        } catch {
            await service?.close()
            try? FileHandle.standardError.write(contentsOf: Data("Coincide remote environment could not start safely.\n".utf8))
            return 1
        }
    }
    /// A finished update stream means this connection can no longer present a
    /// live workspace. Explicit cancellation belongs to resubscribe/close and
    /// must leave the replacement subscription and its input intact.
    static func forwardSubscription(_ updates: AsyncStream<RemoteEnvironmentSnapshot>,
                                    send: @Sendable (RemoteEnvironmentSnapshot) async throws -> Void,
                                    disconnect: @Sendable () -> Void) async {
        do {
            for await value in updates {
                try Task.checkCancellation()
                try await send(value)
            }
        } catch { }
        if !Task.isCancelled { disconnect() }
    }
    private static func validID(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let id): !id.isEmpty && id.utf8.count <= 128
        case .number(let id): id.isFinite && id >= 0 && id <= 9_007_199_254_740_991 && id.rounded() == id
        default: false
        }
    }
    fileprivate static func response(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }
    fileprivate static func errorResponse(id: JSONValue, error: any Error) -> JSONValue {
        let code: Int, kind: String, message: String
        if let safe = error as? RemoteTerminalFailure { code = -32_002; kind = safe.kind.rawValue; message = safe.localizedDescription }
        else if let safe = error as? RemoteWorkspaceFailure { code = -32_001; kind = safe.kind.rawValue; message = safe.localizedDescription }
        else { let safe = error as? RemoteEnvironmentError ?? .init(.unavailable); code = -32_000; kind = safe.kind.rawValue; message = safe.localizedDescription }
        return .object(["jsonrpc": .string("2.0"), "id": id, "error": .object([
            "code": .number(Double(code)), "message": .string(message), "data": .object(["kind": .string(kind)])])])
    }
    private struct Arguments {
        let directory: URL
        let expected: UUID?
        let label: String
        let options: RemoteEnvironmentOptions
        init(_ values: [String]) throws {
            var fields: [String: String] = [:], index = 1
            let allowed = Set(["--data-directory", "--expected-environment-id", "--label", "--codex-executable", "--codex-home", "--claude-executable", "--claude-configuration-directory"])
            var stdio = false
            while index < values.count {
                let name = values[index]; index += 1
                if name == "--stdio" { guard !stdio else { throw RemoteEnvironmentError(.invalidRequest) }; stdio = true; continue }
                guard allowed.contains(name), fields[name] == nil, index < values.count else { throw RemoteEnvironmentError(.invalidRequest) }
                let value = values[index]; index += 1
                guard !value.isEmpty, value.utf8.count <= 16_384,
                      !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw RemoteEnvironmentError(.invalidRequest) }
                fields[name] = value
            }
            guard stdio, let path = fields["--data-directory"], path.hasPrefix("/") else { throw RemoteEnvironmentError(.invalidRequest) }
            for name in ["--codex-executable", "--codex-home", "--claude-executable", "--claude-configuration-directory"] {
                if let value = fields[name], !value.hasPrefix("/") { throw RemoteEnvironmentError(.invalidRequest) }
            }
            if let raw = fields["--expected-environment-id"] {
                guard let id = UUID(uuidString: raw) else { throw RemoteEnvironmentError(.invalidRequest) }; expected = id
            } else { expected = nil }
            directory = URL(fileURLWithPath: path).standardizedFileURL
            label = fields["--label"] ?? ProcessInfo.processInfo.hostName
            options = .init(codexExecutable: fields["--codex-executable"] ?? "codex", codexHome: fields["--codex-home"],
                            claudeExecutable: fields["--claude-executable"] ?? "claude", claudeConfigurationDirectory: fields["--claude-configuration-directory"])
        }
    }
}

private struct RemoteEnvironmentStdioFrame: Sendable { let value: JSONValue; let byteCount: Int }
private final class RemoteEnvironmentStdioInput: @unchecked Sendable {
    let frames: AsyncThrowingStream<RemoteEnvironmentStdioFrame, any Error>
    private let continuation: AsyncThrowingStream<RemoteEnvironmentStdioFrame, any Error>.Continuation
    private let queue = DispatchQueue(label: "com.apoorvdarshan.coincide.remote-stdin")
    private let source: DispatchSourceRead
    private let drained = DispatchGroup()
    private var decoder = NDJSONDecoder(maximumFrameSize: RemoteEnvironmentProtocol.maximumWorkspaceRequestBytes)
    private var queuedBytes = 0
    private var stopped = false
    init() throws {
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else { throw RemoteEnvironmentError(.unavailable) }
        (frames, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(RemoteEnvironmentProtocol.maximumPendingRequests))
        source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
        drained.enter()
        source.setEventHandler { [weak self] in self?.read() }
        let drained = drained
        source.setCancelHandler { Darwin.close(STDIN_FILENO); drained.leave() }
        source.resume()
    }
    private func read() {
        guard !stopped else { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        do {
            var consumed = 0
            while consumed < 65_536 {
                let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                if count > 0 {
                    consumed += count
                    for frame in try decoder.append(Data(bytes.prefix(count))) {
                        try enqueue(frame)
                    }
                } else if count == 0 {
                    for frame in try decoder.finish() {
                        try enqueue(frame)
                    }
                    finish(nil); return
                } else if errno == EINTR { continue }
                else if errno == EAGAIN || errno == EWOULDBLOCK { return }
                else { throw RemoteEnvironmentError(.unavailable) }
            }
        } catch { finish(RemoteEnvironmentError(.invalidRequest)) }
    }
    private func enqueue(_ value: JSONValue) throws {
        let count = try JSONEncoder().encode(value).count
        guard queuedBytes <= RemoteEnvironmentProtocol.maximumQueuedRequestBytes - count else { throw RemoteEnvironmentError(.limitExceeded) }
        queuedBytes += count
        if case .dropped = continuation.yield(.init(value: value, byteCount: count)) { throw RemoteEnvironmentError(.limitExceeded) }
    }
    func consumed(_ count: Int) { queue.async { self.queuedBytes = max(0, self.queuedBytes - count) } }
    private func finish(_ error: (any Error)?) {
        guard !stopped else { return }; stopped = true
        continuation.finish(throwing: error); source.cancel()
    }
    func stop() { queue.async { self.finish(nil) } }
    func join() async { await withCheckedContinuation { continuation in drained.notify(queue: .global()) { continuation.resume() } } }
}
private actor RemoteWorkspaceReadResponses {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var closed = false
    func submit(id: JSONValue, operation: @escaping @Sendable () async throws -> JSONValue,
                writer: RemoteEnvironmentStdioWriter, disconnect: @escaping @Sendable () -> Void) throws {
        guard !closed, tasks.count < 8 else { throw RemoteWorkspaceFailure(.busy) }
        let key = UUID()
        tasks[key] = Task {
            let response: JSONValue
            do { response = RemoteEnvironmentStdio.response(id: id, result: try await operation()) }
            catch { response = RemoteEnvironmentStdio.errorResponse(id: id, error: error) }
            do { try Task.checkCancellation(); try await writer.send(response) }
            catch { if !Task.isCancelled { disconnect() } }
            self.finished(key)
        }
    }
    private func finished(_ id: UUID) { tasks.removeValue(forKey: id) }
    func close() async {
        closed = true
        let owned = Array(tasks.values)
        for task in owned { task.cancel() }
        for task in owned { await task.value }
    }
}
private actor RemoteEnvironmentStdioWriter {
    private var writing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init() throws {
        let flags = fcntl(STDOUT_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1) == 0 else { throw RemoteEnvironmentError(.unavailable) }
    }
    private func acquire() async throws {
        if !writing { writing = true; return }
        guard waiters.count < RemoteEnvironmentProtocol.maximumPendingRequests else { throw RemoteEnvironmentError(.limitExceeded) }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { writing = false }
        else { waiters.removeFirst().resume() }
    }
    func send(_ value: JSONValue) async throws {
        try await acquire()
        defer { release() }
        var bytes = try JSONEncoder().encode(value)
        guard bytes.count < RemoteEnvironmentProtocol.maximumFrameBytes else { throw RemoteEnvironmentError(.limitExceeded) }
        bytes.append(10)
        let deadline = ContinuousClock.now + .seconds(10)
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw RemoteEnvironmentError(.unavailable) }
            let count = bytes.withUnsafeBytes { buffer in Darwin.write(STDOUT_FILENO, buffer.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { try await Task.sleep(for: .milliseconds(2)) }
            else { throw RemoteEnvironmentError(.unavailable) }
        }
    }
}
