import Darwin
import Foundation
import Testing
@testable import CoincideCore

private func projectSettingsFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-project-settings-owner-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let physical = try #require(realpath(root.path, nil))
    defer { free(physical) }
    return URL(fileURLWithPath: String(cString: physical), isDirectory: true)
}

@Test func projectSettingsRootResolvesSystemAliasesBeforeAnchoringAbsentDirectories() throws {
    let base = try projectSettingsFixture(); defer { try? FileManager.default.removeItem(at: base) }
    let alias = FileManager.default.temporaryDirectory.appendingPathComponent(base.lastPathComponent)
    let root = ProjectSettingsFiles.root(dataRoot: alias.appendingPathComponent("not-created/nested"))
    #expect(Data(root.path.utf8) == Data(base.appendingPathComponent("not-created/nested/ProjectSettings").path.utf8))
    let document = ProjectSettingsDocument(key: "checkout:alias", icon: .emoji("🌍"))
    #expect(try ProjectSettingsFiles.load(root: root, key: document.key) == nil)
    try ProjectSettingsFiles.save(document, root: root)
    #expect(try ProjectSettingsFiles.load(root: root, key: document.key) == document)
    let moved = base.appendingPathComponent("Moved")
    try FileManager.default.moveItem(at: root, to: moved)
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: moved)
    #expect(throws: CoincideError.self) { try ProjectSettingsFiles.load(root: root, key: document.key) }
}
private func writePrivateSettings(_ bytes: Data, to url: URL) throws {
    try bytes.write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

@Test func projectSettingsCASRejectsDifferentBytesAndReplacedStorageEvenWithEqualDecodedValues() throws {
    let base = try projectSettingsFixture(); defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Settings"), key = "checkout:exact"
    let original = ProjectSettingsDocument(key: key, icon: .emoji("🌍"))
    try ProjectSettingsFiles.save(original, root: root)
    let capture = try ProjectSettingsFiles.capture(root: root, keys: [key])
    let url = ProjectSettingsFiles.fileURL(root: root, key: key)
    var rewritten = try Data(contentsOf: url); rewritten.append(0x0a)
    try writePrivateSettings(rewritten, to: url)
    #expect(try ProjectSettingsFiles.load(root: root, key: key) == original)
    #expect(throws: CoincideError.self) {
        try ProjectSettingsFiles.save(.init(key: key, icon: .emoji("🚀")), root: root, expectedRevision: capture.revisions[0])
    }
    #expect(try Data(contentsOf: url) == rewritten)
    let latest = try ProjectSettingsFiles.capture(root: root, keys: [key])
    let moved = base.appendingPathComponent("Moved")
    try FileManager.default.moveItem(at: root, to: moved)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try writePrivateSettings(rewritten, to: url)
    #expect(throws: CoincideError.self) {
        try ProjectSettingsFiles.update(root: root, keys: [key], expectedCapture: latest) { $0.icon = .emoji("🚀") }
    }
    #expect(try Data(contentsOf: url) == rewritten)
    #expect(try Data(contentsOf: moved.appendingPathComponent(url.lastPathComponent)) == rewritten)
}

@Test func projectSettingsIndependentConcurrentUpdatesShareOneLockAndCASHasOneWinner() async throws {
    let base = try projectSettingsFixture(); defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Settings"), key = "repository:concurrent"
    try ProjectSettingsFiles.save(.init(key: key, actions: []), root: root)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<8 {
            group.addTask {
                let action = try ProjectAction(id: "action-\(index)", input: .init(name: "Action \(index)", command: "printf controlled-\(index)"))
                try ProjectSettingsFiles.update(root: root, keys: [key]) { $0.actions = ($0.actions ?? []) + [action] }
            }
        }
        try await group.waitForAll()
    }
    #expect(try ProjectSettingsFiles.load(root: root, key: key)?.actions?.count == 8)
    let captured = try ProjectSettingsFiles.capture(root: root, keys: [key])
    let results = await withTaskGroup(of: Bool.self) { group in
        for index in 0..<8 {
            group.addTask {
                do {
                    try ProjectSettingsFiles.update(root: root, keys: [key], expectedCapture: captured) { $0.icon = .monogram(text: String(index), color: .blue) }
                    return true
                } catch { return false }
            }
        }
        var values: [Bool] = []; for await value in group { values.append(value) }; return values
    }
    #expect(results.filter { $0 }.count == 1)
    #expect(try ProjectSettingsFiles.load(root: root, key: key)?.actions?.count == 8)
}

@Test(arguments: ["valid", "corrupt", "foreign", "canonical-key"])
func projectSettingsFallbackMigrationRemovesOnlyTheValidatedExactSource(mode: String) throws {
    let base = try projectSettingsFixture(); defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Settings"), primary = "repository:main", fallback = "checkout:café"
    try ProjectSettingsFiles.save(.init(key: fallback, icon: .emoji("🌍")), root: root)
    let file = ProjectSettingsFiles.fileURL(root: root, key: fallback)
    if mode == "corrupt" { try writePrivateSettings(Data("{".utf8), to: file) }
    if mode == "foreign" { try writePrivateSettings(JSONEncoder().encode(ProjectSettingsDocument(key: "another-key", icon: .emoji("🌍"))), to: file) }
    if mode == "canonical-key" {
        try writePrivateSettings(JSONEncoder().encode(ProjectSettingsDocument(key: fallback.decomposedStringWithCanonicalMapping, icon: .emoji("🌍"))), to: file)
    }
    let before = try Data(contentsOf: file)
    if mode == "valid" {
        let captured = try ProjectSettingsFiles.capture(root: root, keys: [primary, fallback])
        try ProjectSettingsFiles.update(root: root, keys: [primary, fallback], expectedCapture: captured) { $0.worktreeSubmodules = .topLevel }
        let value = try #require(try ProjectSettingsFiles.load(root: root, key: primary))
        #expect(value.icon == .emoji("🌍") && value.worktreeSubmodules == .topLevel)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    } else {
        #expect(throws: CoincideError.self) { try ProjectSettingsFiles.update(root: root, keys: [primary, fallback]) { $0.icon = .emoji("🚀") } }
        #expect(throws: CoincideError.self) { try ProjectSettingsFiles.save(.init(key: fallback), root: root) }
        #expect(try Data(contentsOf: file) == before)
        #expect(!FileManager.default.fileExists(atPath: ProjectSettingsFiles.fileURL(root: root, key: primary).path))
    }
}
