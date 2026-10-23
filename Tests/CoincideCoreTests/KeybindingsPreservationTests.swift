import Foundation
import Darwin
import Testing
@testable import CoincideCore

private func keybindingPreservationRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-keybinding-preservation-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}

@Test func keybindingsSurgicalEditPreservesUnknownEntriesUntouchedFieldsAndAllCommentBytes() async throws {
    let root = try keybindingPreservationRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("keybindings.json")
    let unknown = #"{"command":"future.command", "key":"mod+g", "nested":[{"text":"a,]//not a comment"},false,null]}"#
    let untouched = #"{ "key" : "mod+j", "command" : "terminal.toggle", "futureField" : "cafe\u0301" }"#
    let original = """
    // Original owner: cafe\u{301}; keep spelling and whitespace.
    [
      { /* inside replaced object */ "key": "mod+k", // key explanation
        "command": "commandPalette.toggle" },
      \(unknown), /* unknown entry explanation */
      \(untouched),
      7, // malformed entry is still someone's configuration
    ] /* final comment */
    """
    try Data(original.utf8).write(to: url)
    let store = KeybindingsConfigStore(fileURL: url, defaults: [], lateDefaults: [])
    let before = await store.load()
    let newRule = KeybindingRule(key: "mod+shift+k", command: .commandPaletteToggle)
    let saved = try await store.upsert(newRule, replacing: .init(key: "mod+k", command: .commandPaletteToggle), expectedRevision: before.revision)
    let bytes = try Data(contentsOf: url), text = String(decoding: bytes, as: UTF8.self)
    for literal in [unknown, untouched, "// Original owner: cafe\u{301}; keep spelling and whitespace.",
                    "/* inside replaced object */", "// key explanation", "/* unknown entry explanation */",
                    "// malformed entry is still someone's configuration", "/* final comment */"] {
        #expect(bytes.range(of: Data(literal.utf8)) != nil)
    }
    #expect(text.contains("7, // malformed entry"))
    #expect(saved.fileRules == [.init(key: "mod+j", command: .terminalToggle), newRule])
    #expect(saved.issues.count == 2 && saved.issues.allSatisfy { $0.kind == .invalidEntry })
    #expect(saved.revision != before.revision)
    let loaded = await store.load()
    #expect(loaded == saved)
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}

@Test(arguments: ["first", "middle", "last", "all"])
func keybindingsRemovingRulesPreservesCommentsAndAValidArrayAtEverySeparator(position: String) async throws {
    let root = try keybindingPreservationRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("keybindings.json")
    let original = """
    /* prefix */ [
      {"key":"mod+b",/* first */"command":"sidebar.toggle"}, // after first
      {"key":"mod+j",/* middle */"command":"terminal.toggle"}, // after middle
      {"key":"mod+k",/* last */"command":"commandPalette.toggle"} // after last
    ] // suffix
    """
    try Data(original.utf8).write(to: url)
    let store = KeybindingsConfigStore(fileURL: url, defaults: [], lateDefaults: [])
    let rules = [KeybindingRule(key: "mod+b", command: .sidebarToggle), .init(key: "mod+j", command: .terminalToggle),
                 .init(key: "mod+k", command: .commandPaletteToggle)]
    let indices = position == "all" ? [0, 1, 2] : [position == "first" ? 0 : position == "middle" ? 1 : 2]
    for index in indices {
        let current = await store.load()
        _ = try await store.remove(rules[index], expectedRevision: current.revision)
    }
    let final = await store.load(), bytes = try Data(contentsOf: url)
    #expect(final.issues.isEmpty && final.fileRules == rules.enumerated().filter { !indices.contains($0.offset) }.map(\.element))
    for comment in ["/* prefix */", "/* first */", "// after first", "/* middle */", "// after middle",
                    "/* last */", "// after last", "// suffix"] {
        #expect(bytes.range(of: Data(comment.utf8)) != nil)
    }
    if position == "all" {
        let appended = try await store.upsert(rules[0], expectedRevision: final.revision)
        #expect(appended.issues.isEmpty && appended.fileRules == [rules[0]])
    }
}

