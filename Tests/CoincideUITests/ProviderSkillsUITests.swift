import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private let nativeSkills = [
    ProviderSkill(name: "review", path: "/fixture/skills/review/SKILL.md", displayName: "Review changes", description: "Review the current workspace", scope: "repo"),
    ProviderSkill(name: "REVIEW", path: "/fixture/personal/review/SKILL.md", scope: "user"),
    ProviderSkill(name: "ship-it", path: "/fixture/skills/ship/SKILL.md", shortDescription: "Inspect release readiness without publishing", scope: "user"),
    ProviderSkill(name: "disabled", path: "/fixture/disabled/SKILL.md", enabled: false),
    ProviderSkill(name: "agent-only", path: "/fixture/agent/SKILL.md", userInvocable: false),
    ProviderSkill(name: "2k", path: "/fixture/currency/SKILL.md")
]
private actor NativeSkillsGate {
    private var released: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = 0
    init(held: Bool = true) { released = !held }
    func wait() async { entered += 1; if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; let owned = waiters; waiters = []; owned.forEach { $0.resume() } }
}
private actor NativeSkillsPeer: ProviderSession {
    nonisolated let events = AsyncStream<ProviderEvent> { _ in }
    let thread: CodingThread
    let readGate: NativeSkillsGate
    let closeGate: NativeSkillsGate
    private(set) var forced: [Bool] = []
    private(set) var closes = 0
    init(thread: CodingThread, readGate: NativeSkillsGate, closeGate: NativeSkillsGate) {
        self.thread = thread; self.readGate = readGate; self.closeGate = closeGate
    }
    func codexSkills(forceReload: Bool) async -> ProviderSkillInventory {
        forced.append(forceReload); await readGate.wait()
        return .init(cwd: thread.workspacePath, skills: nativeSkills)
    }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) throws { throw CoincideError("Skills metadata must never send a prompt.") }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() async { closes += 1; await closeGate.wait() }
}
private actor NativeSkillsRuntime: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private var runID: UUID?
    private(set) var inputs: [String] = []
    private(set) var closes = 0
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; continuation = pair.continuation }
    func models() throws -> [ProviderModel] { throw ProviderSkillError(.unavailable) }
    func send(text: String, thread: CodingThread) {
        inputs.append(text); runID = thread.activeRun?.id
        if let runID {
            continuation.yield(.context(runID: runID, event: .thread("skills-offline-thread")))
            continuation.yield(.context(runID: runID, event: .turn("skills-turn-\(inputs.count)")))
        }
    }
    func interrupt() { if let runID { continuation.yield(.context(runID: runID, event: .completed(.interrupted))) }; runID = nil }
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { closes += 1; continuation.finish() }
}
private final class NativeSkillsFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [NativeSkillsPeer] = []
    private var launches: [CodingThread] = []
    let readGate: NativeSkillsGate, closeGate: NativeSkillsGate
    let runtime = NativeSkillsRuntime()
    init(heldRead: Bool, heldClose: Bool) {
        readGate = NativeSkillsGate(held: heldRead); closeGate = NativeSkillsGate(held: heldClose)
    }
    func make(_ thread: CodingThread) -> any ProviderSession {
        if thread.activeRun != nil { return runtime }
        let peer = NativeSkillsPeer(thread: thread, readGate: readGate, closeGate: closeGate)
        lock.withLock { peers.append(peer); launches.append(thread) }; return peer
    }
    var metadata: [NativeSkillsPeer] { lock.withLock { peers } }
    var metadataLaunches: [CodingThread] { lock.withLock { launches } }
}
@MainActor private struct NativeSkillsFixture {
    let root: URL, database: URL
    let project: WorkspaceProject, thread: CodingThread
    let factory: NativeSkillsFactory
    let engine: WorkspaceEngine
    let store: WorkspaceStore
    static func make(heldRead: Bool = false, heldClose: Bool = false) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-native-skills-" + UUID().uuidString, isDirectory: true)
        let checkout = root.appendingPathComponent("Checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let project = WorkspaceProject(path: checkout.path), database = root.appendingPathComponent("workspace.sqlite")
        var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
        thread.codexRuntimeConfiguration = .init(selection: .custom, executable: "/fixture/offline/codex", homeDirectory: root.appendingPathComponent("Captured Home").path)
        var initial = WorkspaceSnapshot(); initial.projects = [project]; initial.threads = [thread]
        try await WorkspaceDatabase(url: database).save(initial, event: "native.skills.fixture")
        let factory = NativeSkillsFactory(heldRead: heldRead, heldClose: heldClose)
        let engine = try WorkspaceEngine(url: database, providerFactory: { factory.make($0) }, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine, codexHostID: UUID()); await store.load()
        return .init(root: root, database: database, project: project, thread: thread, factory: factory, engine: engine, store: store)
    }
    func cleanup() async {
        await factory.readGate.release(); await factory.closeGate.release(); await store.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}
@MainActor private func waitNativeSkills(file: StaticString = #fileID, line: UInt = #line, _ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("Native skills fixture timed out at \(file):\(line).") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test @MainActor func nativeSkillMentionsUseUTF16AndPreserveLatestDraftSelectionAndLiteralText() throws {
    let text = "😀 prefix $review tail", caret = ("😀 prefix $re" as NSString).length
    let trigger = try #require(ComposerSkillMention.trigger(in: text, selection: .init(location: caret, length: 0), showSlash: true))
    #expect(trigger.query == "re" && trigger.expectedText == "$review")
    let latest = text + "\nأضف ملاحظة جديدة"
    let replacement = try #require(trigger.inserting(token: "$ship-it", into: latest, selection: .init(location: caret, length: 0)))
    #expect(replacement.text == "😀 prefix $ship-it tail\nأضف ملاحظة جديدة")
    #expect(replacement.selection == NSRange(location: ("😀 prefix $ship-it " as NSString).length, length: 0))
    #expect(trigger.inserting(token: "$ship-it", into: "Changed " + text, selection: trigger.selection) == nil)
    #expect(trigger.inserting(token: "$ship-it", into: text, selection: .init(location: 0, length: 0)) == nil)
    let emoji = try #require(ComposerSkillMention.selection(in: text, range: .init(location: 0, length: 2)))
    #expect(emoji.inserting(token: "$review", into: text, selection: emoji.selection)?.text == "$review prefix $review tail")
    #expect(ComposerSkillMention.selection(in: text, range: .init(location: 1, length: 1)) == nil)
    #expect(ComposerSkillMention.selection(in: text, range: .init(location: 0, length: 1)) == nil)
    #expect(ComposerSkillMention.trigger(in: text, selection: .init(location: 1, length: 0), showSlash: true) == nil)
    #expect(ComposerSkillMention.trigger(in: "/skill:ship", selection: .init(location: 11, length: 0), showSlash: true)?.query == "ship")
    #expect(ComposerSkillMention.trigger(in: "/skill:ship", selection: .init(location: 11, length: 0), showSlash: false) == nil)
    #expect(ComposerSkillMention.trigger(in: "Cost $123", selection: .init(location: 9, length: 0), showSlash: true) == nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeSkillsCoalesceDiscoveryWhileTypingAndCallerCancellationDoesNotDiscardOwnedInventory() async throws {
    let gate = NativeSkillsGate(), thread = CodingThread(project: WorkspaceProject(path: "/fixture/workspace"))
    let model = ProviderSkillsStore(scope: .init(thread), read: { _ in
        await gate.wait(); return .init(cwd: thread.workspacePath, skills: nativeSkills)
    })
    let first = Task { await model.refresh() }
    do {
        try await waitNativeSkills { await gate.entered == 1 }
        first.cancel() // A SwiftUI query task can retire while the same picker keeps typing.
        let second = Task { await model.refresh() }
        await gate.release(); await first.value; await second.value
        #expect(model.skills.map(\.name) == ["review", "ship-it"] && !model.isLoading && model.errorMessage == nil)
        #expect(await gate.entered == 1)
        #expect(SkillPicker.matching(model.skills, query: "readiness").map(\.name) == ["ship-it"])
    } catch { await gate.release(); await first.value; await model.shutdown(); throw error }
    await model.shutdown()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeSkillsRuntimeApplyClearsScopeImmediatelyAndJoinsMetadataCloseAndCancellationResistantRead() async throws {
    let fixture = try await NativeSkillsFixture.make(heldRead: true, heldClose: true)
    let model = try #require(fixture.store.skillsStore(threadID: fixture.thread.id))
    let refresh = Task { await model.refresh() }
    var apply: Task<Void, Never>?
    do {
        try await waitNativeSkills { await fixture.factory.readGate.entered == 1 }
        fixture.store.codexRuntime.selection = .custom; fixture.store.codexRuntime.executable = "/fixture/offline/new-codex"
        fixture.store.codexRuntime.homeDirectory = fixture.root.appendingPathComponent("New Home").path
        var applied = false
        let action = Task { await fixture.store.codexRuntime.applySelection(); applied = true }; apply = action
        try await waitNativeSkills { model.isClosed && fixture.store.codexRuntime.isApplying }
        try await waitNativeSkills { await fixture.factory.closeGate.entered > 0 }
        #expect(model.inventory == nil && fixture.store.skillsStore(threadID: fixture.thread.id) == nil && !applied)
        fixture.store.setDraft("Draft typed during runtime change 😀", id: fixture.thread.id)
        fixture.store.togglePin(fixture.thread.id)
        await fixture.factory.closeGate.release()
        #expect(!applied)
        await fixture.factory.readGate.release(); await action.value; await refresh.value
        #expect(applied && model.inventory == nil && fixture.store.thread(fixture.thread.id)?.draft == "Draft typed during runtime change 😀")
        try await waitNativeSkills { fixture.store.thread(fixture.thread.id)?.isPinned == true }
        let captured = try #require(fixture.store.skillsStore(threadID: fixture.thread.id))
        #expect(captured.id != model.id && captured.scope.configuration == fixture.thread.codexRuntimeConfiguration)
        #expect(fixture.store.codexRuntime.configuration.executable == "/fixture/offline/new-codex")
    } catch { await fixture.factory.readGate.release(); await fixture.factory.closeGate.release(); await apply?.value; await refresh.value; await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeSkillsDiscoveryKeepsActiveActorAndQueuedSkillMentionCapturedAcrossReopen() async throws {
    let fixture = try await NativeSkillsFixture.make()
    do {
        _ = try await fixture.engine.dispatch(.submit(threadID: fixture.thread.id, text: "Original active input"))
        try await waitNativeSkills { fixture.store.thread(fixture.thread.id)?.activeRun?.nativeTurnID != nil }
        let model = try #require(fixture.store.skillsStore(threadID: fixture.thread.id)); await model.refresh(forceReload: true)
        #expect(model.skills.map(\.name) == ["review", "ship-it"])
        let launch = try #require(fixture.factory.metadataLaunches.first)
        #expect(launch.activeRun == nil && launch.runtimeID == nil && launch.queuedTurns.isEmpty)
        #expect(launch.codexRuntimeConfiguration == fixture.thread.codexRuntimeConfiguration)
        #expect(await fixture.factory.runtime.closes == 0)
        let draft = "Latest 😀 $re", selection = NSRange(location: draft.utf16.count, length: 0)
        let anchor = try #require(ComposerSkillMention.trigger(in: draft, selection: selection, showSlash: true))
        let inserted = try #require(anchor.inserting(token: "$review", into: draft + " while preserving this suffix", selection: selection))
        fixture.store.setDraft(inserted.text, id: fixture.thread.id)
        _ = try await fixture.engine.dispatch(.submit(threadID: fixture.thread.id, text: inserted.text))
        let saved = try #require((await fixture.engine.current()).snapshot.threads.first { $0.id == fixture.thread.id })
        #expect(saved.queuedTurns.count == 1 && saved.queuedTurns[0].text == "Latest 😀 $review while preserving this suffix")
        #expect(saved.queuedTurns[0].configuration.codexRuntimeConfiguration == fixture.thread.codexRuntimeConfiguration)
        #expect(await fixture.factory.runtime.inputs == ["Original active input"])
        await fixture.store.shutdown()
        let factory = fixture.factory
        let reopenedEngine = try WorkspaceEngine(url: fixture.database, providerFactory: { factory.make($0) }, identityResolver: { _ in nil })
        let reopened = try await reopenedEngine.load()
        #expect(reopened.threads.first { $0.id == fixture.thread.id }?.queuedTurns == saved.queuedTurns)
        #expect(await fixture.factory.runtime.inputs == ["Original active input"])
        await reopenedEngine.shutdown()
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeSkillInventoryRemovalDiscardsLateResultAndShutdownJoinsItsOwnedRead() async throws {
    let fixture = try await NativeSkillsFixture.make(heldRead: true, heldClose: true)
    let model = try #require(fixture.store.skillsStore(threadID: fixture.thread.id))
    let refresh = Task { await model.refresh() }
    var shutdown: Task<Void, Never>?
    do {
        try await waitNativeSkills { await fixture.factory.readGate.entered == 1 }
        _ = try await fixture.engine.dispatch(.removeProject(projectID: fixture.project.id, expectedThreadIDs: [fixture.thread.id]))
        try await waitNativeSkills { fixture.store.thread(fixture.thread.id) == nil && model.isClosed }
        var finished = false
        let action = Task { await fixture.store.shutdown(); finished = true }; shutdown = action
        try await waitNativeSkills { await fixture.factory.closeGate.entered > 0 }
        #expect(!finished && model.inventory == nil)
        await fixture.factory.closeGate.release(); await fixture.factory.readGate.release()
        await action.value; await refresh.value
        #expect(finished && model.inventory == nil && model.errorMessage == nil)
    } catch { await fixture.factory.closeGate.release(); await fixture.factory.readGate.release(); await shutdown?.value; await refresh.value; await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeComposerSkillSelectionBridgeUsesItsOwnEditorAndRetainsTheNativeDelegate() async throws {
    let container = NSView(), local = NSView(), editor = NSTextView(), other = NSTextView()
    let delegate = NativeSkillsTextDelegate(); editor.delegate = delegate
    editor.string = "😀 $review"; other.string = editor.string
    container.addSubview(local); container.addSubview(other); local.addSubview(editor)
    let anchor = ComposerSelectionBridge.Anchor(); local.addSubview(anchor)
    var observed: (String, NSRange)?, updates = 0
    let bridge = ComposerSelectionBridge(request: nil, selectionChanged: { observed = ($0, $1); updates += 1 }, keyDown: { _ in false })
    let coordinator = ComposerSelectionBridge.Coordinator(bridge); coordinator.anchor = anchor
    defer { coordinator.detach() }
    coordinator.scheduleAttach()
    try await waitNativeSkills { coordinator.editor === editor }
    editor.setSelectedRange(.init(location: 3, length: 3))
    try await waitNativeSkills { observed?.1 == NSRange(location: 3, length: 3) }
    #expect(editor.delegate === delegate && observed?.0 == "😀 $review")
    let otherRange = other.selectedRange()
    coordinator.parent = .init(request: .init(text: editor.string, range: .init(location: 9, length: 0)),
        selectionChanged: { observed = ($0, $1); updates += 1 }, keyDown: { _ in false })
    coordinator.scheduleAttach()
    try await waitNativeSkills { editor.selectedRange() == NSRange(location: 9, length: 0) }
    #expect(other.selectedRange() == otherRange && editor.delegate === delegate)
    let beforeRejectedRequest = updates
    coordinator.parent = .init(request: .init(text: editor.string, range: .init(location: 1, length: 1)),
        selectionChanged: { observed = ($0, $1); updates += 1 }, keyDown: { _ in false })
    coordinator.scheduleAttach()
    try await waitNativeSkills { updates > beforeRejectedRequest }
    #expect(editor.selectedRange() == NSRange(location: 9, length: 0))
}
@MainActor private final class NativeSkillsTextDelegate: NSObject, NSTextViewDelegate {}
@MainActor private final class NativeSkillsGeometry {
    var frames: [String: CGRect] = [:]
}

@Test(arguments: [3, 30], [false, true]) @MainActor
func nativeSkillsPickerKeepsThreeRowsVisibleBesideCompetingTranscriptScrollView(count: Int, dark: Bool) async throws {
    _ = NSApplication.shared
    let thread = CodingThread(project: WorkspaceProject(path: "/fixture/workspace"))
    let rows = (0..<count).map { index in
        ProviderSkill(name: index == 2 ? "fresh-check" : "review-\(index)",
            path: "/fixture/skills/\(index)/SKILL.md", description: "Review the current workspace", scope: "repo")
    }
    let model = ProviderSkillsStore(scope: .init(thread), read: { _ in
        .init(cwd: thread.workspacePath, skills: rows,
              problems: [.init(message: "A skill could not be loaded.")])
    })
    await model.refresh()
    defer { model.cancel() }
    let geometry = NativeSkillsGeometry()
    let picker = SkillPicker(model: model, query: .constant(""), searchField: true, selectedID: rows[0].id,
        choose: { _ in }, move: { _ in }, confirm: {}, dismiss: {}, reportGeometry: { geometry.frames[$0] = $1 })
    // Match the native conversation's two competing vertical scroll areas at
    // its minimum window height. The results previously collapsed to 41 points.
    let content = VStack(spacing: 0) {
        Text("Conversation").frame(height: 44)
        ScrollView { Text("What are we building?").padding(.top, 100).padding(.bottom, 60) }
        VStack(spacing: 10) {
            picker
            TextEditor(text: .constant("Keep a second draft: $ship-check ")).frame(height: 40)
            Button("Send") {}.frame(height: 24)
        }.padding(14)
    }
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    let previous = NSApp.appearance
    NSApp.appearance = appearance
    defer { NSApp.appearance = previous }
    let root = content.environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.controlActiveState, .active).frame(width: 680, height: 600)
    let host = NSHostingView(rootView: root); host.appearance = appearance
    host.frame = .init(x: 0, y: 0, width: 680, height: 600)
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 680, height: 600),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await waitNativeSkills { geometry.frames["skill-" + rows[2].id] != nil && geometry.frames["viewport"] != nil }
    host.layoutSubtreeIfNeeded()
    let viewport = try #require(geometry.frames["viewport"])
    let instructions = try #require(geometry.frames["instructions"])
    let bounds = try #require(geometry.frames["bounds"])
    #expect(viewport.height <= 211 && viewport.height > 0)
    #expect(viewport.maxY <= instructions.minY && bounds.insetBy(dx: -1, dy: -1).contains(viewport))
    for row in rows.prefix(3) {
        let frame = try #require(geometry.frames["skill-" + row.id])
        #expect(viewport.insetBy(dx: -1, dy: -1).contains(frame))
    }
    #expect(host.fittingSize.height <= 601)
    await model.shutdown()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeSkillsPickerAndComposerFitNarrowLongLocalizedRowsInBothAppearancesAndDirections() async throws {
    _ = NSApplication.shared
    let thread = CodingThread(project: WorkspaceProject(path: "/fixture/workspace"))
    let offered = ProviderSkill(name: "review-long-workspace", path: "/fixture/very/long/skills/review/SKILL.md",
        displayName: "Review a long workspace name — مراجعة التغييرات 😀", description: String(repeating: "Review safely and preserve all current work. مراجعة التغييرات. ", count: 6), scope: "repository")
    let model = ProviderSkillsStore(scope: .init(thread), read: { _ in
        .init(cwd: thread.workspacePath, skills: [offered], problems: [.init(message: "A skill could not be loaded.")])
    })
    await model.refresh()
    for width: CGFloat in [320, 680] {
        for dark in [false, true] {
            for rtl in [false, true] {
                let geometry = NativeSkillsGeometry()
                let picker = SkillPicker(model: model, query: .constant(""), searchField: true, selectedID: offered.id,
                    choose: { _ in }, move: { _ in }, confirm: {}, dismiss: {}, reportGeometry: { geometry.frames[$0] = $1 })
                try await captureNativeSkills(picker, geometry: geometry, width: width, dark: dark, rtl: rtl, name: "picker")
                let composerGeometry = NativeSkillsGeometry()
                let composer = ComposerView(text: .constant("$re"), provider: .codex, permission: .supervised, busy: false,
                    submitting: false, hasAttachments: false, attach: {}, importProviders: { _ in }, setPermission: { _ in },
                    send: {}, stop: {}, reportGeometry: { composerGeometry.frames[$0] = $1 }, skills: model)
                try await captureNativeSkills(composer, geometry: composerGeometry, width: width, dark: dark, rtl: rtl, name: "composer")
            }
        }
    }
    await model.shutdown()
}
@MainActor private func captureNativeSkills<V: View>(_ content: V, geometry: NativeSkillsGeometry,
    width: CGFloat, dark: Bool, rtl: Bool, name: String) async throws {
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua)), previous = NSApp.appearance
    NSApp.appearance = appearance; defer { NSApp.appearance = previous }
    let height: CGFloat = 640
    let root = content.environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight).environment(\.controlActiveState, .active)
        .frame(width: width, height: height, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor))
    let host = NSHostingView(rootView: root); host.appearance = appearance
    host.frame = .init(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: width, height: height),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
    let bounds = try #require(geometry.frames["bounds"])
    #expect(bounds.minX >= -1 && bounds.maxX <= width + 1 && bounds.height <= height)
    for key in name == "picker" ? ["refresh", "close"] : ["send"] {
        let frame = try #require(geometry.frames[key])
        #expect(frame.width > 0 && frame.height > 0 && bounds.insetBy(dx: -1, dy: -1).contains(frame))
    }
    guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_SKILLS"] == "1" else { return }
    appearance.performAsCurrentDrawingAppearance {
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "coincide-skills-\(name)-\(Int(width))-\(dark ? "dark" : "light")-\(rtl ? "rtl" : "ltr").png"))
            }
        }
    }
}
