import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private let commandUISkills = [
    ProviderSkill(name: "review", path: "/offline/skills/review", displayName: "Review changes 工作", scope: "project"),
    ProviderSkill(name: "hidden", path: "/offline/skills/hidden", enabled: false),
    ProviderSkill(name: "agent-only", path: "/offline/skills/agent", userInvocable: false)
]
private let commandUIRows = [
    ProviderCommand(name: "inspect", description: "Inspect the workspace", source: "extension", hints: ["Optional focus"]),
    ProviderCommand(name: "review", description: "A command shadowed by the visible skill"),
    ProviderCommand(name: "disabled", enabled: false), ProviderCommand(name: "internal", userInvocable: false)
]
private actor CommandUIGate {
    private var open: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = 0
    init(held: Bool) { open = !held }
    func wait() async { entered += 1; if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; let owned = waiters; waiters = []; owned.forEach { $0.resume() } }
}
private actor CommandUIMetadata: ProviderSession {
    nonisolated let events = AsyncStream<ProviderEvent> { _ in }
    let thread: CodingThread
    let readGate: CommandUIGate, closeGate: CommandUIGate
    init(thread: CodingThread, readGate: CommandUIGate, closeGate: CommandUIGate) {
        self.thread = thread; self.readGate = readGate; self.closeGate = closeGate
    }
    func providerCommands(forceReload: Bool) async -> ProviderCommandInventory {
        await readGate.wait()
        return .init(cwd: thread.workspacePath, commands: commandUIRows, skills: commandUISkills,
                     problems: [.init(component: .commands, message: "A command could not be loaded.")])
    }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) throws { throw ProviderCommandError(.unavailable) }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() async { await closeGate.wait() }
}
private actor CommandUIRuntime: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private var runID: UUID?
    private(set) var inputs: [String] = []
    private(set) var closed = 0
    init() { let stream = AsyncStream<ProviderEvent>.makeStream(); events = stream.stream; continuation = stream.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) { inputs.append(text); runID = thread.activeRun?.id }
    func interrupt() { if let runID { continuation.yield(.context(runID: runID, event: .completed(.interrupted))) }; runID = nil }
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { closed += 1; continuation.finish() }
}
private final class CommandUIFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [CodingThread] = []
    let readGate: CommandUIGate, closeGate: CommandUIGate
    let runtime = CommandUIRuntime()
    init(held: Bool) { readGate = .init(held: held); closeGate = .init(held: held) }
    func make(_ thread: CodingThread) -> any ProviderSession {
        if thread.activeRun != nil { return runtime }
        lock.withLock { captures.append(thread) }
        return CommandUIMetadata(thread: thread, readGate: readGate, closeGate: closeGate)
    }
    var metadataLaunches: [CodingThread] { lock.withLock { captures } }
}
@MainActor private struct CommandUIFixture {
    let root: URL, database: URL
    let thread: CodingThread
    let factory: CommandUIFactory
    let engine: WorkspaceEngine
    let store: WorkspaceStore
    static func make(provider: ProviderKind, held: Bool = false) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-command-ui-" + UUID().uuidString)
        let checkout = root.appendingPathComponent("Workspace")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let project = WorkspaceProject(path: checkout.path), database = root.appendingPathComponent("workspace.sqlite")
        var thread = CodingThread(project: project); thread.provider = provider; thread.model = ""; thread.checkpointPolicy = .disabled
        if provider == .pi {
            let instance = UUID(), agent = root.appendingPathComponent("Private Agent").path
            let runtime = try PiRuntimeConfiguration(instanceID: instance, executable: "/offline/pi", workspacePath: thread.workspacePath,
                homeDirectory: root.appendingPathComponent("Private Home").path, agentDirectory: agent,
                agentDirectorySelection: .explicitDirectory(environmentPath: agent))
            thread.piConfiguration = .init(instanceID: instance, executable: runtime.requestedExecutable, runtime: runtime)
        } else { thread.openCodeConfiguration = .init(executable: "/offline/opencode") }
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        try await WorkspaceDatabase(url: database).save(snapshot, event: "native.commands.fixture")
        let factory = CommandUIFactory(held: held)
        let engine = try WorkspaceEngine(url: database, providerFactory: { factory.make($0) }, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine, codexHostID: UUID()); await store.load()
        return .init(root: root, database: database, thread: thread, factory: factory, engine: engine, store: store)
    }
    func cleanup() async {
        await factory.readGate.release(); await factory.closeGate.release(); await store.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}
