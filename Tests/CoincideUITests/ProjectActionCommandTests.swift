import AppKit
import CoincideCore
import Foundation
import Testing
@testable import Coincide

@MainActor private final class ProjectCommandWindow: NSWindow {
    private static weak var owner: ProjectCommandWindow?
    override var isKeyWindow: Bool { Self.owner === self }
    override func makeKey() { Self.owner = self }
    override func resignKey() { if Self.owner === self { Self.owner = nil } }
    override func close() { resignKey(); super.close() }
}
@MainActor private func projectCommandWindow() -> NSWindow {
    let window = ProjectCommandWindow(contentRect: .init(x: -10000, y: -10000, width: 320, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = NSView(); window.makeKey(); return window
}
@MainActor private func projectCommandEvent(_ window: NSWindow, key: String = "r", code: UInt16 = 15) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
}

@MainActor @Test func projectActionCommandsUseWindowOwnerResolverOverridesAndEventMemoWithoutNativeShortcutFallback() async throws {
    let f = try keyboardFixtureStore(), other = try keyboardFixtureStore()
    let first = ProjectActionCommands(), second = ProjectActionCommands()
    let bindings = KeybindingsStore(fileURL: f.root.appendingPathComponent("keys.json"), watch: false)
    await bindings.start()
    do {
        let thread = try #require(f.threads["a-new"]), otherThread = try #require(other.threads["a-new"])
        f.store.selectedThreadID = thread.id; other.store.selectedThreadID = otherThread.id
        let action = try ProjectAction(id: "dev", input: .init(name: "Dev", command: "never executed", shortcut: .init(key: "r", command: true)))
        let entry = try #require(ProjectScriptCatalog(actions: [action], configuration: nil).scripts.first)
        let source = try #require(ProjectActionCommands.Source(store: f.store, thread: thread, entry: entry))
        let otherSource = try #require(ProjectActionCommands.Source(store: other.store, thread: otherThread, entry: entry))
        var firstCalls = 0, secondCalls = 0
        let owner = UUID(), otherOwner = UUID()
        first.replace(owner: owner, bindings: [.init(source: source, shortcut: action.shortcut, isAllowed: { true }, invoke: { firstCalls += 1 }, report: { _ in Issue.record("Unexpected invocation error") })])
        second.replace(owner: otherOwner, bindings: [.init(source: otherSource, shortcut: action.shortcut, isAllowed: { true }, invoke: { secondCalls += 1 }, report: { _ in Issue.record("Unexpected invocation error") })])
        let one = MainWindowController(store: f.store, keybindings: bindings), two = MainWindowController(store: other.store, keybindings: bindings)
        one.presentations = .init(projectActions: { first }); two.presentations = .init(projectActions: { second })
        let w1 = projectCommandWindow(), w2 = projectCommandWindow()
        defer { w1.close(); w2.close() }
        bindings.dispatcher.register(one, window: w1); bindings.dispatcher.register(two, window: w2)
        w1.makeKey()
        let event = try projectCommandEvent(w1)
        #expect(bindings.dispatcher.handle(event) == nil)
        #expect(bindings.dispatcher.handle(event) == nil)
        await first.drain()
        #expect(firstCalls == 1 && secondCalls == 0)
        w2.makeKey(); #expect(bindings.dispatcher.handle(try projectCommandEvent(w2)) == nil)
        await second.drain(); #expect(firstCalls == 1 && secondCalls == 1)
        // A file rule replaces this command's old default, rather than adding another shortcut.
        try await bindings.save(.init(key: "mod+u", command: .script("dev")))
        let context = KeybindingContext.menu
        #expect(bindings.resolve(.init(keyCode: 15, characters: "r", command: true, control: false, option: false, shift: false), context: context, projectDefaults: first.defaults) == nil)
        #expect(bindings.resolve(.init(keyCode: 32, characters: "u", command: true, control: false, option: false, shift: false), context: context, projectDefaults: first.defaults) == .script("dev"))
        try await bindings.remove(.init(key: "mod+u", command: .script("dev")))
        // Static app commands take precedence over active project defaults (pinned T3 primary/active policy).
        let conflict = try ProjectActionShortcut(key: "k", command: true)
        first.replace(owner: owner, bindings: [.init(source: source, shortcut: conflict, isAllowed: { true }, invoke: { firstCalls += 1 }, report: { _ in })])
        #expect(bindings.resolve(.init(keyCode: 40, characters: "k", command: true, control: false, option: false, shift: false), context: context, projectDefaults: first.defaults) == .commandPaletteToggle)
        try await bindings.save(.init(key: "mod+l", command: .commandPaletteToggle), replacing: .init(key: "mod+k", command: .commandPaletteToggle, when: "!terminalFocus"))
        #expect(bindings.resolve(.init(keyCode: 40, characters: "k", command: true, control: false, option: false, shift: false), context: context, projectDefaults: first.defaults) == .script("dev"))
        let terminalConflict = try ProjectActionShortcut(key: "d", command: true)
        first.replace(owner: owner, bindings: [.init(source: source, shortcut: terminalConflict, isAllowed: { true }, invoke: { firstCalls += 1 }, report: { _ in })])
        #expect(bindings.resolve(.init(keyCode: 2, characters: "d", command: true, control: false, option: false, shift: false), context: .init(["terminalFocus": true]), projectDefaults: first.defaults) == .terminalSplit)
        // A stale owner cannot unregister the replacement owner's commands.
        first.replace(owner: otherOwner, bindings: first.bindings); first.unregister(owner: owner)
        #expect(!first.bindings.isEmpty)
        bindings.dispatcher.unregister(one, window: w1); bindings.dispatcher.unregister(two, window: w2)
    } catch { await bindings.shutdown(); await f.store.shutdown(); await other.store.shutdown(); throw error }
    await bindings.shutdown(); await f.store.shutdown(); await other.store.shutdown()
    try FileManager.default.removeItem(at: f.root); try FileManager.default.removeItem(at: other.root)
}

@MainActor @Test func projectActionCommandsRetainOriginalBirthCheckoutConfigurationAndScriptDigest() async throws {
    let f = try keyboardFixtureStore()
    do {
        let thread = try #require(f.threads["a-new"]), project = f.projects[0]
        f.store.selectedThreadID = thread.id
        try await f.store.projectSettings.update(project) { $0.actions = [try .init(id: "dev", input: .init(name: "Dev", command: "printf one"))] }
        let entry = try #require(ProjectScriptCatalog(actions: f.store.projectSettings.document(for: project).actions, configuration: nil).scripts.first)
        let source = try #require(ProjectActionCommands.Source(store: f.store, thread: thread, entry: entry))
        let commands = ProjectActionCommands(); var calls = 0
        commands.replace(owner: UUID(), bindings: [.init(source: source, shortcut: nil, isAllowed: { source.isCurrent(in: f.store) }, invoke: { calls += 1 }, report: { _ in })])
        #expect(source.isCurrent(in: f.store))
        let projectIndex = try #require(f.store.snapshot.projects.firstIndex(where: { $0.id == project.id }))
        var resolved = project
        let remote = try #require(RepositoryIdentity.normalizedRemote("https://github.com/fixture/command-namespace.git"))
        resolved.repositoryIdentity = try RepositoryIdentity(remote: remote, remoteName: "origin", rootPath: project.path, projectRelativePath: "")
        let originalActions = f.store.projectSettings.document(for: project).actions
        try ProjectSettingsFiles.save(.init(key: ProjectSettingsKey.primary(for: resolved), actions: originalActions), root: f.store.projectSettings.root)
        await f.store.projectSettings.load(resolved)
        f.store.snapshot.projects[projectIndex] = resolved
        #expect(!commands.perform(.script("dev"), expected: source), "Equal action bytes in a new namespace do not retarget an old command.")
        f.store.snapshot.projects[projectIndex] = project
        let index = try #require(f.store.snapshot.threads.firstIndex(where: { $0.id == thread.id }))
        f.store.snapshot.threads[index].createdAt += 1
        #expect(!commands.perform(.script("dev"), expected: source))
        f.store.snapshot.threads[index] = thread
        f.store.snapshot.threads[index].workspacePath += "/other"
        #expect(!commands.perform(.script("dev"), expected: source))
        f.store.snapshot.threads[index] = thread
        f.store.selectedThreadID = f.threads["b-one"]?.id
        #expect(!commands.perform(.script("dev"), expected: source))
        f.store.selectedThreadID = thread.id
        try await f.store.projectSettings.update(project) { $0.actions = [try .init(id: "dev", input: .init(name: "Dev", command: "printf two"))] }
        #expect(!commands.perform(.script("dev"), expected: source))
        await commands.drain(); #expect(calls == 0)
        #expect(!ProjectActionCommands.targetIsCurrent(store: f.store, thread: thread, project: WorkspaceProject(path: project.path + "/other")))
    } catch { await f.store.shutdown(); throw error }
    await f.store.shutdown(); try FileManager.default.removeItem(at: f.root)
}

@MainActor @Test func projectActionShortcutYieldsToNativeCopyQuitAndFileEditorFindWithoutInvokingThem() async throws {
    let f = try keyboardFixtureStore(), commands = ProjectActionCommands()
    let keys = KeybindingsStore(fileURL: f.root.appendingPathComponent("keys.json"), watch: false)
    await keys.start()
    let window = projectCommandWindow(), oldMenu = NSApp.mainMenu
    defer { NSApp.mainMenu = oldMenu; window.close() }
    do {
        let thread = try #require(f.threads["a-new"]); f.store.selectedThreadID = thread.id
        let editor = NSTextView(); editor.string = "Native copy remains available"; editor.isEditable = true
        editor.setAccessibilityLabel("File editor"); editor.setSelectedRange(NSRange(location: 0, length: 6))
        window.contentView = editor; window.makeFirstResponder(editor)
        let menu = NSMenu(); menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"); copy.target = editor
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); quit.target = NSApp
        menu.addItem(copy); menu.addItem(quit); NSApp.mainMenu = menu
        let controller = MainWindowController(store: f.store, keybindings: keys)
        controller.presentations = .init(projectActions: { commands }); keys.dispatcher.register(controller, window: window)
        defer { keys.dispatcher.unregister(controller, window: window) }
        var calls = 0
        for (key, code) in [("c", UInt16(8)), ("q", UInt16(12)), ("f", UInt16(3)), ("c", UInt16(8))] {
            let action = try ProjectAction(id: "native-conflict", input: .init(name: "Conflict", command: "never execute", shortcut: .init(key: key, command: true)))
            let entry = try #require(ProjectScriptCatalog(actions: [action], configuration: nil).scripts.first)
            let source = try #require(ProjectActionCommands.Source(store: f.store, thread: thread, entry: entry))
            commands.replace(owner: UUID(), bindings: [.init(source: source, shortcut: action.shortcut, isAllowed: { true }, invoke: { calls += 1 }, report: { _ in })])
            let event = try projectCommandEvent(window, key: key, code: code)
            #expect(keys.dispatcher.handle(event) === event)
            #expect(keys.dispatcher.handle(event) === event, "The same event keeps its native routing decision.")
            await commands.drain()
            editor.setSelectedRange(NSRange(location: 0, length: 0))
        }
        #expect(calls == 0 && editor.string == "Native copy remains available")
    } catch { await keys.shutdown(); await f.store.shutdown(); try? FileManager.default.removeItem(at: f.root); throw error }
    await keys.shutdown(); await f.store.shutdown(); try FileManager.default.removeItem(at: f.root)
}
