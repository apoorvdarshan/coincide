import Foundation
import Testing

@testable import CoincideKit

/// An in-memory stdio transport. Lines the client writes go to `onWrite`; `deliver` plays
/// lines from the agent asynchronously, in order, as a real pipe would.
@MainActor
final class ACPFakeTransport: ACPTransport {
    var onLine: ((String) -> Void)?
    var onStderr: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    var onWrite: ((JSONValue) -> Void)?
    let arguments: [String]
    let environment: [String: String]
    private(set) var written: [JSONValue] = []
    private(set) var isTerminated = false

    init(arguments: [String] = [], environment: [String: String] = [:]) {
        self.arguments = arguments
        self.environment = environment
    }

    func start() throws {}

    func write(_ line: String) {
        guard let message = JSONValue.parse(line) else {
            Issue.record("Client wrote a line that is not JSON: \(line)")
            return
        }
        written.append(message)
        onWrite?(message)
    }

    func terminate() { isTerminated = true }

    func deliver(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onLine?(line) }
        }
    }

    func exit(status: Int32, stderr: String) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onExit?(status, stderr) }
        }
    }
}

/// A scriptable ACP agent on top of `ACPFakeTransport`. Requests get default answers unless a test
/// installs a handler for the method.
@MainActor
final class ACPFakeAgent {
    typealias Handler = (_ id: JSONValue, _ params: JSONValue) -> Void

    var initializeResult: JSONValue = ["protocolVersion": 1, "agentCapabilities": ["loadSession": true]]
    var sessionResult: JSONValue = ["sessionId": "sess-1"]
    var loadResult: JSONValue = [:]
    var handlers: [String: Handler] = [:]
    private(set) var transports: [ACPFakeTransport] = []
    private(set) var requests: [(method: String, params: JSONValue)] = []
    private(set) var notifications: [(method: String, params: JSONValue)] = []
    /// Answers the client sent to the agent's own requests, by request id.
    private(set) var answers: [Int: JSONValue] = [:]
    private(set) var lastPromptID: JSONValue?

    var transport: ACPFakeTransport { transports.last! }

    /// Pass to `ACPSession(launch:flavor:transport:)`.
    var factory: ACPTransportFactory {
        { [unowned self] _, arguments, _, environment in
            let transport = ACPFakeTransport(arguments: arguments, environment: environment)
            transport.onWrite = { [unowned self] in self.receive($0) }
            self.transports.append(transport)
            return transport
        }
    }

    func requests(_ method: String) -> [JSONValue] {
        requests.filter { $0.method == method }.map(\.params)
    }

    func notifications(_ method: String) -> [JSONValue] {
        notifications.filter { $0.method == method }.map(\.params)
    }

    private func receive(_ message: JSONValue) {
        if let method = message["method"]?.string {
            let params = message["params"] ?? .null
            if let id = message["id"] {
                requests.append((method, params))
                handle(method, id, params)
            } else {
                notifications.append((method, params))
            }
        } else if let id = message["id"]?.int {
            answers[id] = message
        }
    }

    private func handle(_ method: String, _ id: JSONValue, _ params: JSONValue) {
        if let handler = handlers[method] {
            handler(id, params)
            return
        }
        switch method {
        case "initialize": reply(id, initializeResult)
        case "session/new": reply(id, sessionResult)
        case "session/load", "session/resume": reply(id, loadResult)
        case "session/prompt": lastPromptID = id
        default: reply(id, [:])
        }
    }

