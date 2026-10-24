import Darwin
import Foundation
import Testing
@testable import CoincideCore

func contextHandoffTestInput(text: String = "Actual new input 工作 e\u{301}\n  Keep literal spacing.\n") throws -> ProviderInput {
    let transfer = UUID()
    let source = ContextHandoffCoverage(transferID: transfer, sourceThreadID: UUID(), sourceRunID: UUID(), strategy: "portable_context")
    let selected = try ContextHandoffService.select(messages: [
        .init(id: "original-user", role: "user", kind: "user_message", text: "Original constraints\n  Preserve source whitespace.\n"),
        .init(id: "original-tool", role: "tool", kind: "command_execution", text: "Command: offline check\nExit code: 1\nExact saved diagnostic")
    ], coverage: source)
    return .init(text: text, historicalContext: .init(deliveryID: UUID(), transferIDs: [transfer], selection: selected))
}

actor ContextHandoffLegacySession: ProviderSession {
    nonisolated let events = AsyncStream<ProviderEvent> { $0.finish() }
    private(set) var received: [String] = []
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) { received.append(text) }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() {}
}

@Test func contextHandoffLegacyProviderFallbackRendersOnceAndRefusesUnsupportedImages() async throws {
    let legacy = ContextHandoffLegacySession(), session: any ProviderSession = legacy
    let input = try contextHandoffTestInput(), thread = CodingThread(project: .init(path: "/private/offline-context"))
    let expected = try input.providerText()
    try await session.send(input: input, thread: thread)
    #expect(await legacy.received == [expected])
    var withImage = input; withImage.images = [.init(mimeType: "image/png", data: try attachmentImageData())]
    await #expect(throws: CoincideError.self) { try await session.send(input: withImage, thread: thread) }
    #expect(await legacy.received.count == 1)
    #expect(throws: ProviderSteeringError(.unsupported)) { try input.requireNoHistoricalContextForSteering() }
}

@Test func contextHandoffPreservesWholePriorityItemsTruthfulActivityAndExplicitOmissions() throws {
    let original = "Preserve every line.\n\n  And this indentation.\n"
    let messages: [ContextHandoffMessage] = [
        .init(id: "first-user", role: "user", kind: "user_message", text: original),
        .init(id: "huge", role: "assistant", kind: "assistant_message", text: String(repeating: "界🧪", count: 20_000)),
        .init(id: "old", role: "assistant", kind: "assistant_message", text: String(repeating: "x", count: 4_000)),
        .init(id: "latest-user", role: "user", kind: "user_message", text: "Current constraints"),
        .init(id: "latest-assistant", role: "assistant", kind: "assistant_message", text: "Latest partial work 日本語 مرحبا"),
        .init(id: "tool", role: "tool", kind: "command_execution", text: "Command: local check\nExit code: 1\nExact outcome"),
        .init(id: "private-reasoning", role: "reasoning", kind: "reasoning", text: "NEVER_IN_HANDOFF")
    ]
    let coverage = ContextHandoffCoverage(transferID: UUID(), sourceThreadID: UUID(), strategy: "fork_delta_context",
        additionalOmittedIDs: ["private-session-state"])
    let selection = try ContextHandoffService.select(messages: messages, coverage: coverage, budget: 3_500)
    #expect(selection.includedIDs == ["first-user", "latest-user", "latest-assistant", "tool"])
    #expect(selection.omittedIDs == ["private-session-state", "huge", "old", "private-reasoning"])
    #expect(selection.messages.first?.text.utf8.elementsEqual(original.utf8) == true)
    #expect(selection.renderedText.contains("Historical tool") && selection.renderedText.contains("command_execution"))
    #expect(!selection.renderedText.contains("NEVER_IN_HANDOFF") && !selection.coverage.contains("t3_context_read"))
    #expect(try ContextHandoffService.select(messages: messages, coverage: coverage, budget: 3_500) == selection)
    try ContextHandoffService.validate(selection)
}

