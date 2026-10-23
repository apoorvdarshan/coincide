import Darwin
import Foundation
import Testing
@testable import CoincideCore

private actor EmbeddedScriptOutput {
    private var data = Data()
    func append(_ chunk: ProjectScriptOutputChunk) { data.append(chunk.data) }
    var text: String { String(decoding: data, as: UTF8.self) }
}

private struct EmbeddedScriptFixture: Sendable {
    let root: URL, workspace: URL, executable: URL
    let files: WorkspaceFileService
    let plan: ProjectScriptExecutionPlan
    var environment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.path, "LANG": "en_US.UTF-8",
         "SHELL": "/bin/sh", "GIT_DIR": "must-be-removed", "CODEX_THREAD_ID": "must-be-removed"]
    }
    static func make(command: String) async throws -> Self {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("coincide-embedded-script-\(UUID())").resolvingSymlinksInPath()
        let workspace = root.appendingPathComponent("worktree's 工作 space"), project = root.appendingPathComponent("source")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: project, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let files = WorkspaceFileService(root: workspace)
        do {
            let configuration = try ProjectConfiguration(scripts: [.init(name: "Reviewed private settle", command: command, runOnSettle: true)])
            try JSONEncoder().encode(configuration).write(to: workspace.appendingPathComponent("t3.json"), options: .atomic)
            let plan = try await ProjectScriptExecutionPlan.capture(scriptIndex: 0, using: files, projectRoot: project, shell: URL(fileURLWithPath: "/bin/sh"))
            #if DEBUG
            let mode = "debug"
            #else
            let mode = "release"
            #endif
            let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let built = checkout.appendingPathComponent(".build/\(mode)/CoincideEnvironment").resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: built.path) else { throw CoincideError("Build the matching environment executable before embedded-helper acceptance.") }
            let executable = root.appendingPathComponent("preinstalled-environment")
            try fm.createSymbolicLink(at: executable, withDestinationURL: built)
            return .init(root: root, workspace: workspace, executable: executable, files: files, plan: plan)
        } catch { await files.close(); try? fm.removeItem(at: root); throw error }
    }
    func session() throws -> NativeProjectScriptExecutionSession {
        let factory = try RemoteEnvironmentScriptHelper.factory(executableURL: executable, environment: environment)
        let value = try factory(plan)
        return try #require(value as? NativeProjectScriptExecutionSession)
    }
    func close() async { await files.close(); try? FileManager.default.removeItem(at: root) }
}

private func embeddedScriptEventually(_ predicate: @escaping @Sendable () async throws -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < end else { throw CoincideError("The private embedded script helper did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1)))
func remoteEnvironmentEmbeddedScriptFactoryRefusesUnavailableOrForeignExecutableWithoutLaunching() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-script-factory-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let nonExecutable = root.appendingPathComponent("not-executable")
    try Data("private fixture".utf8).write(to: nonExecutable)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nonExecutable.path)
    for url in [nil, root, nonExecutable, root.appendingPathComponent("missing"), URL(string: "https://example.invalid/helper")] as [URL?] {
        #expect(throws: ProjectScriptExecutionError.self) {
            _ = try RemoteEnvironmentScriptHelper.factory(executableURL: url, environment: [:])
        }
    }
    #expect(throws: ProjectScriptExecutionError.self) {
        _ = try RemoteEnvironmentScriptHelper.factory(executableURL: URL(fileURLWithPath: "/bin/sh"), environment: ["BAD=KEY": "value"])
    }
}

@Test(.timeLimit(.minutes(1)))
func remoteEnvironmentEmbeddedScriptUsesSameExecutableAndPreparedApprovalStartsExactlyOnce() async throws {
    let f = try await EmbeddedScriptFixture.make(command: "printf 'one\\n' >> executions; printf 'native-output😀:%s:%s' \"$PWD\" \"${GIT_DIR-unset}\"; exit 7")
    let session = try f.session(), output = EmbeddedScriptOutput()
    let collector = Task { try await session.consumeOutput { await output.append($0) } }
    do {
        try await session.prepare()
        #expect(!FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("executions").path))
        let helperPID = try #require(session.helperProcessID)
        #expect(getsid(helperPID) == helperPID && getpgid(helperPID) == helperPID)
        try session.start(); try await session.waitUntilStarted()
        #expect(throws: ProjectScriptExecutionError.self) { try session.start() }
        let exit = try await session.waitForCommandExit()
        #expect(exit == .exited(7))
        try await embeddedScriptEventually { await output.text.contains("native-output😀:" + f.workspace.path + ":unset") }
        let text = await output.text
        #expect(text.contains(f.workspace.path) && text.contains(":unset"))
        #expect(try String(contentsOf: f.workspace.appendingPathComponent("executions"), encoding: .utf8) == "one\n")
        await session.close(); _ = await collector.result
        #expect(kill(helperPID, 0) == -1 && errno == ESRCH)
        let afterRestart = try f.session()
        try await afterRestart.prepare(); await afterRestart.close()
        #expect(try String(contentsOf: f.workspace.appendingPathComponent("executions"), encoding: .utf8) == "one\n", "Preparing the same approved files after a host restart must not replay a command.")
    } catch { await session.close(); _ = await collector.result; await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteEnvironmentEmbeddedScriptStopDrainsOwnedSessionAndDetachedCommandGroup() async throws {
    let f = try await EmbeddedScriptFixture.make(command: "/bin/sh -c 'trap \"\" HUP TERM; printf \"%s\" \"$$\" > child.pid; exec /bin/sleep 30' </dev/null >/dev/null 2>&1 & exit 0")
    let session = try f.session()
    do {
        try await session.prepare(); try session.start(); try await session.waitUntilStarted()
        let exit = try await session.waitForCommandExit()
        #expect(exit == .exited(0))
        try await embeddedScriptEventually { FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("child.pid").path) }
        let pid = try #require(session.helperProcessID)
        #expect(!(try ScriptWire.groupMembers(pid, excluding: pid)).isEmpty)
        async let first: Void = session.close()
        async let second: Void = session.close()
        _ = await (first, second)
        #expect(try ScriptWire.groupMembers(pid, excluding: pid).isEmpty)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    } catch { await session.close(); await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteEnvironmentEmbeddedScriptRevalidatesReviewedConfigurationBeforeAnyCommand() async throws {
    let f = try await EmbeddedScriptFixture.make(command: "printf forbidden > must-not-exist")
    let session = try f.session()
    do {
        try await session.prepare()
        let configuration = f.workspace.appendingPathComponent("t3.json")
        try Data(contentsOf: configuration).write(to: configuration, options: .atomic)
        try session.start()
        do { try await session.waitUntilStarted(); Issue.record("Changed reviewed configuration was executed.") }
        catch let failure as ProjectScriptExecutionError { #expect(failure.failure == .configurationChanged) }
        await session.close()
        #expect(!FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("must-not-exist").path))
    } catch { await session.close(); await f.close(); throw error }
    await f.close()
}