@Test(arguments: [false, true])
func keybindingsBackfillInsertsDefaultsWithoutRewritingJSONCOrEmptyArrayComments(empty: Bool) async throws {
    let root = try keybindingPreservationRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("keybindings.json")
    let custom = #"{ "key" : "mod+g", "command" : "terminal.toggle", "extra" : {"note":"//literal"} },"#
    let original = "// header\r\n[\r\n/* keep this comment */\r\n" + (empty ? "" : custom + "\r\n") + "]// tail\r\n"
    try Data(original.utf8).write(to: url)
    let sidebar = KeybindingRule(key: "mod+b", command: .sidebarToggle)
    let store = KeybindingsConfigStore(fileURL: url, defaults: [sidebar], lateDefaults: [])
    let result = await store.start(), first = try Data(contentsOf: url)
    #expect(result.issues.isEmpty && result.fileRules == [sidebar] + (empty ? [] : [.init(key: "mod+g", command: .terminalToggle)]))
    #expect(first.range(of: Data("// header\r\n[".utf8)) != nil)
    #expect(first.range(of: Data(("\r\n/* keep this comment */\r\n" + (empty ? "" : custom + "\r\n") + "]// tail\r\n").utf8)) != nil)
    _ = await store.start()
    #expect(try Data(contentsOf: url) == first)
}

@Test func keybindingsPreservedUnknownEntriesKeepTheirSlotsAtRuleLimitAndRefuseTotalCapacityWithoutLoss() async throws {
    let root = try keybindingPreservationRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("keybindings.json")
    let rules = (0..<KeybindingResolver.maxRules).map { KeybindingRule(key: "mod+j", command: .script("private-\($0)")) }
    let body = String(decoding: KeybindingsConfigStore.encode(rules), as: UTF8.self).dropFirst(2).dropLast(3)
    let unknown = #"{"future":"opaque","nested":[1,2,3]}"#
    try Data(("[" + unknown + ",\n" + body + "]\n").utf8).write(to: url)
    let store = KeybindingsConfigStore(fileURL: url, defaults: [], lateDefaults: [])
    let before = await store.load(), replacement = KeybindingRule(key: "mod+k", command: .commandPaletteToggle)
    let result = try await store.upsert(replacement, expectedRevision: before.revision)
    #expect(result.fileRules == Array(rules.dropFirst()) + [replacement] && result.issues.count == 1)
    #expect(try Data(contentsOf: url).range(of: Data(unknown.utf8)) != nil)
    let full = Data(("[" + Array(repeating: unknown, count: 4_096).joined(separator: ",") + "]").utf8)
    try full.write(to: url)
    let capacity = await store.load()
    await #expect(throws: (any Error).self) { try await store.upsert(replacement, expectedRevision: capacity.revision) }
    #expect(try Data(contentsOf: url) == full)
}

@Test func keybindingsCommentOnlyConcurrentEditStillRefusesStaleRevisionAndPreservesLatestUnknownBytes() async throws {
    let root = try keybindingPreservationRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("keybindings.json")
    let original = Data("[/* old */ {\"key\":\"mod+j\",\"command\":\"terminal.toggle\"}, 7]".utf8)
    try original.write(to: url)
    let first = KeybindingsConfigStore(fileURL: url, defaults: [], lateDefaults: [])
    let second = KeybindingsConfigStore(fileURL: url, defaults: [], lateDefaults: [])
    let stale = await first.load(), latest = Data("[/* new */ {\"key\":\"mod+j\",\"command\":\"terminal.toggle\"}, 7]".utf8)
    try latest.write(to: url, options: .atomic)
    let replacement = KeybindingRule(key: "mod+g", command: .terminalToggle)
    await #expect(throws: (any Error).self) {
        try await first.upsert(replacement, replacing: stale.fileRules[0], expectedRevision: stale.revision)
    }
    #expect(try Data(contentsOf: url) == latest)
    let refreshed = await second.load()
    let changed = try await second.upsert(replacement, replacing: refreshed.fileRules[0], expectedRevision: refreshed.revision)
    #expect(changed.fileRules == [replacement] && changed.issues.count == 1)
    #expect(try Data(contentsOf: url).range(of: Data("/* new */".utf8)) != nil)
}

@Test func keybindingsUnsupportedCommentShapeIsPreservedInsteadOfDestructivelyReformatted() async throws {
    let root = try keybindingPreservationRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("keybindings.json")
    // The legacy lenient decoder accepts an unfinished trailing comment. The
    // editing lexer refuses this ambiguous document, without a lossy fallback.
    let original = Data("[] /* unfinished user note".utf8)
    try original.write(to: url)
    let store = KeybindingsConfigStore(fileURL: url, defaults: [], lateDefaults: [])
    let current = await store.load()
    #expect(current.issues.isEmpty)
    await #expect(throws: (any Error).self) {
        try await store.upsert(.init(key: "mod+j", command: .terminalToggle), expectedRevision: current.revision)
    }
    #expect(try Data(contentsOf: url) == original)
}