@Test func contextHandoffCountsEscapedMultilingualWireEnvelopesAndCounterBoundaries() throws {
    let messages = (0..<500).map { index in
        ContextHandoffMessage(id: "item-\(index)", role: index % 2 == 0 ? "user" : "assistant", kind: "message",
            text: String(repeating: "\0\\\"🧪界", count: 15))
    }
    let coverage = ContextHandoffCoverage(transferID: UUID(), sourceThreadID: UUID(), strategy: "portable_context", retrievalAvailable: true)
    for budget in [2_000, 4_000, 9_999, 10_000, 16_000, 64_000] {
        let selection = try ContextHandoffService.select(messages: messages, coverage: coverage, budget: budget)
        #expect(selection.cost <= budget && selection.renderedText.utf8.count <= budget)
        #expect(selection.includedIDs.count + selection.omittedIDs.count == messages.count)
        #expect(!selection.omittedIDs.isEmpty && selection.coverage.contains("t3_context_read"))
        for selected in selection.messages { #expect(messages.first { $0.id == selected.id } == selected) }
        try ContextHandoffService.validate(selection)
    }
    #expect(throws: ContextHandoffError(.budgetExceeded)) { try ContextHandoffService.select(messages: [], coverage: coverage, budget: 0) }
}

@Test func contextHandoffBudgetSubtractsCurrentInputAttachmentsUsageAndSpaceForWork() throws {
    let image = ChatAttachment(id: UUID(), name: "image.png", mimeType: "image/png", byteCount: 1, digest: String(repeating: "a", count: 64), fileExtension: "png")
    let plain = try ContextHandoffBudget.available(userText: "Continue", modelContextWindow: 32_000)
    let withImage = try ContextHandoffBudget.available(userText: "Continue", attachments: [image], modelContextWindow: 32_000)
    #expect(plain < 16_000 && withImage < plain)
    #expect(try ContextHandoffBudget.available(userText: String(repeating: "界", count: 30_000), modelContextWindow: 32_000) == 0)
    #expect(try ContextHandoffBudget.available(userText: "Continue", modelContextWindow: 24_000, nativeUsedTokens: 23_000) == 0)
    #expect(try ContextHandoffBudget.available(userText: "Continue", tokenCap: 100_000, modelContextWindow: 1_000_000) == 64_000)
}

@Test func contextHandoffCoverageNamesEveryScopedTransferAndPreservesSingleTransferCoding() throws {
    let first = UUID(), additional = (0..<31).map { _ in UUID() }
    let coverage = ContextHandoffCoverage(transferID: first, sourceThreadID: UUID(), strategy: "combined_context",
        retrievalAvailable: true, additionalTransferIDs: additional)
    let selection = try ContextHandoffService.select(messages: [], coverage: coverage)
    for id in [first] + additional { #expect(selection.renderedText.contains(id.uuidString)) }
    try ProviderHistoricalContext(deliveryID: UUID(), transferIDs: [first] + additional, selection: selection).validate()
    #expect(throws: ContextHandoffError(.invalidSource)) {
        try ProviderHistoricalContext(deliveryID: UUID(), transferIDs: [first], selection: selection).validate()
    }
    for invalid in [[first], [additional[0], additional[0]], additional + [UUID()]] {
        let wrong = ContextHandoffCoverage(transferID: first, sourceThreadID: coverage.sourceThreadID,
            strategy: "combined_context", additionalTransferIDs: invalid)
        #expect(throws: ContextHandoffError(.invalidSource)) { _ = try ContextHandoffService.select(messages: [], coverage: wrong) }
    }
    let single = ContextHandoffCoverage(transferID: first, sourceThreadID: coverage.sourceThreadID, strategy: "portable_context")
    let bytes = try JSONEncoder().encode(single)
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(object["additionalTransferIDs"] == nil)
    let decoded = try JSONDecoder().decode(ContextHandoffCoverage.self, from: bytes)
    #expect(decoded == single && decoded.additionalTransferIDs.isEmpty)
    let original = try ContextHandoffService.select(messages: [], coverage: single)
    let restored = try JSONDecoder().decode(ContextHandoffSelection.self, from: JSONEncoder().encode(original))
    try ContextHandoffService.validate(restored)
    #expect(restored.digest == original.digest)
}

@Test func contextHandoffTypedInputKeepsLiteralBytesAndRejectsChangedSavedSelection() throws {
    let input = try contextHandoffTestInput(), literal = input.text
    let blocks = try input.providerTextBlocks()
    #expect(blocks.count == 2 && blocks.last?.utf8.elementsEqual(literal.utf8) == true)
    #expect(try input.providerText().hasSuffix("\n\nUser message:\n" + literal))
    #expect(input.text.utf8.elementsEqual(literal.utf8) && input.images.isEmpty)
    let legacy = ProviderInput(text: literal)
    let legacyText = try legacy.providerText(), legacyBlocks = try legacy.providerTextBlocks()
    #expect(legacyText.utf8.elementsEqual(literal.utf8) && legacyBlocks == [literal])
    let context = try #require(input.historicalContext)
    for field in ["renderedText", "coverage", "digest", "includedIDs"] {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: Any])
        var selection = try #require(object["selection"] as? [String: Any])
        selection[field] = field == "includedIDs" ? ["wrong-item"] : "changed"
        object["selection"] = selection
        let changed = try JSONDecoder().decode(ProviderHistoricalContext.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: ContextHandoffError(.invalidSource)) { try changed.validate() }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["codex", "claude"], [false, true])
