import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct ConfigurationFixture: Sendable {
    let root: URL
    let service: WorkspaceFileService
    var file: URL { root.appendingPathComponent(ProjectConfigurationService.fileName) }
    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-configuration-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Self(root: root, service: WorkspaceFileService(root: root))
    }
    func write(_ contents: String) throws { try Data(contents.utf8).write(to: file) }
    func cleanup() async { await service.close(); try? FileManager.default.removeItem(at: root) }
}

@Test func projectConfigurationImportsCompleteJSONCSchemaAndPreservesLiteralScriptData() throws {
    let configuration = try ProjectConfiguration.parse(#"""
    {
      /* Documentation: https://t3.codes/schema/t3.json */
      "$schema": "https://t3.codes/schema/t3.json",
      "iconPath": "  assets/logo.svg  ",
      "defaultThreadEnvMode": "worktree",
      "worktreeSubmodules": "top-level",
      "scripts": [
        {
          "name": "  Dévelop 👨‍💻  ",
          "command": "  printf '%s\\n' 'https://example.invalid/a//b/*c*/,}';\nprintf '%s' '\"quoted\"'  ",
          "icon": "configure",
          "runOnWorktreeCreate": true,
          "runOnSettle": true,
          "async": false,
          "previewUrl": "  http://localhost:3000/path?a=one,b=two  ",
          "autoOpenPreview": true,
          "unknownFutureField": {"value": [1, 2,],},
        },
        {"name": "Repeated", "command": "echo same"},
        {"name": "Repeated", "command": "echo same"},
      ], // Imported roles are declarations, not instructions to execute.
    }
    """#)
    #expect(configuration.schemaURL == "https://t3.codes/schema/t3.json")
    #expect(configuration.iconPath == "assets/logo.svg" && configuration.defaultThreadEnvMode == .worktree && configuration.worktreeSubmodules == .topLevel)
    let script = try #require(configuration.scripts.first)
    #expect(script.name == "Dévelop 👨‍💻" && script.icon == .configure)
    #expect(script.command == "printf '%s\\n' 'https://example.invalid/a//b/*c*/,}';\nprintf '%s' '\"quoted\"'")
    #expect(script.runOnWorktreeCreate && script.runOnSettle && !script.runsAsynchronously)
    #expect(script.previewURL == "http://localhost:3000/path?a=one,b=two" && script.autoOpenPreview)
    #expect(configuration.scripts.count == 3 && configuration.scripts[1] == configuration.scripts[2])
    #expect(configuration.scripts[1].icon == .play && !configuration.scripts[1].runOnWorktreeCreate && !configuration.scripts[1].runOnSettle && configuration.scripts[1].runsAsynchronously)
    #expect(try JSONDecoder().decode(ProjectConfiguration.self, from: JSONEncoder().encode(configuration)) == configuration)
    #expect(try ProjectConfiguration.parse("{}").scripts.isEmpty)
    #expect(try ProjectConfiguration.parse(#"{"$schema":"","future":true}"#).schemaURL == "")
}

@Test func projectConfigurationJSONCLexerKeepsEscapedStringsAndRejectsMalformedOrUnsupportedValues() throws {
    let json = #"{"scripts":[{"name":"URLs","command":"echo \"//not-comment\"; echo \"/*literal*/ ,}\""}],/* tail */}"#
    #expect(try ProjectConfiguration.parse(json).scripts.first?.command == #"echo "//not-comment"; echo "/*literal*/ ,}""#)
    for invalid in [
        "{ not json", "[]", "null", #"{"scripts":null}"#, #"{"iconPath":null}"#,
        #"{"defaultThreadEnvMode":"remote"}"#, #"{"worktreeSubmodules":"all"}"#,
        #"{"scripts":{}}"#, #"{"scripts":[{"name":"A","command":"echo x","async":null}]}"#,
        #"{"scripts":[{"name":"A","command":"echo x","runOnSettle":1}]}"#,
        #"{"scripts":[{"name":"A","command":"echo x","icon":"unknown"}]}"#,
        #"{"scripts":[{"name":" ","command":"echo x"}]}"#,
        #"{"scripts":[{"name":"A","command":" \n "}]}"#,
        #"{"scripts":[{"name":"A","command":"echo\u0000hidden"}]}"#,
        #"{"scripts":[{"name":"A","command":"echo x","previewUrl":" "}]}"#,
        #"{"scripts":[{"name":"A","command":"echo x"},,]}"#,
        #"{"scripts":[,{"name":"A","command":"echo x"}]}"#,
        #"{"scripts":[],,}"#, #"{,"scripts":[]}"#, #"{"future":[,]}"#,
        #"{"future":01}"#, #"{"future":0x10}"#, #"{"future":.5}"#,
        #"{"future":1.}"#, #"{"future":1e}"#, #"{"future":undefined}"#,
        #"{"future":'single quotes'}"#, #"{unquoted: true}"#, "\u{feff}{}",
        #"{"unknown":tr/**/ue}"#, #"{"scripts":[], /* never closed}"#,
        #"{"scripts":[], "unknown":"unterminated}"#,
        "{\"unknown\":" + String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65) + "}",
    ] {
        #expect(throws: ProjectConfigurationError.self) { try ProjectConfiguration.parse(invalid) }
    }
}

@Test func projectConfigurationEnforcesPinnedDeclarationAndPathLimitsWithGenericDiagnostics() throws {
    let script = try ProjectScript(name: "Test", command: "echo test")
    #expect(try ProjectConfiguration(scripts: Array(repeating: script, count: 50)).scripts.count == 50)
    #expect(throws: ProjectConfigurationError.self) { try ProjectConfiguration(scripts: Array(repeating: script, count: 51)) }
    #expect(try ProjectConfiguration(iconPath: String(repeating: "😀", count: 256)).iconPath?.utf16.count == 512)
    #expect(throws: ProjectConfigurationError.self) { try ProjectConfiguration(iconPath: String(repeating: "😀", count: 257)) }
    #expect(throws: ProjectConfigurationError.self) { try ProjectConfiguration.parse(String(repeating: " ", count: ProjectConfigurationService.maximumBytes + 1)) }
    do {
        _ = try ProjectConfiguration.parse(#"{"scripts":[{"name":"synthetic-private-name","command":"https://synthetic-user:synthetic-secret@example.invalid","icon":"synthetic-secret"}]}"#)
        Issue.record("Invalid script metadata was accepted.")
    } catch {
        #expect(error is ProjectConfigurationError)
        #expect(!String(describing: error).contains("synthetic") && !error.localizedDescription.contains("synthetic"))
    }
}

@Test func projectScriptInvocationUsesLiteralCapturedProjectAndCheckoutContextWithoutExecution() throws {
    let script = try ProjectScript(name: "  Build  ", command: "  printf '%s' \"$T3CODE_PROJECT_ROOT\"; echo '$(do-not-expand-here)'  ", runOnWorktreeCreate: true, runsAsynchronously: false)
    let project = URL(fileURLWithPath: "/fixture/Project's root $(literal)"), checkout = URL(fileURLWithPath: "/fixture/工作 checkout\nwith newline")
    let local = try ProjectScriptInvocation(script: script, projectRoot: project)
    #expect(local.name == "Build" && local.command == script.command && local.directory == project)
    #expect(local.environment == ["T3CODE_PROJECT_ROOT": project.path])
    let worktree = try ProjectScriptInvocation(script: script, projectRoot: project, worktreePath: checkout)
    #expect(worktree.command == script.command && worktree.directory == checkout)
    #expect(worktree.environment == ["T3CODE_PROJECT_ROOT": project.path, "T3CODE_WORKTREE_PATH": checkout.path])
    for value in ["https://example.invalid/repo", "file://remote.invalid/repo", "file:///repo?token=synthetic", "file:///repo#fragment", "file://user:synthetic@localhost/repo"] {
        let url = try #require(URL(string: value))
        #expect(throws: ProjectConfigurationError.self) { try ProjectScriptInvocation(script: script, projectRoot: url) }
        #expect(throws: ProjectConfigurationError.self) { try ProjectScriptInvocation(script: script, projectRoot: project, worktreePath: url) }
    }
}

@Test func projectConfigurationAnchoredDiscoveryDistinguishesMissingAndRevisionsWithoutRunningCommands() async throws {
    let fixture = try ConfigurationFixture.make()
    do {
        let missing = try await ProjectConfigurationService.load(using: fixture.service)
        #expect(!missing.exists && missing.configuration == nil && missing.revision == nil && missing.warning == nil)
        let contents = #"{"scripts":[{"name":"Never executed","command":"touch config-discovery-must-not-execute","runOnWorktreeCreate":true,"runOnSettle":true,"autoOpenPreview":true,"previewUrl":"https://example.invalid"}]}"#
        try fixture.write(contents)
        let first = try await ProjectConfigurationService.load(using: fixture.service)
        #expect(first.exists && first.configuration?.scripts.count == 1 && first.revision != nil && first.warning == nil)
        #expect(try await ProjectConfigurationService.load(using: fixture.service) == first)
        try Data(contents.utf8).write(to: fixture.file, options: .atomic)
        let replacement = try await ProjectConfigurationService.load(using: fixture.service)
        #expect(replacement.configuration == first.configuration && replacement.revision != first.revision)
        try fixture.write(#"{"scripts":[{"name":"Never executed","command":"echo changed"}]}"#)
        let changed = try await ProjectConfigurationService.load(using: fixture.service)
        #expect(changed.configuration != first.configuration && changed.revision != replacement.revision)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("config-discovery-must-not-execute").path))
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test func projectConfigurationInvalidOversizeBinaryAndMalformedUTF8RemainNonExecutableWarnings() async throws {
    let fixture = try ConfigurationFixture.make()
    do {
        try fixture.write(#"{"scripts":[{"name":"A","command":false}]}"#)
        let invalid = try await ProjectConfigurationService.load(using: fixture.service)
        #expect(invalid.exists && invalid.configuration == nil && invalid.revision != nil && invalid.warning != nil)
        try fixture.write(String(repeating: " ", count: ProjectConfigurationService.maximumBytes + 1))
        let oversize = try await ProjectConfigurationService.load(using: fixture.service)
        #expect(oversize.exists && oversize.configuration == nil && oversize.revision == nil && oversize.warning?.contains("256 KB") == true)
        for bytes in [Data([0xff, 0x7b, 0x7d]), Data([0x7b, 0, 0x7d])] {
            try bytes.write(to: fixture.file)
            let unreadable = try await ProjectConfigurationService.load(using: fixture.service)
            #expect(unreadable.exists && unreadable.configuration == nil && unreadable.revision == nil && unreadable.warning != nil)
        }
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func projectConfigurationDiscoveryAllowsAnchoredInternalLinksButRejectsOutsideDanglingAndSpecialFiles() async throws {
    let fixture = try ConfigurationFixture.make(), outside = try ConfigurationFixture.make()
    do {
        let settings = fixture.root.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        try Data(#"{"scripts":[{"name":"Internal","command":"echo internal"}]}"#.utf8).write(to: settings.appendingPathComponent("configuration.json"))
        #expect(symlink("settings/configuration.json", fixture.file.path) == 0)
        #expect(try await ProjectConfigurationService.load(using: fixture.service).configuration?.scripts.first?.name == "Internal")
        #expect(unlink(fixture.file.path) == 0)
        try outside.write(#"{"scripts":[{"name":"Outside","command":"echo must-not-import"}]}"#)
        #expect(symlink(outside.file.path, fixture.file.path) == 0)
        let escaped = try await ProjectConfigurationService.load(using: fixture.service)
        #expect(escaped.configuration == nil && escaped.warning != nil)
        #expect(unlink(fixture.file.path) == 0)
        #expect(symlink("missing.json", fixture.file.path) == 0)
        #expect(try await ProjectConfigurationService.load(using: fixture.service).configuration == nil)
        #expect(unlink(fixture.file.path) == 0)
        #expect(mkfifo(fixture.file.path, 0o600) == 0)
        let fifo = try await ProjectConfigurationService.load(using: fixture.service)
        #expect(fifo.configuration == nil && fifo.warning != nil)
        var value = stat(); #expect(lstat(fixture.file.path, &value) == 0 && value.st_mode & S_IFMT == S_IFIFO)
        #expect(unlink(fixture.file.path) == 0)
        try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: false)
        #expect(try await ProjectConfigurationService.load(using: fixture.service).configuration == nil)
        #expect(try String(contentsOf: outside.file, encoding: .utf8).contains("must-not-import"))
    } catch { await fixture.cleanup(); await outside.cleanup(); throw error }
    await fixture.cleanup(); await outside.cleanup()
}

private actor ConfigurationGate {
    var opened = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func release() { opened = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
}

@Test func projectConfigurationDiscoveryPropagatesCancellationClosedSessionsAndReplacedRoot() async throws {
    let fixture = try ConfigurationFixture.make(), moved = fixture.root.appendingPathExtension("original")
    do {
        try fixture.write(#"{"scripts":[{"name":"Original","command":"echo original"}]}"#)
        _ = try await ProjectConfigurationService.load(using: fixture.service)
        let gate = ConfigurationGate()
        let task = Task { await gate.wait(); return try await ProjectConfigurationService.load(using: fixture.service) }
        task.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        try FileManager.default.moveItem(at: fixture.root, to: moved)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try fixture.write(#"{"scripts":[{"name":"Foreign replacement","command":"echo must-not-import"}]}"#)
        do { _ = try await ProjectConfigurationService.load(using: fixture.service); Issue.record("A replaced root was accepted.") }
        catch let error as WorkspaceFileError { #expect(error.failure == .rootReplaced) }
        #expect(try String(contentsOf: moved.appendingPathComponent("t3.json"), encoding: .utf8).contains("original"))
        #expect(try String(contentsOf: fixture.file, encoding: .utf8).contains("must-not-import"))
        await fixture.service.close()
        do { _ = try await ProjectConfigurationService.load(using: fixture.service); Issue.record("A closed file session was accepted.") }
        catch let error as WorkspaceFileError { #expect(error.failure == .closed) }
    } catch { await fixture.cleanup(); try? FileManager.default.removeItem(at: moved); throw error }
    await fixture.cleanup(); try? FileManager.default.removeItem(at: moved)
}
