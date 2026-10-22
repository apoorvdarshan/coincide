import Foundation
import Testing
@testable import CoincideCore

/// The golden observations come from the hash-pinned original Pi implementation
/// running against synthetic files. Neither Node nor Pi runs in this Swift test.
@Test func piHistoryMatchesOriginalSourceBranchContextReloadAndExclusiveUserCuts() throws {
    let file = try #require(Bundle.module.url(forResource: "pi_history_original_0_80_5", withExtension: "json", subdirectory: "Fixtures"))
    let oracle = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
    #expect(oracle["schema"] == .number(1))
    #expect(oracle["providerVersion"] == .string("0.80.5"))
    for key in ["fullPackageImported", "installedProviderInvoked", "nativeMutationTested", "originalAlgorithmsRewritten"] {
        #expect(oracle["scope"][key] == .bool(false))
    }
    #expect(oracle["scope"]["stableWorkspaceSubstitution"] == .bool(true))
    let modules = try #require(oracle["modules"].array)
    #expect(modules.count == 2)
    #expect(modules.first?["sha256"] == .string("b135a1d19a70cc840658c995539dbcc01fc4eaa3ca6f0ff1df1cbf2c7fbe3cdd"))
    #expect(modules.last?["sha256"] == .string("8229aedb49e0cf12ebb9ed72670e24770c23e4d3ea814fe6f4e91cabe0288745"))
    for category in ["subprocess", "network", "filesystem", "configuration", "identityCreation"] {
        #expect(oracle["guards"][category] == .number(0))
        let probes = try #require(oracle["guardSelfTests"][category].piOracleNumber)
        #expect(probes > 0)
    }
    #expect(oracle["allowedOperations"]["opens"] == oracle["allowedOperations"]["closes"])
    let cases = try #require(oracle["cases"].array)
    #expect(cases.count == 11)
    var transitionCount = 0, cutCount = 0
    for item in cases {
        let name = try #require(item["name"].string)
        let entries = try #require(item["entries"].array)
        let graph = try PiHistoryGraph(header: item["header"], entries: entries, leafID: item["runtimeLeafID"].string)
        try expectPiOracleProjection(graph, item["expectedRuntime"], name: name)
        #expect(graph.header.raw == item["header"] && graph.entries.map(\.raw) == entries, "Raw native envelopes: \(name)")
        #expect(graph.leafOrigin == .runtime)

        var bytes = Data()
        for row in [item["header"]] + entries { bytes.append(try JSONEncoder().encode(row)); bytes.append(10) }
        let reloaded = try PiHistoryGraph.parse(bytes)
        try expectPiOracleProjection(reloaded, item["expectedReload"], name: name)
        #expect(reloaded.leafOrigin == .reloadedFile)
        #expect(reloaded.entries.map(\.raw) == entries && reloaded.inventoryDigest == graph.inventoryDigest)
        for transition in try #require(item["branchResetTransitions"].array) {
            let leaf = transition["entryID"].string
            #expect(transition["action"] == .string(leaf == nil ? "resetLeaf" : "branch"))
            let moved = try PiHistoryGraph(header: item["header"], entries: entries, leafID: leaf)
            #expect(moved.leafID == transition["leafID"].string, "Original live leaf: \(name)")
            #expect(moved.activeBranch.map(\.id) == (try piOracleIDs(transition["branchEntryIDs"])), "Original branch: \(name)")
            #expect(moved.contextEntries.map(\.id) == (try piOracleIDs(transition["contextEntryIDs"])), "Original context: \(name)")
            #expect(moved.contextMessageEntries.map(\.id) == (try piOracleIDs(transition["contextMessageEntryIDs"])), "Original message classification: \(name)")
            #expect(moved.entries.map(\.raw) == entries && moved.inventoryDigest == graph.inventoryDigest)
            transitionCount += 1
        }
        for cut in try #require(item["cuts"].array) {
            let userID = try #require(cut["beforeUserEntryID"].string)
            let retained = try graph.retainedPrefix(beforeUserEntryID: userID)
            #expect(retained.map(\.id) == (try piOracleIDs(cut["retainedEntryIDs"])), "Original exclusive user cut: \(name)")
            #expect(retained.allSatisfy { graph.entry(id: $0.id)?.raw == $0.raw })
            cutCount += 1
        }
    }
    #expect(transitionCount == 41 && cutCount == 13)
}

private func expectPiOracleProjection(_ graph: PiHistoryGraph, _ expected: JSONValue, name: String) throws {
    #expect(graph.header.sessionID == expected["sessionID"].string, "Original session identity: \(name)")
    #expect(graph.leafID == expected["leafID"].string, "Original leaf: \(name)")
    #expect(graph.entries.map(\.id) == (try piOracleIDs(expected["inventoryEntryIDs"])), "Original append inventory: \(name)")
    #expect(graph.activeBranch.map(\.id) == (try piOracleIDs(expected["branchEntryIDs"])), "Original active branch: \(name)")
    #expect(graph.contextEntries.map(\.id) == (try piOracleIDs(expected["contextEntryIDs"])), "Original compaction context: \(name)")
    #expect(graph.contextMessageEntries.map(\.id) == (try piOracleIDs(expected["contextMessageEntryIDs"])), "Original message classification: \(name)")
}

private func piOracleIDs(_ raw: JSONValue) throws -> [String] {
    try #require(raw.array).map { try #require($0.string) }
}

private extension JSONValue {
    var piOracleNumber: Double? { if case .number(let value) = self { value } else { nil } }
}
