import Foundation
import Darwin
import Testing
@testable import CoincideCore

private func keybindingsRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-keybindings-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
private func writeConfig(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }
private func fileRules(_ url: URL) throws -> [KeybindingRule] { KeybindingsConfigStore.decode(try Data(contentsOf: url)).rules }

@Test func keybindingsFirstRunWritesDefaultsInReadableOrderAndLoadsThem() async throws {
    let root = try keybindingsRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("nested/keybindings.json")
    let store = KeybindingsConfigStore(fileURL: url)
    let state = await store.start()
    #expect(state.issues.isEmpty && state.keybindings == KeybindingDefaults.resolved && state.fileRules == KeybindingDefaults.rules)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.hasPrefix("[\n  { \"key\": \"mod+b\", \"command\": \"sidebar.toggle\" },\n"))
    #expect(text.contains("{ \"key\": \"mod+[\", \"command\": \"navigation.back\", \"when\": \"!terminalFocus\" }") && text.hasSuffix("}\n]\n"))
    #expect(try fileRules(url) == KeybindingDefaults.rules)
    let permissions = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
    #expect(permissions == 0o700)
    #expect(KeybindingsConfigStore.decode(KeybindingsConfigStore.encode([])).rules.isEmpty && String(decoding: KeybindingsConfigStore.encode([]), as: UTF8.self) == "[\n]\n")
}

@Test func keybindingsMalformedFilesUseDefaultsAndInvalidEntriesDoNotBlockOthers() async throws {
    let root = try keybindingsRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("keybindings.json")
    try writeConfig("{ \"key\": \"mod+g\" }", to: url)
    let malformed = await KeybindingsConfigStore(fileURL: url).load()
    #expect(malformed.keybindings == KeybindingDefaults.resolved && malformed.issues.map(\.kind) == [.malformedConfig])
    try writeConfig("""
    [
      // Comments and trailing commas are accepted, as in T3.
      { "key": "mod+g", "command": "terminal.toggle" },
      { "key": "mod+shift+g", "command": "terminal.new", "when": "terminalFocus", },
      { "key": "mod+h", "command": "not.a.command" },
      { "key": "mod+a+b", "command": "thread.pin" },
      { "key": "mod+e", "command": "thread.pin", "when": "a &&" },
      "mod+q",
      { "key": "mod+l", "command": "script.test.run", "extra": 1 }, /* trailing */
    ]
    """, to: url)
    let state = await KeybindingsConfigStore(fileURL: url).load()
    #expect(state.issues.map(\.index) == [2, 3, 4, 5] && state.issues.allSatisfy { $0.kind == .invalidEntry })
    #expect(state.issues[0].summary == "Entry 3: Unknown command “not.a.command”.")
    #expect(state.fileRules.map(\.command) == [.terminalToggle, .terminalNew, .script("test")])
    #expect(!state.keybindings.contains { $0.command == .terminalToggle && $0.shortcut.key == "j" })
    #expect(state.keybindings.contains { $0.command == .threadPin && $0.shortcut.key == "p" })
    #expect(KeybindingsConfigStore.stripLenientJSON("[\"a,]//b\", /*c*/ 1,\n]") == "[\"a,]//b\",   1\n]")
}

@Test func keybindingsStartupBackfillAddsMissingCommandsBeforeUserRulesAndSkipsConflicts() async throws {
    let root = try keybindingsRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("keybindings.json")
    let defaults: [KeybindingRule] = [.init(key: "mod+b", command: .sidebarToggle), .init(key: "mod+k", command: .commandPaletteToggle, when: "!terminalFocus"),
                                      .init(key: "mod+j", command: .terminalToggle)]
    try writeConfig("[{ \"key\": \"mod+k\", \"command\": \"thread.pin\", \"when\": \"!terminalFocus\" }, { \"key\": \"mod+g\", \"command\": \"terminal.toggle\" }]", to: url)
    let store = KeybindingsConfigStore(fileURL: url, defaults: defaults)
    let state = await store.start()
    // Sidebar was missing and is added first; the palette default collides with the user's ⌘K rule.
    #expect(try fileRules(url) == [defaults[0], .init(key: "mod+k", command: .threadPin, when: "!terminalFocus"), .init(key: "mod+g", command: .terminalToggle)])
    let warnings = await store.warnings
    #expect(state.issues.isEmpty && warnings.contains { $0.contains("commandPalette.toggle") })
    // A deleted default returns only through a later backfill of a missing command, never by replacing customizations.
    _ = try await store.remove(defaults[0])
    #expect(try fileRules(url).count == 2)
    _ = await store.start()
    #expect(try fileRules(url).first == defaults[0])
    // Backfill never rewrites a file with issues.
    try writeConfig("[{ \"key\": \"mod+g\", \"command\": \"terminal.toggle\" }, 5]", to: url)
    let held = await store.start()
    let heldRules = try fileRules(url), heldWarnings = await store.warnings
    #expect(held.issues.count == 1 && heldRules == [.init(key: "mod+g", command: .terminalToggle)])
    #expect(heldWarnings.contains { $0.contains("has issues") })
}

