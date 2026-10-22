import Darwin
import Foundation
import Testing
@testable import CoincideCore

private actor ScriptCapturedOutput {
    var bytes = Data()
    var sequences: [UInt64] = []
    func append(_ value: ProjectScriptOutputChunk) { bytes.append(value.data); sequences.append(value.sequence) }
    func text() -> String { String(decoding: bytes, as: UTF8.self) }
}
private actor ScriptTestGate {
    var entered = false, released = false
    var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor ScriptTestFlag { var value = false; func set() { value = true } }

private struct ScriptExecutionFixture: Sendable {
    let scratch: URL, root: URL
    let files: WorkspaceFileService
    let helper: URL
    let plan: ProjectScriptExecutionPlan
    var environment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": scratch.path, "LANG": "en_US.UTF-8", "SYNTHETIC_VALUE": "literal fixture"]
    }
    static func make(_ command: String, name: String = "Managed fixture") async throws -> Self {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-script-execution-" + UUID().uuidString).resolvingSymlinksInPath()
        let root = scratch.appendingPathComponent("checkout's 工作 space")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = WorkspaceFileService(root: root)
        do {
            let configuration = try ProjectConfiguration(scripts: [.init(name: name, command: command, runOnWorktreeCreate: true)])
            try JSONEncoder().encode(configuration).write(to: root.appendingPathComponent("t3.json"))
            let plan = try await ProjectScriptExecutionPlan.capture(scriptIndex: 0, using: files, projectRoot: root, shell: URL(fileURLWithPath: "/bin/sh"))
            #if DEBUG
            let configurationName = "debug"
            #else
            let configurationName = "release"
            #endif
            let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let helper = checkout.appendingPathComponent(".build/\(configurationName)/CoincideScriptHelper")
            #expect(FileManager.default.isExecutableFile(atPath: helper.path), "SwiftPM must build the matching managed helper executable dependency.")
            return Self(scratch: scratch, root: root, files: files, helper: helper, plan: plan)
        } catch { await files.close(); try? FileManager.default.removeItem(at: scratch); throw error }
    }
    func session() throws -> NativeProjectScriptExecutionSession { try .init(plan: plan, helperURL: helper, environment: environment) }
    func cleanup() async { await files.close(); try? FileManager.default.removeItem(at: scratch) }
}
private func scriptEventually(_ detail: String, _ predicate: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Managed script fixture did not reach: " + detail) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func scriptCollector(_ session: NativeProjectScriptExecutionSession, _ output: ScriptCapturedOutput) -> Task<Void, any Error> {
    Task { try await session.consumeOutput { await output.append($0) } }
}

