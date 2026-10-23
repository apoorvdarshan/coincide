import Darwin
import Foundation
import Testing
@testable import CoincideCore

private let bridgeTimestamp = "2026-10-23T00:00:00.000Z"
private let bridgeEpoch = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let bridgePreparation = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let bridgeNonce = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
private let bridgeSecondNonce = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
private let bridgeSessionID = "55555555-5555-4555-8555-555555555555"
private let bridgeFile = "/fixture/pi/session.jsonl"

private func bridgeReservation(_ input: ProviderInput, id: String = "opening-input", nonce: UUID = bridgeNonce,
                               retirement: UUID? = nil) throws -> PiInputBridgeReservation {
    try .init(nonce: nonce, processEpoch: bridgeEpoch, runPreparationID: bridgePreparation,
              clientMessageID: id, originalDigest: PiHistoryInputEvidence.digest(input),
              nativeSessionID: bridgeSessionID, nativeSessionFile: bridgeFile, retirementNonce: retirement)
}
private func bridgeBase() throws -> PiHistoryEntry {
    try .init(raw: .object(["type": .string("model_change"), "id": .string("base"), "parentId": .null,
                           "timestamp": .string(bridgeTimestamp), "provider": .string("fixture"), "modelId": .string("fixture-model")]))
}
private func bridgeUser(_ input: ProviderInput, id: String = "native-user", parent: String = "marker") throws -> PiHistoryEntry {
    var content: [JSONValue] = [.object(["type": .string("text"), "text": .string(input.text)])]
    content += input.images.map { .object(["type": .string("image"), "mimeType": .string($0.mimeType), "data": .string($0.data.base64EncodedString())]) }
    return try .init(raw: .object(["type": .string("message"), "id": .string(id), "parentId": .string(parent),
        "timestamp": .string(bridgeTimestamp), "message": .object(["role": .string("user"), "content": .array(content), "timestamp": .number(1)])]))
}
private func bridgeObservation(_ entries: [PiHistoryEntry], leaf: String? = nil) throws -> PiRuntimeEntryObservation {
    try .init(nativeSessionFile: bridgeFile, nativeSessionID: bridgeSessionID,
              leafID: leaf ?? entries.last?.id, entries: entries.map(PiHistoryEntryDescriptor.init))
}
private func bridgeFixture(original: ProviderInput = .init(text: "Use $review"),
                           expanded: ProviderInput = .init(text: "Use $review\n\n<skill>synthetic skill body</skill>")) throws
    -> (PiInputBridgeReservation, [PiHistoryEntry], PiRuntimeEntryObservation, PiRuntimeEntryObservation) {
    let reservation = try bridgeReservation(original), base = try bridgeBase()
    let marker = try PiInputBridgeMarker(reservation: reservation, expandedDigest: PiHistoryInputEvidence.digest(expanded),
        id: "marker", parentID: base.id, timestamp: bridgeTimestamp)
    let entries = try [base, PiHistoryEntry(raw: marker.rawEntry), bridgeUser(expanded)]
    return try (reservation, entries, bridgeObservation([base]), bridgeObservation(entries))
}

@Test func piInputBridgeProvesExpandedNativeUserAndRevalidatesOnlyDigestDescriptorsAfterCoding() throws {
    let (reservation, entries, baseline, final) = try bridgeFixture()
    let proofs = try PiInputBridge.prove(reservations: [reservation], entries: entries, baseline: baseline, finalObservation: final)
    #expect(proofs.count == 1 && proofs[0].nativeUserEntryID == "native-user")
    #expect(proofs[0].marker.reservation.originalDigest != proofs[0].expandedDigest)
    let bytes = try JSONEncoder().encode(proofs)
    #expect(!String(decoding: bytes, as: UTF8.self).contains("synthetic skill body"))
    let decoded = try JSONDecoder().decode([PiInputBridgeEvidence].self, from: bytes)
    #expect(decoded == proofs)
    try PiInputBridge.validate(reservations: [reservation], evidence: decoded, baseline: baseline, finalObservation: final)
    let marker = try PiInputBridgeMarker(entry: entries[1])
    #expect(try PiHistoryEntry(raw: marker.rawEntry).digest == entries[1].digest)
    let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(reservation))
    #expect(encoded["storage"] == .null && encoded["retirementNonce"] == .null)
    #expect(Set(encoded.object?.keys.map { $0 } ?? []) == PiInputBridge.reservationKeys)
}