    func reply(_ id: JSONValue, _ result: JSONValue) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func fail(_ id: JSONValue, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]])
    }

    /// Ends the pending prompt.
    func finishPrompt(_ stopReason: String = "end_turn", usage: JSONValue? = nil) {
        guard let id = lastPromptID else {
            Issue.record("No prompt is pending")
            return
        }
        lastPromptID = nil
        var result: [String: JSONValue] = ["stopReason": .string(stopReason)]
        if let usage { result["usage"] = usage }
        reply(id, .object(result))
    }

    func update(_ update: JSONValue, session: String = "sess-1", meta: JSONValue? = nil) {
        var params: [String: JSONValue] = ["sessionId": .string(session), "update": update]
        if let meta { params["_meta"] = meta }
        notify("session/update", .object(params))
    }

    func notify(_ method: String, _ params: JSONValue) {
        send(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    /// Sends a request from the agent to the client.
    func ask(_ id: Int, _ method: String, _ params: JSONValue) {
        send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
    }

    func send(_ message: JSONValue) {
        transport.deliver(message.compactJSON)
    }
}

/// Collects a session's events.
@MainActor
final class ACPEventLog {
    private(set) var events: [AgentEvent] = []

    func attach(_ session: AgentSession) {
        session.onEvent = { [weak self] in self?.events.append($0) }
    }

    var completions: [TurnOutcome] {
        events.compactMap { if case .turnCompleted(let outcome) = $0 { outcome } else { nil } }
    }

    var approvals: [ApprovalRequest] {
        events.compactMap { if case .approvalRequested(let request) = $0 { request } else { nil } }
    }

    var notices: [String] {
        events.compactMap { if case .notice(let text) = $0 { text } else { nil } }
    }

    var questions: [UserInputRequest] {
        events.compactMap { if case .userInputRequested(let request) = $0 { request } else { nil } }
    }

    var sessionIDs: [String] {
        events.compactMap { if case .sessionStarted(let id) = $0 { id } else { nil } }
    }

    func removeAll() { events.removeAll() }
}

/// Polls until `condition` holds, failing the test after `timeout`.
@MainActor
func acpWaitUntil(
    _ description: String = "condition", timeout: Duration = .seconds(3), sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else {
            Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Lets queued main-queue deliveries run.
@MainActor
func acpSettle() async {
    for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(10)) }
}

func acpLaunch(
    _ provider: ProviderKind = .grok, resume: String? = nil, accessMode: AccessMode = .approval,
    directory: URL = URL(fileURLWithPath: NSTemporaryDirectory()), environment: [String: String] = [:]
) -> AgentLaunch {
    AgentLaunch(
        provider: provider, executable: URL(fileURLWithPath: "/usr/bin/true"), environment: environment,
        workingDirectory: directory, resumeSessionID: resume,
        selection: ModelSelection(provider: provider, modelID: "default"), accessMode: accessMode, interactionMode: .build)
}

func acpTurn(
    _ text: String, _ provider: ProviderKind = .grok, model: String = "default", effort: String? = nil,
    accessMode: AccessMode = .approval, interactionMode: InteractionMode = .build, images: [String] = []
) -> AgentTurnInput {
    AgentTurnInput(
        text: text, imagePaths: images, selection: ModelSelection(provider: provider, modelID: model, effort: effort),
        accessMode: accessMode, interactionMode: interactionMode)
}

/// A flavor that follows the spec with no vendor behavior, with a few knobs for tests.
struct ACPPlainFlavor: ACPAgentFlavor {
    var kind: ProviderKind = .grok
    var launchArguments: [String] = []
    var capabilities = ACPClientCapabilities()
    var configuredAuthMethod: String?
    var signsInWhenRequired = true
    var extraEnvironment: [String: String] = [:]
    var modeForAccess: [AccessMode: String] = [:]

    var provider: ProviderKind { kind }
    func arguments(for accessMode: AccessMode) -> [String] { launchArguments }
    func environment(_ base: [String: String], executable: URL) -> [String: String] {
        base.merging(extraEnvironment) { $1 }
    }
    var clientCapabilities: ACPClientCapabilities { capabilities }
    func authMethodID(environment: [String: String]) -> String? { configuredAuthMethod }
    var authenticatesWhenRequired: Bool { signsInWhenRequired }
    func sessionMode(for accessMode: AccessMode) -> String? { modeForAccess[accessMode] }
}

/// The first prompt of a session carries the interaction-mode instructions.
func acpInstructed(_ text: String, _ mode: InteractionMode = .build) -> String {
    ACPPrompt.text(text, mode: mode, previousMode: nil)
}

func acpTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-acp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return URL(fileURLWithPath: ACPFileSystem.realPath(directory.path) ?? directory.path)
}
