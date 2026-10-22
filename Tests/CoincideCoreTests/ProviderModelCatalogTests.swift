import Foundation
import Testing
@testable import CoincideCore

struct CatalogPeer {
    let root: URL
    let wire: URL
    let session: CodexSession

    init(_ options: [String: JSONValue]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-catalog-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = root.appendingPathComponent("options.json")
        try JSONEncoder().encode(JSONValue.object(options)).write(to: config, options: .atomic)
        wire = root.appendingPathComponent("wire.jsonl")
        let fixture = try #require(Bundle.module.url(forResource: "codex_catalog", withExtension: "py", subdirectory: "Fixtures"))
        session = try CodexSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: root,
                                   arguments: [fixture.path, config.path, wire.path])
    }

    func frames() throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: wire.path) else { return [] }
        return try Data(contentsOf: wire).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
}

func withCatalogPeer(_ options: [String: JSONValue], _ body: (CatalogPeer) async throws -> Void) async throws {
    let peer = try CatalogPeer(options)
    do {
        try await body(peer)
        await peer.session.close(); try FileManager.default.removeItem(at: peer.root)
    } catch {
        await peer.session.close(); try? FileManager.default.removeItem(at: peer.root); throw error
    }
}

private func catalogModel(_ wireID: String = "wire-model", catalogID: String = "catalog-model") -> JSONValue {
    .object(["id": .string(catalogID), "model": .string(wireID), "displayName": .string("Advertised model 日本語"),
             "supportedReasoningEfforts": .array([
                .object(["reasoningEffort": .string("medium"), "description": .string("Balanced work")]),
                .object(["reasoningEffort": .string("future-super-effort"), "description": .string("Future advertised depth 😀")])]),
             "defaultReasoningEffort": .string("future-super-effort"), "isDefault": .bool(true), "hidden": .bool(false)])
}

private func catalogError(_ body: () async throws -> Void) async throws {
    do { try await body(); Issue.record("The unsafe catalog response was accepted.") }
    catch is CancellationError { throw CoincideError("A malformed catalog was misclassified as caller cancellation.") }
    catch {
        #expect(error.localizedDescription == CodexModelCatalogEntry.failureMessage)
        #expect(!error.localizedDescription.contains("synthetic-private-token"))
    }
}