@Test func piInputBridgeRejectsLaterTextAndImageReplacementDespiteValidHookMarker() throws {
    let image = ProviderImage(mimeType: "image/png", data: Data([1, 2, 3]))
    let input = ProviderInput(text: "original", images: [image])
    let (reservation, entries, baseline, _) = try bridgeFixture(original: input, expanded: input)
    let changed = [ProviderInput(text: "later replacement", images: [image]),
                   ProviderInput(text: input.text, images: [.init(mimeType: "image/png", data: Data([3, 2, 1]))])]
    for value in changed {
        let replaced = try [entries[0], entries[1], bridgeUser(value)]
        let final = try bridgeObservation(replaced)
        #expect(throws: PiHistoryGraphError.self) {
            try PiInputBridge.prove(reservations: [reservation], entries: replaced, baseline: baseline, finalObservation: final)
        }
    }
}

@Test func piInputBridgeRejectsNonadjacentMarkerForeignUserAndChangedMarkerEnvelope() throws {
    let (reservation, entries, baseline, final) = try bridgeFixture()
    let spacer = try PiHistoryEntry(raw: .object(["type": .string("custom"), "customType": .string("other-extension"),
        "data": .object([:]), "id": .string("spacer"), "parentId": .string("marker"), "timestamp": .string(bridgeTimestamp)]))
    let expanded = ProviderInput(text: "Use $review\n\n<skill>synthetic skill body</skill>")
    let nonadjacent = try [entries[0], entries[1], spacer, bridgeUser(expanded, parent: "spacer")]
    let nonadjacentFinal = try bridgeObservation(nonadjacent)
    #expect(throws: PiHistoryGraphError.self) {
        try PiInputBridge.prove(reservations: [reservation], entries: nonadjacent, baseline: baseline, finalObservation: nonadjacentFinal)
    }
    let foreign = try entries + [bridgeUser(.init(text: "foreign"), id: "foreign-user", parent: "native-user")]
    let foreignFinal = try bridgeObservation(foreign)
    #expect(throws: PiHistoryGraphError.self) {
        try PiInputBridge.prove(reservations: [reservation], entries: foreign, baseline: baseline, finalObservation: foreignFinal)
    }
    var changed = try #require(entries[1].raw.object)
    changed["nativeExtra"] = .string("not represented in the proof")
    let changedEntry = try PiHistoryEntry(raw: .object(changed))
    #expect(throws: PiHistoryGraphError.self) { try PiInputBridgeMarker(entry: changedEntry) }
    #expect(throws: PiHistoryGraphError.self) {
        try PiInputBridge.prove(reservations: [reservation], entries: [entries[0], changedEntry, entries[2]], baseline: baseline, finalObservation: final)
    }
}

@Test func piInputBridgeRejectsRepeatedNonceAndReorderedAuthoredOwners() throws {
    let input = ProviderInput(text: "identical native payload")
    let first = try bridgeReservation(input)
    let second = try bridgeReservation(input, id: "steer-input", nonce: bridgeSecondNonce)
    let base = try bridgeBase()
    let firstMarker = try PiInputBridgeMarker(reservation: first, expandedDigest: first.originalDigest, id: "marker-a", parentID: "base", timestamp: bridgeTimestamp)
    let secondMarker = try PiInputBridgeMarker(reservation: second, expandedDigest: second.originalDigest, id: "marker-b", parentID: "user-a", timestamp: bridgeTimestamp)
    let entries = try [base, PiHistoryEntry(raw: firstMarker.rawEntry), bridgeUser(input, id: "user-a", parent: "marker-a"),
                       PiHistoryEntry(raw: secondMarker.rawEntry), bridgeUser(input, id: "user-b", parent: "marker-b")]
    let baseline = try bridgeObservation([base]), final = try bridgeObservation(entries)
    let proof = try PiInputBridge.prove(reservations: [first, second], entries: entries, baseline: baseline, finalObservation: final)
    #expect(proof.map(\.nativeUserEntryID) == ["user-a", "user-b"])
    #expect(throws: PiHistoryGraphError.self) {
        try PiInputBridge.validate(reservations: [second, first], evidence: proof, baseline: baseline, finalObservation: final)
    }
    let reused = try bridgeReservation(input, id: "steer-input", nonce: first.nonce)
    #expect(throws: PiHistoryGraphError.self) {
        try PiInputBridge.validate(reservations: [first, reused], evidence: proof, baseline: baseline, finalObservation: final)
    }
}