@Test func keybindingsLateDefaultsApplyOnceBesideTheirCompanionRule() async throws {
    let root = try keybindingsRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("keybindings.json")
    let alongside = KeybindingRule(key: "mod+alt+enter", command: .init("composer.sendBackground"), when: "composerFocus")
    let late = KeybindingDefaults.LateDefault(id: "composer.sendBackground:mod+enter", alongside: alongside,
                                              rule: .init(key: "mod+enter", command: .init("composer.sendBackground"), when: "composerFocus"))
    try writeConfig("[{ \"key\": \"mod+alt+enter\", \"command\": \"composer.sendBackground\", \"when\": \"composerFocus\" }]", to: url)
    let store = KeybindingsConfigStore(fileURL: url, defaults: [alongside], lateDefaults: [late])
    _ = await store.start()
    #expect(try fileRules(url) == [late.rule, alongside])
    #expect(try String(contentsOf: store.migrationsURL, encoding: .utf8) == late.id + "\n")
    _ = try await store.remove(late.rule)
    _ = await store.start()
    #expect(try fileRules(url) == [alongside])
    // A fresh install records the migration without adding the late rule twice.
    let fresh = root.appendingPathComponent("fresh/keybindings.json")
    let freshStore = KeybindingsConfigStore(fileURL: fresh, defaults: [alongside], lateDefaults: [late])
    _ = await freshStore.start()
    #expect(try fileRules(fresh) == [alongside] && FileManager.default.fileExists(atPath: freshStore.migrationsURL.path))
}

@Test func keybindingsUpsertReplaceAndRemoveWriteAtomicallyAndKeepOrder() async throws {
    let root = try keybindingsRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("keybindings.json")
    try writeConfig("[{ \"key\": \"Mod+K\", \"command\": \"commandPalette.toggle\" }, { \"key\": \"mod+j\", \"command\": \"terminal.toggle\" }, 7]", to: url)
    let store = KeybindingsConfigStore(fileURL: url, defaults: [])
    let replaced = try await store.upsert(.init(key: "mod+shift+k", command: .commandPaletteToggle), replacing: .init(key: "mod+k", command: .commandPaletteToggle))
    #expect(try fileRules(url) == [.init(key: "mod+j", command: .terminalToggle), .init(key: "mod+shift+k", command: .commandPaletteToggle)])
    #expect(replaced.issues.map(\.kind) == [.invalidEntry] && KeybindingResolver.shortcut(for: .commandPaletteToggle, in: replaced.keybindings)?.label == "⇧⌘K")
    _ = try await store.upsert(.init(key: "mod+j", command: .terminalToggle))
    #expect(try fileRules(url).map(\.key) == ["mod+shift+k", "mod+j"])
    let removed = try await store.remove(.init(key: "MOD+J", command: .terminalToggle))
    #expect(try fileRules(url) == [.init(key: "mod+shift+k", command: .commandPaletteToggle)] && removed.fileRules.count == 1)
    await #expect(throws: (any Error).self) { try await store.upsert(.init(key: "mod+a+b", command: .threadPin)) }
    await #expect(throws: (any Error).self) { try await store.upsert(.init(key: "mod+a", command: .init("nope.nope"))) }
    try writeConfig("not json", to: url)
    await #expect(throws: (any Error).self) { try await store.upsert(.init(key: "mod+a", command: .threadPin)) }
    #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0 != "keybindings.json" }
    #expect(leftovers == [".keybindings.lock"], "The persistent private lock prevents cross-instance lost writes; atomic scratch files must be removed.")
}