private func catalogEventually(_ predicate: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The offline catalog fixture did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test func providerModelCatalogTypesRoundTripAdvertisedValuesAndDecodeLegacyDefaults() throws {
    let legacy = Data(#"{"id":"legacy-wire","name":"Legacy model"}"#.utf8)
    #expect(try JSONDecoder().decode(ProviderModel.self, from: legacy) == .init(id: "legacy-wire", name: "Legacy model"))
    let model = ProviderModel(id: "wire", name: "Future model", reasoningEfforts: [.init(id: "new-effort", description: "An advertised choice")],
                              defaultReasoningEffort: "new-effort", isDefault: true, catalogID: "catalog")
    #expect(try JSONDecoder().decode(ProviderModel.self, from: JSONEncoder().encode(model)) == model)
}

@Test(.timeLimit(.minutes(1)))
func codexModelCatalogPreservesWireIdentityDynamicEffortsAndLegacyMissingMetadata() async throws {
    let response: JSONValue = .object(["data": .array([catalogModel(), .object(["id": .string("legacy-only-id")]),
        .object(["model": .string("legacy-wire-only"), "supportedReasoningEfforts": .null,
                 "defaultReasoningEffort": .null, "isDefault": .null, "hidden": .null])])])
    try await withCatalogPeer(["pages": .object(["": response])]) { peer in
        let models = try await peer.session.models(), model = try #require(models.first)
        #expect(models.map(\.id) == ["wire-model", "legacy-only-id", "legacy-wire-only"])
        #expect(model.catalogID == "catalog-model" && model.name == "Advertised model 日本語")
        #expect(model.reasoningEfforts.map(\.id) == ["medium", "future-super-effort"])
        #expect(model.reasoningEfforts.last?.description == "Future advertised depth 😀")
        #expect(model.defaultReasoningEffort == "future-super-effort" && model.isDefault)
        #expect(models[1] == .init(id: "legacy-only-id", name: "legacy-only-id", catalogID: "legacy-only-id"))
        #expect(models[2] == .init(id: "legacy-wire-only", name: "legacy-wire-only"))
        let requests = try peer.frames().filter { $0["method"] == .string("model/list") }
        #expect(requests.count == 1 && requests[0]["params"]["limit"] == .number(100))
        #expect(requests[0]["params"]["includeHidden"] == .bool(false))
        #expect(try peer.frames().allSatisfy { ["initialize", "initialized", "model/list"].contains($0["method"].string ?? "") })
    }
}

@Test(.timeLimit(.minutes(1)))
func codexModelCatalogPaginatesAndDeduplicatesIdenticalRowsWhileKeepingHiddenRowsOutOfPicker() async throws {
    let first = catalogModel(), second = catalogModel("second-wire", catalogID: "second-catalog")
    var hidden = try #require(catalogModel("hidden-wire", catalogID: "hidden-catalog").object)
    hidden["hidden"] = .bool(true)
    let pages: JSONValue = .object([
        "": .object(["data": .array([first, .object(hidden)]), "nextCursor": .string("opaque-cursor")]),
        "opaque-cursor": .object(["data": .array([first, second]), "nextCursor": .null])])
    try await withCatalogPeer(["pages": pages]) { peer in
        let models = try await peer.session.models()
        #expect(models.map(\.id) == ["wire-model", "second-wire"])
        let requests = try peer.frames().filter { $0["method"] == .string("model/list") }
        #expect(requests.count == 2 && requests[0]["params"]["cursor"] == .null)
        #expect(requests[1]["params"]["cursor"] == .string("opaque-cursor"))
        #expect(requests.allSatisfy { $0["params"]["includeHidden"] == .bool(false) })
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["wire", "catalog", "effort"])
func codexModelCatalogRejectsConflictingDuplicateIdentities(kind: String) async throws {
    let first = catalogModel()
    var duplicate = try #require(first.object)
    if kind == "wire" { duplicate["displayName"] = .string("Conflicting name") }
    if kind == "catalog" { duplicate["model"] = .string("another-wire-model") }
    if kind == "effort" {
        duplicate["supportedReasoningEfforts"] = .array([
            .object(["reasoningEffort": .string("medium"), "description": .string("One description")]),
            .object(["reasoningEffort": .string("medium"), "description": .string("A conflicting description")])])
    }
    try await withCatalogPeer(["pages": .object(["": .object(["data": .array([first, .object(duplicate)])])])]) { peer in
        try await catalogError { _ = try await peer.session.models() }
    }
}

@Test(.timeLimit(.minutes(1)))
func codexModelCatalogRejectsCursorCyclesBeforeAnotherRequest() async throws {
    let pages: JSONValue = .object([
        "": .object(["data": .array([]), "nextCursor": .string("cycle")]),
        "cycle": .object(["data": .array([]), "nextCursor": .string("cycle")])])
    try await withCatalogPeer(["pages": pages]) { peer in
        try await catalogError { _ = try await peer.session.models() }
        #expect(try peer.frames().filter { $0["method"] == .string("model/list") }.count == 2)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["page", "rows", "bytes", "efforts"])
func codexModelCatalogEnforcesFiniteDiscoveryBudgets(kind: String) async throws {
    var options: [String: JSONValue] = [:]
    if kind == "page" { options["infinitePages"] = .bool(true) }
    if kind == "rows" { options["rowOverflow"] = .bool(true) }
    if kind == "bytes" { options["byteOverflow"] = .bool(true) }
    if kind == "efforts" {
        var item = try #require(catalogModel().object)
        item["supportedReasoningEfforts"] = .array((0..<65).map { .object(["reasoningEffort": .string("effort-\($0)"), "description": .string("Choice")]) })
        options["pages"] = .object(["": .object(["data": .array([.object(item)])])])
    }
    try await withCatalogPeer(options) { peer in
        try await catalogError { _ = try await peer.session.models() }
        let count = try peer.frames().filter { $0["method"] == .string("model/list") }.count
        #expect(count == (kind == "page" ? 20 : 1))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["root", "data", "model", "id", "displayName", "hidden", "isDefault", "efforts", "effortID", "description", "defaultEffort", "cursor"])
func codexModelCatalogSanitizesMalformedSchemaInsteadOfReturningPartialDiscovery(kind: String) async throws {
    var item = try #require(catalogModel().object)
    switch kind {
    case "model", "id", "displayName", "hidden", "isDefault": item[kind] = .number(1)
    case "efforts": item["supportedReasoningEfforts"] = .string("synthetic-private-token")
    case "effortID": item["supportedReasoningEfforts"] = .array([.object(["reasoningEffort": .string("bad\nvalue"), "description": .string("Choice")])])
    case "description": item["supportedReasoningEfforts"] = .array([.object(["reasoningEffort": .string("medium"), "description": .number(1)])])
    case "defaultEffort": item["defaultReasoningEffort"] = .number(1)
    default: break
    }
    var response: JSONValue = .object(["data": .array([.object(item)])])
    if kind == "root" { response = .array([]) }
    if kind == "data" { response = .object(["data": .string("synthetic-private-token")]) }
    if kind == "cursor" { response = .object(["data": .array([]), "nextCursor": .string("")]) }
    try await withCatalogPeer(["pages": .object(["": response])]) { peer in
        try await catalogError { _ = try await peer.session.models() }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["initializeError", "listError"])
func codexModelCatalogSanitizesProviderErrorsWithoutExposingPrivateValues(mode: String) async throws {
    try await withCatalogPeer([mode: .bool(true)]) { peer in
        try await catalogError { _ = try await peer.session.models() }
    }
}

@Test(.timeLimit(.minutes(1)))
func codexModelCatalogCancellationDetachesTheReadAndAllowsFreshDiscovery() async throws {
    let gateRoot = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-catalog-gate-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: gateRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: gateRoot) }
    let entered = gateRoot.appendingPathComponent("entered"), release = gateRoot.appendingPathComponent("release")
    try await withCatalogPeer(["entered": .string(entered.path), "release": .string(release.path),
                              "pages": .object(["": .object(["data": .array([catalogModel()])])])]) { peer in
        let cancelled = Task { try await peer.session.models() }
        do {
            try await catalogEventually { FileManager.default.fileExists(atPath: entered.path) }
            cancelled.cancel()
            do { _ = try await cancelled.value; Issue.record("The cancelled catalog read returned models.") }
            catch is CancellationError {}
            try Data().write(to: release)
            let recovered = try await peer.session.models()
            #expect(recovered.map(\.id) == ["wire-model"])
            let frames = try peer.frames()
            #expect(frames.filter { $0["method"] == .string("initialize") }.count == 1)
            #expect(frames.filter { $0["method"] == .string("model/list") }.count == 2)
        } catch { try? Data().write(to: release); cancelled.cancel(); _ = try? await cancelled.value; throw error }
    }
}
