import Foundation
import Darwin
import Testing
@testable import CoincideCore

@Test func piResumeRejectsFIFOWithoutBlockingBeforeRegularFileValidation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pi-fifo-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let path = root.appendingPathComponent("saved-session.jsonl").path
    guard mkfifo(path, 0o600) == 0 else { throw CoincideError("Could not create the owned FIFO fixture.") }
    let release = DispatchGroup(); release.enter()
    // Make a blocking implementation fail a bounded timing assertion instead
    // of hanging the test process forever. The helper opens only this FIFO.
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) {
        let descriptor = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        if descriptor >= 0 { Darwin.close(descriptor) }
        release.leave()
    }
    defer { release.wait(); try? FileManager.default.removeItem(at: root) }
    let start = ContinuousClock.now
    #expect(throws: (any Error).self) { _ = try PiProtocol.resumeHeader(path, cwd: root) }
    #expect(start.duration(to: .now) < .milliseconds(200))
}

@Test func piProtocolFramingPreservesUnicodeSeparatorsAndRejectsMalformedOrOversizedFrames() throws {
    let value = JSONValue.object(["type": .string("message_update"), "text": .string("日本語\u{2028}\u{2029}exact")])
    var data = try JSONEncoder().encode(value); data.append(contentsOf: [13, 10])
    var decoder = NDJSONDecoder(maximumFrameSize: 512), decoded: [JSONValue] = []
    for byte in data { decoded += try decoder.append(Data([byte])) }
    #expect(decoded == [value])
    var invalid = NDJSONDecoder(maximumFrameSize: 5)
    #expect(throws: (any Error).self) { _ = try invalid.append(Data("123456".utf8)) }
}

@Test func piModelsKeepProviderAndModelIdentitySeparateAndRejectConflictingOrMalformedCatalogRows() throws {
    let raw = JSONValue.object(["models": .array([
        .object(["provider": .string("one"), "id": .string("same/model"), "name": .string("First"), "reasoning": .bool(true), "thinkingLevelMap": .object(["high": .null, "max": .string("maximum")])]),
        .object(["provider": .string("two"), "id": .string("same/model"), "name": .string("Second")])])])
    let rows = try PiProtocol.models(raw)
    #expect(rows.count == 2 && rows[0].id != rows[1].id)
    #expect(rows[0].piSelection?.modelID == "same/model")
    #expect(rows[0].piThinkingLevels == ["off", "minimal", "low", "medium", "max"])
    var conflicting = raw["models"].array ?? []
    conflicting.append(.object(["provider": .string("one"), "id": .string("same/model"), "name": .string("Changed")]))
    #expect(throws: (any Error).self) { _ = try PiProtocol.models(.object(["models": .array(conflicting)])) }
    #expect(throws: (any Error).self) { _ = try PiProtocol.models(.object(["models": .array([.object(["provider": .string(""), "id": .string("bad")])])])) }
}

@Test func piExtensionRequestsBoundShapesAndDistinguishEmptyValuesFromMalformedSelection() throws {
    let request = ApprovalRequest(id: .string("local"), method: "pi/extension", params: .object(["method": .string("editor"), "title": .string("Edit"), "prefill": .string("")]))
    let typed = try PiExtensionRequest.presentation(request)
    #expect(typed.prefill == "" && typed.method == .editor)
    for invalid in [JSONValue.object(["method": .string("select"), "title": .string("Choose"), "options": .array([.string("duplicate"), .string("duplicate")])]),
                    .object(["method": .string("unknown"), "title": .string("Unknown")]),
                    .object(["method": .string("confirm"), "title": .number(2)])] {
        #expect(throws: (any Error).self) { _ = try PiExtensionRequest(params: invalid) }
    }
}

@Test func piProjectionScopesSnapshotsDeltasAndToolsToExactRunAndRejectsUnknownToolMutation() throws {
    var projection = PiProjection(scope: "session-first-run")
    _ = try projection.apply(.object(["type": .string("message_start"), "message": .object(["role": .string("assistant")])]))
    let first = try projection.apply(.object(["type": .string("message_update"), "assistantMessageEvent": .object(["type": .string("text_delta"), "contentIndex": .number(0), "delta": .string("partial")])]))
    let final = try projection.apply(.object(["type": .string("message_end"), "message": .object(["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("exact snapshot")])])])]))
    let a = try #require(first.first), b = try #require(final.first)
    #expect(a.key == b.key && a.key.sessionID == "session-first-run")
    let entity = try b.apply(to: a.apply(to: nil))
    #expect(entity.text == "exact snapshot")
    let unknown = try projection.apply(.object(["type": .string("tool_execution_end"), "toolCallId": .string("unknown"), "isError": .bool(false)]))
    #expect(unknown.isEmpty)
}