func contextHandoffActualPrivateProvidersReceiveSeparateHistoryAndLiteralBlocks(profile: String, image: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-context-delivery-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let fixture = try #require(Bundle.module.url(forResource: "context_handoff_provider", withExtension: "py", subdirectory: "Fixtures"))
    try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("peer.py"))
    let executable = root.appendingPathComponent("private-provider")
    let script = "#!/bin/sh\ncoincide_peer_root=\"$(dirname \"$0\")\"\nexec /usr/bin/env -i PATH=/usr/bin:/bin HOME=\"$coincide_peer_root\" /usr/bin/python3 \"$coincide_peer_root/peer.py\" " + profile + " \"$coincide_peer_root\"\n"
    try Data(script.utf8).write(to: executable); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    var input = try contextHandoffTestInput()
    if image { input.images.append(.init(mimeType: "image/png", data: try attachmentImageData())) }
    var expected: [String: JSONValue] = ["text": .array(try input.providerTextBlocks().map(JSONValue.string))]
    if let value = input.images.first { expected["image"] = .string(value.data.base64EncodedString()) }
    try JSONEncoder().encode(JSONValue.object(expected)).write(to: root.appendingPathComponent("expected.json"))
    for name in ["expected.json", "peer.py"] {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(name).path)
    }
    let session: any ProviderSession
    switch profile {
    case "codex": session = try CodexSession(executable: executable, cwd: root, arguments: [])
    default: session = try ClaudeSession(executable: executable, cwd: root, arguments: [])
    }
    var thread = CodingThread(project: .init(path: root.path), model: "fixture")
    thread.provider = profile == "codex" ? .codex : .claude
    thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: Date())
    do {
        try await session.send(input: input, thread: thread)
        let receipt = root.appendingPathComponent("checked.json"), deadline = ContinuousClock.now + .seconds(8)
        while !FileManager.default.fileExists(atPath: receipt.path) {
            guard ContinuousClock.now < deadline else { throw CoincideError("The private context-delivery peer did not confirm its input blocks.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let checked = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: receipt))
        #expect(checked["count"] == .number(1) && checked["literalExact"] == .bool(true) && checked["historySeparate"] == .bool(true))
        #expect(input.text == "Actual new input 工作 e\u{301}\n  Keep literal spacing.\n")
        await session.close()
        let pid = try #require(Int32(String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        try FileManager.default.removeItem(at: root)
    } catch { await session.close(); print("Private context-delivery fixture retained at \(root.path)"); throw error }
}
