import Foundation
import Testing
@testable import CoincideCore

@Test(arguments: ["valid", "wrong-nonce", "replacement", "foreign-user"])
func piFreshHistoryReprovesExpandedInputAfterCrashBeforeTerminalJournal(_ mode: String) throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pi-bridge-recovery-\(UUID())")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let root = URL(fileURLWithPath: try PiRuntimeConfiguration.physical(temporary.path))
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try PiRuntimeConfiguration(instanceID: UUID(), executable: "/never-executed/pi", requestedExecutable: "pi",
        workspacePath: root.path, homeDirectory: root.path, agentDirectory: root.appendingPathComponent("agent").path,
        agentDirectorySelection: .explicitDirectory(environmentPath: root.appendingPathComponent("agent").path))
    let configuration = PiConfiguration(instanceID: runtime.instanceID, executable: "pi", runtime: runtime)
    let path = root.appendingPathComponent("native.jsonl"), session = UUID().uuidString.lowercased()
    let intent = try PiFreshSessionIntent(id: UUID(), operationID: UUID(), runtimeIdentity: configuration.runtimeIdentity,
        nativeSessionFile: path.path, sourceNativeSessionFile: root.appendingPathComponent("source.jsonl").path,
        originalNativeSessionID: UUID().uuidString.lowercased(), sourceInventoryDigest: String(repeating: "a", count: 64),
        semanticDigest: String(repeating: "b", count: 64))
    let preparationID = UUID(), original = ProviderInput(text: "Use $review 工作")
    let expanded = ProviderInput(text: "Use $review 工作\n\n<skill>Actual native expansion</skill>")
    let reservation = try PiInputBridgeReservation(nonce: UUID(), processEpoch: UUID(), runPreparationID: preparationID,
        clientMessageID: "authored-input", originalDigest: PiHistoryInputEvidence.digest(original),
        nativeSessionID: session, nativeSessionFile: path.path)
    let opening = try PiHistoryInputEvidence(clientMessageID: reservation.clientMessageID, inputDigest: reservation.originalDigest,
        kind: .opening, bridgeReservation: reservation)
    let baseline = try PiRuntimeEntryObservation(nativeSessionFile: path.path, nativeSessionID: session, leafID: nil, entries: [])
    let preparation = try PiRunHistoryPreparation(id: preparationID, runID: UUID(), runtimeIdentity: configuration.runtimeIdentity,
        observedVersion: "0.80.5", openingInput: opening, baseline: baseline, freshIntentID: intent.id, freshEmptyObservation: baseline)
    let prepared = try PiRunHistoryEvidence(preparation: preparation)
    let recalled = try JSONDecoder().decode(PiRunHistoryEvidence.self, from: JSONEncoder().encode(prepared))
    #expect(recalled.inputs.first?.bridgeReservation == reservation && recalled.inputs.first?.bridgeEvidence == nil)
    let markerReservation = mode == "wrong-nonce" ? try PiInputBridgeReservation(nonce: UUID(), processEpoch: reservation.processEpoch,
        runPreparationID: preparationID, clientMessageID: reservation.clientMessageID, originalDigest: reservation.originalDigest,
        nativeSessionID: session, nativeSessionFile: path.path) : reservation
    let stamp = "2026-10-23T00:00:00.000Z"
    let marker = try PiInputBridgeMarker(reservation: markerReservation, expandedDigest: PiHistoryInputEvidence.digest(expanded),
        id: "proof-marker", parentID: nil, timestamp: stamp)
    let header: JSONValue = .object(["type": .string("session"), "version": .number(3), "id": .string(session),
        "cwd": .string(root.path), "timestamp": .string(stamp)])
    func user(_ id: String, parent: String, text: String) -> JSONValue {
        .object(["type": .string("message"), "id": .string(id), "parentId": .string(parent), "timestamp": .string(stamp),
            "message": .object(["role": .string("user"), "content": .string(text)])])
    }
    var rows = [header, marker.rawEntry, user("native-user", parent: "proof-marker", text: mode == "replacement" ? "Replaced by another extension" : expanded.text)]
    if mode == "foreign-user" { rows.append(user("foreign-user", parent: "native-user", text: "Unowned input")) }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var bytes = Data()
    for row in rows { bytes.append(try encoder.encode(row)); bytes.append(10) }
    try bytes.write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    let service = try PiHistoryService(configuration: runtime)
    let result = try service.inspectFresh(intent: intent, consumer: recalled)
    if mode == "valid" {
        let file = try PiHistoryFileReader().read(filePath: path.path, expectedWorkspacePath: root.path, expectedSessionID: session)
        #expect(result == .persisted(try PiHistoryFileRevision(file)))
    } else { #expect(result == .unavailable) }
    #expect(try service.inspectFresh(intent: intent, consumer: nil) == .unavailable)
    #expect(try Data(contentsOf: path) == bytes)
    #expect(recalled == prepared)
}