@Test(.timeLimit(.minutes(1)))
func managedScriptPlanRoundTripPreparedDoesNotExecuteAndStartIsOneShot() async throws {
    let fixture = try await ScriptExecutionFixture.make("printf '%s\\n' \"$PWD\" \"$T3CODE_PROJECT_ROOT\" \"$SYNTHETIC_VALUE\"; printf started > sentinel; exit 7")
    let session = try fixture.session(), output = ScriptCapturedOutput(), collector = scriptCollector(session, output)
    do {
        #expect(try JSONDecoder().decode(ProjectScriptExecutionPlan.self, from: JSONEncoder().encode(fixture.plan)) == fixture.plan)
        #expect(!String(decoding: try JSONEncoder().encode(fixture.plan), as: UTF8.self).contains("SYNTHETIC_VALUE\":\"literal fixture"))
        try await session.prepare()
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("sentinel").path))
        try session.start(); try await session.waitUntilStarted()
        #expect(throws: ProjectScriptExecutionError.self) { try session.start() }
        #expect(try await session.waitForCommandExit() == .exited(7))
        #expect(try await session.waitForCommandExit() == .exited(7))
        try await scriptEventually("literal cwd/environment output") { await output.text().contains("literal fixture") }
        #expect(await output.text().contains(fixture.root.path))
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("sentinel"), encoding: .utf8) == "started")
    } catch { await session.close(); _ = await collector.result; await fixture.cleanup(); throw error }
    await session.close(); _ = await collector.result; await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func managedScriptExitSevenDoesNotLoseStdioClosedBackgroundOwnershipAndRepeatedCloseDrains() async throws {
    let fixture = try await ScriptExecutionFixture.make("/bin/sh -c 'trap \"\" HUP TERM; printf \"%s\" \"$$\" > background.pid; exec /bin/sleep 30' </dev/null >/dev/null 2>&1 & exit 7")
    let session = try fixture.session()
    do {
        try await session.prepare(); try session.start(); try await session.waitUntilStarted()
        #expect(try await session.waitForCommandExit() == .exited(7))
        try await scriptEventually("background pid") { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("background.pid").path) }
        let pid = try #require(session.helperProcessID)
        #expect(!(try ScriptWire.groupMembers(pid, excluding: pid)).isEmpty)
        async let one: Void = session.close()
        async let two: Void = session.close()
        _ = await (one, two)
        #expect(try ScriptWire.groupMembers(pid, excluding: pid).isEmpty)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    } catch { await session.close(); await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func managedScriptCommandExitResolvesWhileBackgroundPTYOutputContinuesUntilStop() async throws {
    let fixture = try await ScriptExecutionFixture.make("/bin/sh -c 'trap \"\" HUP TERM; while :; do printf \"tick😀\\n\"; /bin/sleep 0.03; done' & exit 0")
    let session = try fixture.session(), output = ScriptCapturedOutput(), collector = scriptCollector(session, output)
    do {
        try await session.prepare(); try session.start(); try await session.waitUntilStarted()
        #expect(try await session.waitForCommandExit() == .exited(0))
        try await scriptEventually("first background output") { await output.bytes.count > 0 }
        let before = await output.bytes.count
        try await scriptEventually("output after command exit") { await output.bytes.count > before }
        let pid = try #require(session.helperProcessID)
        await session.close(); _ = await collector.result
        #expect(try ScriptWire.groupMembers(pid, excluding: pid).isEmpty)
    } catch { await session.close(); _ = await collector.result; await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func managedScriptControlEOFModelsOwnerDeathAndChildrenCannotRetainAuthorityFDs() async throws {
    let fixture = try await ScriptExecutionFixture.make("/bin/sh -c 'trap \"\" HUP TERM; printf ready > alive; exec /bin/sleep 30' & exit 0")
    let session = try fixture.session()
    do {
        try await session.prepare(); try session.start(); try await session.waitUntilStarted()
        #expect(try await session.waitForCommandExit() == .exited(0))
        try await scriptEventually("live child") { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("alive").path) }
        let pid = try #require(session.helperProcessID)
        // Close ONLY the authority writer: no Stop frame and no app escalation timer.
        session.simulateControlEOF()
        try await scriptEventually("helper exited after authority EOF") { kill(pid, 0) == -1 && errno == ESRCH }
        #expect(try ScriptWire.groupMembers(pid, excluding: pid).isEmpty)
        await session.close()
    } catch { await session.close(); await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func managedScriptPreparedConfigAndRootReplacementsRejectStartWithoutWritingEitherFolder() async throws {
    for replaceRoot in [false, true] {
        let fixture = try await ScriptExecutionFixture.make("printf forbidden > must-not-exist")
        let session = try fixture.session()
        do {
            try await session.prepare()
            if replaceRoot {
                try FileManager.default.moveItem(at: fixture.root, to: fixture.scratch.appendingPathComponent("original"))
                try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: fixture.scratch.appendingPathComponent("original/t3.json"), to: fixture.root.appendingPathComponent("t3.json"))
            } else {
                let url = fixture.root.appendingPathComponent("t3.json")
                try Data(contentsOf: url).write(to: url, options: .atomic)
            }
            try session.start()
            do { try await session.waitUntilStarted(); Issue.record("A replaced approved workspace/config was executed.") }
            catch let error as ProjectScriptExecutionError { #expect(error.failure == .configurationChanged) }
            await session.close()
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("must-not-exist").path))
            #expect(!FileManager.default.fileExists(atPath: fixture.scratch.appendingPathComponent("original/must-not-exist").path))
        } catch { await session.close(); await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }
}

@Test(.timeLimit(.minutes(1)))
func managedScriptPreStartCancellationNeverRunsAndCancelledExitWaiterDoesNotStopAnother() async throws {
    let fixture = try await ScriptExecutionFixture.make("IFS= read -r value; printf 'accepted:%s' \"$value\"; exit 0")
    let unused = try fixture.session()
    try await unused.prepare(); await unused.close()
    #expect(throws: ProjectScriptExecutionError.self) { try unused.start() }
    let session = try fixture.session(), output = ScriptCapturedOutput(), collector = scriptCollector(session, output)
    do {
        try await session.prepare(); try session.start(); try await session.waitUntilStarted()
        let cancelled = Task { try await session.waitForCommandExit() }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("A cancelled exit waiter succeeded.") }
        catch { #expect(error is CancellationError) }
        try await session.resize(columns: 100, rows: 30)
        try await session.sendInput(Data("hello\n".utf8))
        #expect(try await session.waitForCommandExit() == .exited(0))
        try await scriptEventually("PTY input") { await output.text().contains("accepted:hello") }
    } catch { await session.close(); _ = await collector.result; await fixture.cleanup(); throw error }
    await session.close(); _ = await collector.result; await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func managedScriptRawOutputIsOrderedAndLosslessAcrossManyUTF8Chunks() async throws {
    let repeated = "ab😀é𝒜", count = 35_000
    let fixture = try await ScriptExecutionFixture.make("i=0; while [ \"$i\" -lt \(count) ]; do printf '\(repeated)'; i=$((i+1)); done; exit 7")
    let session = try fixture.session(), output = ScriptCapturedOutput(), collector = scriptCollector(session, output)
    do {
        try await session.prepare(); try session.start()
        #expect(try await session.waitForCommandExit() == .exited(7))
        let expected = Data(String(repeating: repeated, count: count).utf8)
        try await scriptEventually("all ordered raw bytes") { await output.bytes.count >= expected.count }
        #expect(await output.bytes == expected)
        let sequence = await output.sequences
        #expect(sequence == Array(0..<UInt64(sequence.count)) && sequence.count > 16)
    } catch { await session.close(); _ = await collector.result; await fixture.cleanup(); throw error }
    await session.close(); _ = await collector.result; await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func managedScriptCloseRemainsResponsiveUnderOutputPressureAndHeldPresentation() async throws {
    let fixture = try await ScriptExecutionFixture.make("trap '' HUP TERM; while :; do printf 'output-pressure-😀-0123456789'; done")
    let session = try fixture.session(), gate = ScriptTestGate(), closed = ScriptTestFlag()
    let collector = Task { try await session.consumeOutput { _ in await gate.hold() } }
    do {
        try await session.prepare(); try session.start(); try await session.waitUntilStarted()
        try await scriptEventually("consumer held with active output") { await gate.entered }
        let closing = Task { await session.close(); await closed.set() }
        try await scriptEventually("owned process drain independent of presentation") { await closed.value }
        await closing.value
        let pid = try #require(session.helperProcessID)
        #expect(try ScriptWire.groupMembers(pid, excluding: pid).isEmpty)
        await gate.release(); _ = await collector.result
    } catch { await gate.release(); await session.close(); _ = await collector.result; await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func managedScriptShellCannotInheritHelperAuthorityOrAnchoredDirectoryDescriptors() async throws {
    let command = "for fd in 3 4 5 6 7 8 9 30; do if ( : >&\"$fd\" ) 2>/dev/null; then printf 'LEAKED:%s\\n' \"$fd\"; fi; done; printf 'fd-check-complete'; exit 0"
    let fixture = try await ScriptExecutionFixture.make(command)
    let session = try fixture.session(), output = ScriptCapturedOutput(), collector = scriptCollector(session, output)
    do {
        try await session.prepare(); try session.start(); #expect(try await session.waitForCommandExit() == .exited(0))
        try await scriptEventually("descriptor probe completed") { await output.text().contains("fd-check-complete") }
        #expect(!(await output.text()).contains("LEAKED"))
    } catch { await session.close(); _ = await collector.result; await fixture.cleanup(); throw error }
    await session.close(); _ = await collector.result; await fixture.cleanup()
}

@Test func managedScriptWireAndDecodedPlansRejectInvalidPayloadsWithoutCredentialDiagnostics() async throws {
    let fixture = try await ScriptExecutionFixture.make("printf harmless")
    var message = ScriptWire.Message("start", id: fixture.plan.id); message.input = Data([1])
    #expect(throws: ProjectScriptExecutionError.self) { try ScriptWire.frame(message) }
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.plan)) as? [String: Any])
    object["shellPath"] = "https://synthetic-user:synthetic-secret@example.invalid/shell"
    do {
        _ = try JSONDecoder().decode(ProjectScriptExecutionPlan.self, from: JSONSerialization.data(withJSONObject: object))
        Issue.record("A nonlocal decoded plan was accepted.")
    } catch { #expect(!error.localizedDescription.contains("synthetic")) }
    let env = try NativeProjectScriptExecutionSession.sanitizedEnvironment(["PATH": "/bin", "GIT_CONFIG_PARAMETERS": "synthetic", "GIT_DIR": "/foreign", "T3CODE_PROJECT_ROOT": "/old", "SSH_AUTH_SOCK": "/fixture/socket"])
    #expect(env == ["PATH": "/bin", "SSH_AUTH_SOCK": "/fixture/socket"])
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func managedScriptCoalescedStopThenStartCannotExecuteAPreparedCommand() async throws {
    let fixture = try await ScriptExecutionFixture.make("printf forbidden > coalesced-must-not-execute")
    let ready = ScriptPromise<Void>(), prepared = ScriptPromise<Void>(), output = ScriptOutputQueue()
    let child = try ScriptHelperProcess(helper: fixture.helper, id: fixture.plan.id, environment: fixture.environment, output: output) { message in
        if message.kind == "ready" { ready.finish(.success(())) }
        if message.kind == "prepared" { prepared.finish(.success(())) }
    }
    do {
        try await ready.value()
        var prepare = ScriptWire.Message("prepare", id: fixture.plan.id); prepare.plan = fixture.plan
        try await child.write(prepare); try await prepared.value()
        try await child.writeBatch([.init("stop", id: fixture.plan.id), .init("start", id: fixture.plan.id)])
        await child.finished()
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("coalesced-must-not-execute").path))
    } catch { child.stop(); await child.finished(); await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func managedScriptUnexpectedHelperDeathDrainsLiveGroupWithoutReplayingTheCommand() async throws {
    let fixture = try await ScriptExecutionFixture.make("printf once >> executions; trap '' HUP TERM; while :; do /bin/sleep 1; done")
    let session = try fixture.session()
    do {
        try await session.prepare(); try session.start(); try await session.waitUntilStarted()
        try await scriptEventually("first execution") { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("executions").path) }
        let pid = try #require(session.helperProcessID)
        #expect(!(try ScriptWire.groupMembers(pid, excluding: pid)).isEmpty)
        // This live helper is our unreaped child; its PID is not restored from storage.
        #expect(kill(pid, SIGKILL) == 0)
        do { _ = try await session.waitForCommandExit(); Issue.record("A killed helper reported successful command completion.") }
        catch { #expect(error is ProjectScriptExecutionError) }
        await session.close()
        #expect(try ScriptWire.groupMembers(pid, excluding: pid).isEmpty)
        let reopened = try fixture.session()
        try await reopened.prepare(); await reopened.close()
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("executions"), encoding: .utf8) == "once")
    } catch { await session.close(); await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func managedScriptCloseDrainsWhenCommandNeverReadsItsPendingPTYInput() async throws {
    let fixture = try await ScriptExecutionFixture.make("trap '' HUP TERM; printf alive > nonreader; while :; do /bin/sleep 1; done")
    let session = try fixture.session(), senders = ScriptTestFlag()
    do {
        try await session.prepare(); try session.start(); try await session.waitUntilStarted()
        let pending = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 { group.addTask { _ = try? await session.sendInput(Data(repeating: 97, count: 65_536)) } }
            }
            await senders.set()
        }
        try await scriptEventually("non-reading command") { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("nonreader").path) }
        let pid = try #require(session.helperProcessID)
        await session.close(); await pending.value
        #expect(await senders.value)
        #expect(try ScriptWire.groupMembers(pid, excluding: pid).isEmpty)
    } catch { await session.close(); await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func managedScriptConcurrentControlWritersAreBoundedBeforeFrameAllocation() async throws {
    let fixture = try await ScriptExecutionFixture.make(String(repeating: ":;", count: 100_000))
    let nonreader = fixture.scratch.appendingPathComponent("owned-nonreading-helper")
    try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: nonreader)
    #expect(chmod(nonreader.path, 0o700) == 0)
    let child = try ScriptHelperProcess(helper: nonreader, id: fixture.plan.id, environment: fixture.environment, output: ScriptOutputQueue()) { _ in }
    var prepare = ScriptWire.Message("prepare", id: fixture.plan.id); prepare.plan = fixture.plan
    let firstMessage = prepare
    let blocked = Task { try await child.write(firstMessage) }
    do {
        try await scriptEventually("one admitted large control frame") { child.pendingControlWrites.bytes == ScriptWire.maximumFrame }
        for _ in 0..<32 {
            do { try await child.write(ScriptWire.Message("stop", id: fixture.plan.id)); Issue.record("An input frame bypassed the aggregate admission cap.") }
            catch let error as ProjectScriptExecutionError { #expect(error.failure == .inputBusy) }
        }
        #expect(child.pendingControlWrites.count == 1 && child.pendingControlWrites.bytes <= ScriptWire.maximumFrame)
        child.stop(); await child.finished(); _ = await blocked.result
        #expect(child.pendingControlWrites.count == 0 && child.pendingControlWrites.bytes == 0)
    } catch { child.stop(); await child.finished(); _ = await blocked.result; await fixture.cleanup(); throw error }
    await fixture.cleanup()
}