@Test func piInputBridgeRetirementIsSeparateFromConsumptionAndKeepsFlatCoding() throws {
    let input = ProviderInput(text: "a new explicit input")
    let fresh = try bridgeReservation(input, nonce: bridgeSecondNonce, retirement: bridgeNonce)
    let bytes = try fresh.encoded()
    let raw = try JSONDecoder().decode(JSONValue.self, from: bytes)
    #expect(raw["retirementNonce"] == .string(bridgeNonce.uuidString.lowercased()))
    #expect(try PiInputBridgeReservation(json: raw) == fresh)
    #expect(try JSONDecoder().decode(PiInputBridgeReservation.self, from: JSONEncoder().encode(fresh)) == fresh)
    #expect(throws: PiHistoryGraphError.self) { try bridgeReservation(input, retirement: bridgeNonce) }
    var altered = try #require(raw.object); altered["nonce"] = .string("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
    #expect(throws: PiHistoryGraphError.self) { try PiInputBridgeReservation(json: .object(altered)) }
}

/// Runs only the generated app-owned fragment against a small native API peer.
/// The vendor package, CLI, credentials, model and browser are never imported.
/// Frontmatter itself remains the imported vendor helper in production; this
/// peer supplies a synthetic helper to isolate the bridge/FS/digest contract.
private func runBridgeJavaScript(_ body: String, fifoReservation: Bool = false) async throws -> JSONValue {
    let node = try #require(ProcessChannel.findExecutable("node"))
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pi-input-bridge-\(UUID())")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let root = URL(fileURLWithPath: try PiRuntimeConfiguration.physical(temporary.path))
    defer { try? FileManager.default.removeItem(at: root) }
    let sidecar = root.appendingPathComponent("reservation.json")
    if fifoReservation {
        guard mkfifo(sidecar.path, 0o600) == 0 else { throw CoincideError("The private Pi input bridge FIFO could not be created.") }
    }
    let fragment = try PiInputBridge.extensionFragment(reservationPath: sidecar.path, processEpoch: bridgeEpoch)
    let rawReservation = try bridgeReservation(.init(text: "Use $review $review $unknown", images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))])).json
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let literal = String(decoding: try encoder.encode(rawReservation), as: UTF8.self)
    let nativeSkill = try bridgeReservation(.init(text: "/skill:review args $review", images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))])).json
    let template = try bridgeReservation(.init(text: "/template $review", images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))])).json
    let nativeSkillLiteral = String(decoding: try encoder.encode(nativeSkill), as: UTF8.self)
    let templateLiteral = String(decoding: try encoder.encode(template), as: UTF8.self)
    let script = #"""
    import * as coincideInputFS from "node:fs";
    import * as coincideInputPath from "node:path";
    import { createHash as coincideInputHash } from "node:crypto";
    import assert from "node:assert/strict";
    const coincideStripFrontmatter = (text) => text.replace(/^---\r?\n[\s\S]*?\r?\n---(?:\r?\n|$)/, "");
    globalThis.fetch = () => { throw new Error("network forbidden"); };
    const root = process.argv[2];
    const sidecar = coincideInputPath.join(root, "reservation.json");
    const original = \#(literal);
    const nativeSkillReservation = \#(nativeSkillLiteral);
    const templateReservation = \#(templateLiteral);
    const image = { type: "image", mimeType: "image/png", data: "AQID" };
    const event = { source: "rpc", text: "Use $review $review $unknown", images: [image] };
    const stamp = "2026-10-23T00:00:00.000Z";
    const base = { type: "model_change", id: "base", parentId: null, timestamp: stamp, provider: "fixture", modelId: "fixture-model" };
    function install(pi) {
      \#(fragment)
    }
    function peer() {
      const hooks = new Map(), entries = [base], notices = [];
      let idle = true, pending = false;
      const manager = { getSessionFile: () => original.nativeSessionFile, getSessionId: () => original.nativeSessionID,
        getLeafId: () => entries.at(-1).id };
      const ctx = { sessionManager: manager, ui: { notify: (message, type) => notices.push({ message, type }) },
        isIdle: () => idle, hasPendingMessages: () => pending };
      const skill = coincideInputPath.join(root, "review-link.md");
      let commands = [{ name: "skill:review", source: "skill", sourceInfo: { path: skill } }];
      const pi = { on: (name, fn) => hooks.set(name, fn),
        getCommands: () => commands,
        appendEntry: (customType, data) => entries.push({ type: "custom", customType, data, id: "marker", parentId: manager.getLeafId(), timestamp: stamp }) };
      install(pi);
      return { hooks, ctx, entries, notices, setIdle: (value) => { idle = value; }, setPending: (value) => { pending = value; },
        setCommands: (value) => { commands = value; } };
    }
    function reserve(value, mode = 0o600) {
      try { coincideInputFS.unlinkSync(sidecar); } catch (e) { if (e.code !== "ENOENT") throw e; }
      coincideInputFS.writeFileSync(sidecar, JSON.stringify(value), { mode, flag: "wx" });
      // The peer must construct the requested permission case independently of
      // the test runner's inherited umask (including private-log runs at 077).
      coincideInputFS.chmodSync(sidecar, mode);
    }
    function appendUser(p, text, images = [image]) {
      const message = { role: "user", content: [{ type: "text", text }, ...images], timestamp: 1 };
      p.hooks.get("message_start")({ message }, p.ctx);
      p.hooks.get("message_end")({ message }, p.ctx);
      p.entries.push({ type: "message", id: "native-user", parentId: p.entries.at(-1).id, timestamp: stamp, message });
    }
    coincideInputFS.writeFileSync(coincideInputPath.join(root, "review.md"), "---\nname: ignored\n---\n  SYNTHETIC SKILL BODY  \n");
    coincideInputFS.symlinkSync(coincideInputPath.join(root, "review.md"), coincideInputPath.join(root, "review-link.md"));
    \#(body)
    """#
    let scriptURL = root.appendingPathComponent("peer.mjs")
    try Data(script.utf8).write(to: scriptURL, options: .atomic)
    let process = try ProcessChannel(executable: node, arguments: [scriptURL.path, root.path],
        environment: ["HOME": root.path, "TMPDIR": root.path, "PATH": "/usr/bin:/bin"])
    let deadline = Task {
        do { try await Task.sleep(for: .seconds(3)); process.stop() } catch { }
    }
    var bytes = Data(), status: Int32?
    do {
        for await event in process.events {
            try Task.checkCancellation()
            switch event {
            case .stdout(let data):
                guard bytes.count + data.count <= 1_048_576 else { throw PiHistoryGraphError(.oversized) }
                bytes.append(data)
            case .stderr: break
            case .exited(let code): status = code
            }
        }
        _ = await process.stopAndDrain(); deadline.cancel(); await deadline.value
    } catch {
        process.stop(); _ = await process.stopAndDrain(); deadline.cancel(); await deadline.value; throw error
    }
    #expect(status == 0)
    guard status == 0, !process.outputOverflowed else { throw CoincideError("The private Pi input bridge peer rejected the contract.") }
    return try JSONDecoder().decode(JSONValue.self, from: bytes)
}

@Test func piInputBridgeGeneratedExtensionClaimsPrivateReservationExpandsAdvertisedSymlinkSkillAndMatchesSwiftDigest() async throws {
    let value = try await runBridgeJavaScript(#"""
    const p = peer();
    p.hooks.get("session_start")({}, p.ctx);
    reserve(original);
    const transformed = p.hooks.get("input")(event, p.ctx);
    assert.equal(transformed.action, "transform");
    assert.equal(transformed.images, event.images);
    assert.equal((transformed.text.match(/SYNTHETIC SKILL BODY/g) ?? []).length, 1);
    assert.equal(transformed.text.includes("$unknown"), true);
    assert.equal(coincideInputFS.existsSync(sidecar), false);
    appendUser(p, transformed.text, transformed.images);
    console.log(JSON.stringify({ entries: p.entries, notices: p.notices, expandedText: transformed.text }));
    """#)
    let raw = try #require(value["entries"].array)
    let entries = try raw.map(PiHistoryEntry.init(raw:))
    let original = ProviderInput(text: "Use $review $review $unknown", images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))])
    let reservation = try bridgeReservation(original)
    let baseline = try bridgeObservation([entries[0]]), final = try bridgeObservation(entries)
    let proofs = try PiInputBridge.prove(reservations: [reservation], entries: entries, baseline: baseline, finalObservation: final)
    let expanded = try #require(value["expandedText"].string)
    #expect(proofs[0].expandedDigest == (try PiHistoryInputEvidence.digest(.init(text: expanded, images: original.images))))
    #expect(value["notices"].array?.first?["message"] == .string(PiInputBridge.readinessMessage(processEpoch: bridgeEpoch)))
}

@Test func piInputBridgeGeneratedExtensionHandlesNativeLaterExpansionAndRejectsUnownedInputWithoutEchoingContents() async throws {
    let value = try await runBridgeJavaScript(#"""
    const p = peer(); reserve(original);
    p.hooks.get("input")(event, p.ctx);
    // Native /skill and template expansion runs after the input hook. This
    // peer supplies its final result; the actual vendor algorithm is not run.
    appendUser(p, "NATIVE TEMPLATE RESULT / quotes \" and café\n\u2028\u2029");
    const foreign = peer(); reserve(original);
    foreign.hooks.get("input")(event, foreign.ctx);
    const rejected = foreign.hooks.get("input")({ ...event, source: "extension", text: "PRIVATE UNOWNED BODY" }, foreign.ctx);
    assert.deepEqual(rejected, { action: "handled" });
    assert.deepEqual(foreign.hooks.get("input")(event, foreign.ctx), { action: "handled" });
    appendUser(foreign, "PRIVATE UNOWNED BODY");
    assert.equal(foreign.entries.length, 2);
    assert.equal(foreign.notices.length, 1);
    assert.equal(JSON.stringify(foreign.notices).includes("PRIVATE"), false);
    console.log(JSON.stringify({ entries: p.entries, foreignNotices: foreign.notices }));
    """#)
    let entries = try #require(value["entries"].array).map(PiHistoryEntry.init(raw:))
    let original = ProviderInput(text: "Use $review $review $unknown", images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))])
    let reservation = try bridgeReservation(original)
    let proofs = try PiInputBridge.prove(reservations: [reservation], entries: entries,
        baseline: bridgeObservation([entries[0]]), finalObservation: bridgeObservation(entries))
    #expect(proofs.count == 1)
    #expect(value["foreignNotices"].array?.first?["message"] == .string(PiInputBridge.failureMessage(processEpoch: bridgeEpoch)))
}

@Test func piInputBridgeGeneratedExtensionDeduplicatesLeadingNativeSkillAndLeavesLaterTemplateExpansionToPi() async throws {
    let value = try await runBridgeJavaScript(#"""
    const skill = peer(); reserve(nativeSkillReservation);
    const nativeInput = { ...event, text: "/skill:review args $review" };
    const nativeResult = skill.hooks.get("input")(nativeInput, skill.ctx);
    assert.equal(nativeResult, undefined); // The leading native skill owns it.
    appendUser(skill, "NATIVE LEADING SKILL EXPANSION");
    const template = peer(); reserve(templateReservation);
    const templateInput = { ...event, text: "/template $review" };
    const templateResult = template.hooks.get("input")(templateInput, template.ctx);
    assert.equal(templateResult.action, "transform");
    assert.equal(templateResult.text.startsWith("/template $review"), true);
    appendUser(template, "NATIVE TEMPLATE EXPANSION AFTER INLINE SKILL");
    console.log(JSON.stringify({ skillEntries: skill.entries, templateEntries: template.entries }));
    """#)
    for (key, text) in [("skillEntries", "/skill:review args $review"), ("templateEntries", "/template $review")] {
        let raw = try #require(value[key].array)
        let entries = try raw.map(PiHistoryEntry.init(raw:))
        let reservation = try bridgeReservation(.init(text: text, images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))]))
        let proofs = try PiInputBridge.prove(reservations: [reservation], entries: entries,
            baseline: bridgeObservation([entries[0]]), finalObservation: bridgeObservation(entries))
        #expect(proofs.count == 1 && proofs[0].marker.reservation == reservation)
    }
}

@Test(arguments: ["idle", "busy", "queued", "wrong-nonce", "associated"])
func piInputBridgeGeneratedExtensionRetiresOnlyExactClaimAfterNativeQuietProof(state: String) async throws {
    let quiet = state == "idle"
    let quoted = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    let body = #"""
    const state = STATE, p = peer(); reserve(original);
    p.hooks.get("input")(event, p.ctx); // A later input hook handles it: no user.
    const next = { ...original, nonce: "44444444-4444-4444-8444-444444444444", retirementNonce: original.nonce };
    if (state === "wrong-nonce") next.retirementNonce = "66666666-6666-4666-8666-666666666666";
    if (state === "associated") p.hooks.get("message_start")({ message: { role: "user", content: [] } }, p.ctx);
    p.setIdle(state !== "busy"); p.setPending(state === "queued");
    reserve(next);
    p.hooks.get("input")(event, p.ctx);
    const claimed = !coincideInputFS.existsSync(sidecar);
    if (state === "idle") appendUser(p, "after explicit quiet retirement");
    console.log(JSON.stringify({ claimed, entries: p.entries, notices: p.notices }));
    """#.replacingOccurrences(of: "STATE", with: quoted)
    let value = try await runBridgeJavaScript(body)
    #expect(value["claimed"] == .bool(quiet))
    if quiet {
        let entries = try #require(value["entries"].array).map(PiHistoryEntry.init(raw:))
        let marker = try PiInputBridgeMarker(entry: entries[1])
        #expect(marker.reservation.nonce == bridgeSecondNonce && marker.reservation.retirementNonce == bridgeNonce)
    } else { #expect(value["notices"].array?.count == 1 && value["entries"].array?.count == 1) }
}

@Test(arguments: ["mode", "symlink", "replay", "fifo"]) func piInputBridgeGeneratedExtensionRefusesUnsafeOrReplayedReservation(kind: String) async throws {
    let quoted = String(decoding: try JSONEncoder().encode(kind), as: UTF8.self)
    let body = #"""
    const kind = KIND, p = peer();
    if (kind === "fifo") { /* Created by the test before the peer starts. */ }
    else if (kind === "mode") {
      reserve(original, 0o644);
      assert.equal(coincideInputFS.lstatSync(sidecar).mode & 0o777, 0o644);
    }
    else if (kind === "symlink") {
      const target = coincideInputPath.join(root, "foreign.json");
      coincideInputFS.writeFileSync(target, JSON.stringify(original), { mode: 0o600 });
      coincideInputFS.symlinkSync(target, sidecar);
    } else {
      reserve(original); p.hooks.get("input")(event, p.ctx); appendUser(p, "first owned input"); reserve(original);
    }
    assert.deepEqual(p.hooks.get("input")(event, p.ctx), { action: "handled" });
    assert.deepEqual(p.hooks.get("input")(event, p.ctx), { action: "handled" });
    assert.equal(coincideInputFS.existsSync(sidecar), true);
    assert.equal(p.notices.length, 1);
    console.log(JSON.stringify({ notices: p.notices, preserved: true }));
    """#.replacingOccurrences(of: "KIND", with: quoted)
    let value = try await runBridgeJavaScript(body, fifoReservation: kind == "fifo")
    #expect(value["preserved"] == .bool(true))
    #expect(value["notices"].array?.first?["message"] == .string(PiInputBridge.failureMessage(processEpoch: bridgeEpoch)))
}

@Test(arguments: ["missing", "oversized", "invalid-utf8", "duplicate", "casefold", "disabled", "agent-only"])
func piInputBridgeSelectedSkillFailureStopsAdmissionWithoutProvingUnexpandedInput(kind: String) async throws {
    let quoted = String(decoding: try JSONEncoder().encode(kind), as: UTF8.self)
    let body = #"""
    const kind = KIND, p = peer();
    const file = coincideInputPath.join(root, "review.md"), advertised = coincideInputPath.join(root, "review-link.md");
    if (kind === "missing") coincideInputFS.unlinkSync(file);
    else if (kind === "oversized") coincideInputFS.writeFileSync(file, Buffer.alloc(4194305, 65));
    else if (kind === "invalid-utf8") coincideInputFS.writeFileSync(file, Buffer.from([0xc3, 0x28]));
    else if (kind === "disabled" || kind === "agent-only") p.setCommands([
      { name: "skill:review", source: "skill", sourceInfo: { path: advertised },
        ...(kind === "disabled" ? { enabled: false } : { userInvocable: false }) },
    ]);
    else p.setCommands([
      { name: "skill:review", source: "skill", sourceInfo: { path: advertised } },
      { name: kind === "duplicate" ? "skill:review" : "skill:REVIEW", source: "skill", sourceInfo: { path: advertised } },
    ]);
    reserve(original);
    const response = p.hooks.get("input")(event, p.ctx);
    assert.equal(response.action, "handled");
    assert.equal(p.entries.length, 1);
    assert.equal(p.notices.length, 1);
    assert.equal(JSON.stringify(p.notices).includes("review"), false);
    console.log(JSON.stringify({ handled: true, notices: p.notices }));
    """#.replacingOccurrences(of: "KIND", with: quoted)
    let value = try await runBridgeJavaScript(body)
    #expect(value["handled"] == .bool(true))
    #expect(value["notices"].array?.first?["message"] == .string(PiInputBridge.failureMessage(processEpoch: bridgeEpoch)))
}