@MainActor private func commandUIEventually(_ predicate: () async -> Bool) async throws {
    let limit = ContinuousClock.now + .seconds(5)
    while !(await predicate()) {
        guard ContinuousClock.now < limit else { throw CoincideError("The native command fixture did not reach its owned boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test @MainActor func nativeCommandSelectionPreservesUnicodeLatestDraftAndRequiresPromptStartWithoutSending() throws {
    let text = "/ins😀 arguments 工作", caret = NSRange(location: 4, length: 0)
    let anchor = try #require(ComposerCommandMention.trigger(in: text, selection: caret))
    let inserted = try #require(anchor.inserting(command: "inspect", into: text + "\nمرحبا", selection: caret))
    #expect(inserted.text == "/inspect arguments 工作\nمرحبا")
    #expect(inserted.selection == NSRange(location: "/inspect ".utf16.count, length: 0))
    #expect(anchor.inserting(command: "inspect", into: "/other arguments", selection: caret) == nil)
    #expect(anchor.inserting(command: "inspect", into: text, selection: .init(location: 0, length: 0)) == nil)
    #expect(ComposerCommandMention.trigger(in: "prefix /inspect", selection: .init(location: 15, length: 0)) == nil)
    #expect(ComposerCommandMention.trigger(in: "/inspect arguments", selection: .init(location: 18, length: 0)) == nil)
    #expect(ComposerCommandMention.trigger(in: "/😀", selection: .init(location: 2, length: 0)) == nil)
    #expect(ComposerCommandMention.selection(in: text, range: .init(location: 1, length: 0)) == nil)
    let skill = try #require(anchor.anchor.inserting(token: "$review", into: text, selection: caret))
    #expect(skill.text == "$review arguments 工作")
    let visible = ProviderCommandPicker.matching(commands: commandUIRows, skills: commandUISkills.filter(\.canInvokeFromComposer), query: "", showSkills: true)
    #expect(visible.map(\.token) == ["/inspect", "$review"])
    #expect(ProviderCommandPicker.matching(commands: commandUIRows, skills: commandUISkills.filter(\.canInvokeFromComposer), query: "skill:rev", showSkills: true).map(\.token) == ["$review"])
    #expect(ProviderCommandPicker.matching(commands: commandUIRows, skills: commandUISkills.filter(\.canInvokeFromComposer), query: "review", showSkills: false).map(\.token) == ["/review"])
}

@Test(.timeLimit(.minutes(1)), arguments: [ProviderKind.pi, .opencode]) @MainActor
func nativeCommandScopeChangeRetiresAndJoinsItsLateInventoryWhileDraftAndPinRemainEditable(provider: ProviderKind) async throws {
    let fixture = try await CommandUIFixture.make(provider: provider, held: true)
    let model = try #require(fixture.store.skillsStore(threadID: fixture.thread.id))
    let refresh = Task { await model.refresh() }
    var shutdown: Task<Void, Never>?
    do {
        try await commandUIEventually { await fixture.factory.readGate.entered == 1 }
        let receipt = try await fixture.engine.dispatch(.editThread(fixture.thread.id, .permission(.fullAccess)))
        #expect(receipt.rejection == nil)
        try await commandUIEventually { model.isClosed }
        fixture.store.setDraft("Keep current text 工作 😀", id: fixture.thread.id); fixture.store.togglePin(fixture.thread.id)
        try await commandUIEventually { fixture.store.thread(fixture.thread.id)?.isPinned == true }
        var finished = false
        let task = Task { await fixture.store.shutdown(); finished = true }; shutdown = task
        try await commandUIEventually { await fixture.factory.closeGate.entered > 0 }
        #expect(!finished && model.commandInventory == nil && model.inventory == nil)
        await fixture.factory.closeGate.release(); await fixture.factory.readGate.release()
        await task.value; await refresh.value
        #expect(finished && model.commandInventory == nil && model.errorMessage == nil)
        #expect(fixture.store.thread(fixture.thread.id)?.draft == "Keep current text 工作 😀")
    } catch {
        await fixture.factory.readGate.release(); await fixture.factory.closeGate.release()
        await shutdown?.value; await refresh.value; await fixture.cleanup(); throw error
    }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeCommandDiscoveryKeepsActiveOpenCodeActorAndQueueCapturedAcrossFutureChoiceAndRestart() async throws {
    let fixture = try await CommandUIFixture.make(provider: .opencode)
    do {
        _ = try await fixture.engine.dispatch(.submit(threadID: fixture.thread.id, text: "Owned active input"))
        try await commandUIEventually { await fixture.factory.runtime.inputs == ["Owned active input"] }
        let model = try #require(fixture.store.skillsStore(threadID: fixture.thread.id)); await model.refresh()
        #expect(model.commands.map(\.name) == ["inspect", "review"] && model.skills.map(\.name) == ["review"])
        #expect(model.commandInventory?.isPartial == true)
        let metadata = try #require(fixture.factory.metadataLaunches.last)
        #expect(metadata.activeRun == nil && metadata.providerThreadID == nil && metadata.runtimeID == nil && metadata.queuedTurns.isEmpty)
        #expect(metadata.openCodeConfiguration == fixture.thread.openCodeConfiguration)
        #expect(await fixture.factory.runtime.closed == 0)
        #expect(await fixture.factory.runtime.inputs == ["Owned active input"], "Discovery and row selection never send a command.")
        let latest = "/ins notes 工作", caret = NSRange(location: 4, length: 0)
        let anchor = try #require(ComposerCommandMention.trigger(in: latest, selection: caret))
        let inserted = try #require(anchor.inserting(command: "inspect", into: latest + "\nLatest additional notes", selection: caret))
        fixture.store.setDraft(inserted.text, id: fixture.thread.id)
        _ = try await fixture.engine.dispatch(.submit(threadID: fixture.thread.id, text: inserted.text))
        let saved = try #require((await fixture.engine.current()).snapshot.threads.first { $0.id == fixture.thread.id })
        #expect(saved.queuedTurns.count == 1 && saved.queuedTurns[0].text == "/inspect notes 工作\nLatest additional notes")
        #expect(saved.queuedTurns[0].configuration.openCodeConfiguration == fixture.thread.openCodeConfiguration)
        _ = try await fixture.engine.dispatch(.editThread(fixture.thread.id, .permission(.fullAccess)))
        try await commandUIEventually { model.isClosed }
        #expect((await fixture.engine.current()).snapshot.threads.first { $0.id == fixture.thread.id }?.queuedTurns == saved.queuedTurns)
        await fixture.store.shutdown()
        let factory = fixture.factory
        let reopened = try WorkspaceEngine(url: fixture.database, providerFactory: { factory.make($0) }, identityResolver: { _ in nil })
        let snapshot = try await reopened.load()
        #expect(snapshot.threads.first { $0.id == fixture.thread.id }?.queuedTurns == saved.queuedTurns)
        #expect(await factory.runtime.inputs == ["Owned active input"])
        await reopened.shutdown()
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeCommandInventoryRefusalsStayDistinctFromAnEmptyCatalogAndTypingCannotDropOwnedResults() async throws {
    var thread = CodingThread(project: WorkspaceProject(path: "/offline/workspace")); thread.provider = .opencode
    thread.openCodeConfiguration = .init(executable: "/offline/opencode")
    let path = thread.workspacePath
    let unavailable = ProviderSkillsStore(scope: .init(thread), commandRead: { _ in throw ProviderCommandError(.unsupported) })
    await unavailable.refresh()
    #expect(unavailable.commandInventory == nil && unavailable.errorMessage == ProviderCommandError(.unsupported).localizedDescription)
    await unavailable.shutdown()
    let ambiguous = ProviderSkillsStore(scope: .init(thread), commandRead: { _ in
        .init(cwd: path, commands: [.init(name: "same"), .init(name: "same", description: "A different native command")], skills: [])
    })
    await ambiguous.refresh()
    #expect(ambiguous.commands.isEmpty && ambiguous.commandInventory == nil)
    #expect(ambiguous.errorMessage == ProviderCommandError(.invalidResponse).localizedDescription)
    await ambiguous.shutdown()
    let gate = CommandUIGate(held: true)
    let typing = ProviderSkillsStore(scope: .init(thread), commandRead: { _ in
        await gate.wait(); return .init(cwd: path, commands: commandUIRows, skills: commandUISkills)
    })
    let first = Task { await typing.refresh() }
    do {
        try await commandUIEventually { await gate.entered == 1 }
        first.cancel()
        let second = Task { await typing.refresh() }
        await gate.release(); await first.value; await second.value
        #expect(typing.commands.map(\.name) == ["inspect", "review"] && typing.errorMessage == nil)
        #expect(await gate.entered == 1)
    } catch { await gate.release(); await first.value; await typing.shutdown(); throw error }
    await typing.shutdown()
}

@MainActor private final class CommandUIGeometry { var frames: [String: CGRect] = [:] }

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeCommandPickerAndTypedComposerFitNarrowLongRowsInBothDirectionsWithoutInvokingAnything() async throws {
    _ = NSApplication.shared
    var thread = CodingThread(project: WorkspaceProject(path: "/offline/workspace")); thread.provider = .opencode
    thread.openCodeConfiguration = .init(executable: "/offline/opencode")
    let path = thread.workspacePath
    let command = ProviderCommand(name: "review-long-workspace", description: String(repeating: "Review all changes 工作 ومراجعة التغييرات. ", count: 5),
                                  source: "workspace", hints: ["Optional instructions"])
    let model = ProviderSkillsStore(scope: .init(thread), commandRead: { _ in
        .init(cwd: path, commands: [command], skills: commandUISkills,
              problems: [.init(component: .skills, message: "A skill could not be loaded.")])
    })
    await model.refresh()
    var invoked = 0
    defer { model.cancel() }
    for width: CGFloat in [320, 680] {
        for dark in [false, true] {
            for rtl in [false, true] {
                let geometry = CommandUIGeometry()
                let rows = ProviderCommandPicker.matching(commands: model.commands, skills: model.skills, query: "", showSkills: true)
                let picker = ProviderCommandPicker(model: model, query: .constant(""), searchField: true, selectedID: rows.first?.id,
                    choose: { _ in invoked += 1 }, move: { _ in }, confirm: { invoked += 1 }, dismiss: {}, showSkills: .constant(true),
                    reportGeometry: { geometry.frames[$0] = $1 })
                try await captureCommandUI(picker, geometry: geometry, width: width, dark: dark, rtl: rtl, name: "picker")
                let composerGeometry = CommandUIGeometry()
                let composer = ComposerView(text: .constant("/rev"), provider: .opencode, permission: .supervised, busy: true,
                    submitting: false, hasAttachments: false, attach: {}, importProviders: { _ in }, setPermission: { _ in },
                    send: { invoked += 1 }, stop: {}, reportGeometry: { composerGeometry.frames[$0] = $1 }, skills: model)
                try await captureCommandUI(composer, geometry: composerGeometry, width: width, dark: dark, rtl: rtl, name: "composer")
            }
        }
    }
    #expect(invoked == 0, "Appearance, discovery and layout never invoke a command, skill or prompt.")
    await model.shutdown()
}

@MainActor private func captureCommandUI<V: View>(_ content: V, geometry: CommandUIGeometry,
    width: CGFloat, dark: Bool, rtl: Bool, name: String) async throws {
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua)), previous = NSApp.appearance
    NSApp.appearance = appearance; defer { NSApp.appearance = previous }
    let height: CGFloat = 680
    let root = content.environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight).environment(\.controlActiveState, .active)
        .frame(width: width, height: height, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor))
    let host = NSHostingView(rootView: root); host.appearance = appearance; host.frame = .init(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: width, height: height),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
    let bounds = try #require(geometry.frames["bounds"])
    #expect(bounds.minX >= -1 && bounds.maxX <= width + 1 && bounds.height <= height)
    for key in name == "picker" ? ["refresh", "close", "viewport", "instructions"] : ["send"] {
        let frame = try #require(geometry.frames[key])
        #expect(frame.width > 0 && frame.height > 0 && bounds.insetBy(dx: -1, dy: -1).contains(frame))
    }
    guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_COMMANDS"] == "1" else { return }
    appearance.performAsCurrentDrawingAppearance {
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "coincide-commands-\(name)-\(Int(width))-\(dark ? "dark" : "light")-\(rtl ? "rtl" : "ltr").png"))
            }
        }
    }
}