private actor KeybindingsEventCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@Test(.timeLimit(.minutes(1))) func keybindingsWatcherSeesInPlaceWritesAndAtomicRenames() async throws {
    let root = try keybindingsRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("keybindings.json")
    try writeConfig("[]", to: url)
    let watcher = KeybindingsFileWatcher(fileURL: url, debounce: .milliseconds(20))
    let counter = KeybindingsEventCounter()
    let consumer = Task { for await _ in watcher.events { await counter.increment() } }
    defer { watcher.stop(); consumer.cancel() }
    func waitFor(_ expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await counter.count < expected {
            guard ContinuousClock.now < deadline else { throw CoincideError("The keybindings watcher missed change \(expected).") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    try await Task.sleep(for: .milliseconds(50))
    // In-place write (the same inode).
    let handle = try FileHandle(forWritingTo: url); try handle.write(contentsOf: Data("[ ]\n".utf8)); try handle.close()
    try await waitFor(1)
    // Atomic replacement by rename, as many editors save.
    try Data("[{ \"key\": \"mod+g\", \"command\": \"terminal.toggle\" }]".utf8).write(to: url, options: .atomic)
    try await waitFor(2)
    // A second atomic save is still observed after the original file was replaced.
    try Data("[{ \"key\": \"mod+h\", \"command\": \"terminal.toggle\" }]".utf8).write(to: url, options: .atomic)
    try await waitFor(3)
    // Unrelated files in the same folder do not report a keybindings change.
    try Data("x".utf8).write(to: root.appendingPathComponent("workspace.sqlite-wal"))
    try await Task.sleep(for: .milliseconds(250))
    #expect(await counter.count == 3)
}

@Test func keybindingsExactRevisionRefusesStaleSettingsAcrossInstancesAndAbsentFileCreation() async throws {
    let root = try keybindingsRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("keybindings.json")
    let first = KeybindingsConfigStore(fileURL: url, defaults: []), second = KeybindingsConfigStore(fileURL: url, defaults: [])
    let absent = await first.load()
    #expect(absent.revision.digest == nil)
    let original = KeybindingRule(key: "mod+é", command: .threadPin)
    let saved = try await second.upsert(original, expectedRevision: absent.revision)
    #expect(saved.revision.digest?.count == 64)
    await #expect(throws: (any Error).self) {
        try await first.upsert(.init(key: "mod+j", command: .terminalToggle), expectedRevision: absent.revision)
    }
    let decomposed = KeybindingRule(key: "mod+e\u{301}", command: .threadPin)
    try KeybindingsConfigStore.encode([decomposed]).write(to: url, options: .atomic)
    #expect(original == decomposed, "Swift's string equivalence must not replace an exact file revision.")
    let before = try Data(contentsOf: url)
    await #expect(throws: (any Error).self) { try await first.remove(original, expectedRevision: saved.revision) }
    #expect(try Data(contentsOf: url) == before)
    let refreshed = await first.load()
    let removed = try await first.remove(decomposed, expectedRevision: refreshed.revision)
    #expect(removed.fileRules.isEmpty && removed.revision != refreshed.revision)
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}

@Test(arguments: ["file-symlink", "directory-symlink", "hard-link", "fifo"])
func keybindingsStorageRefusesForeignOrNonregularTargetsWithoutChangingTheirBytes(kind: String) async throws {
    let root = try keybindingsRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let sentinel = outside.appendingPathComponent("keybindings.json"), original = Data("[]\n".utf8)
    try original.write(to: sentinel)
    let directory = root.appendingPathComponent("settings", isDirectory: true)
    let url = directory.appendingPathComponent("keybindings.json")
    if kind == "directory-symlink" { try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside) }
    else {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch kind {
        case "file-symlink": try FileManager.default.createSymbolicLink(at: url, withDestinationURL: sentinel)
        case "hard-link": try FileManager.default.linkItem(at: sentinel, to: url)
        default: #expect(mkfifo(url.path, 0o600) == 0)
        }
    }
    let store = KeybindingsConfigStore(fileURL: url)
    let state = await store.start()
    #expect(state.issues.contains { $0.kind == .malformedConfig })
    await #expect(throws: (any Error).self) { try await store.upsert(.init(key: "mod+g", command: .terminalToggle)) }
    #expect(try Data(contentsOf: sentinel) == original)
    if kind == "fifo" {
        var info = stat(); #expect(lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFIFO)
    }
}

@Test func keybindingsRejectOversizedDeepOrInvalidUTF8WithoutRewritingTheConfiguration() async throws {
    let root = try keybindingsRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("keybindings.json"), store = KeybindingsConfigStore(fileURL: root.appendingPathComponent("keybindings.json"))
    let deep = "[" + String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40) + "]"
    for bytes in [Data(repeating: 32, count: KeybindingsConfigStore.maximumFileBytes + 1), Data(deep.utf8), Data([0xff, 0xfe, 0x5b, 0x5d])] {
        try bytes.write(to: url)
        let state = await store.start()
        #expect(state.keybindings == KeybindingDefaults.resolved && state.issues.contains { $0.kind == .malformedConfig })
        await #expect(throws: (any Error).self) { try await store.remove(.init(key: "mod+j", command: .terminalToggle)) }
        #expect(try Data(contentsOf: url) == bytes)
    }
}
