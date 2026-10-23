import AppKit
import CoincideCore
import CoincideTerminal
import SwiftUI
import Testing
@testable import Coincide

@MainActor private final class PresentationProbe {
    var calls: [String] = []
    func presentations(terminalVisible: Bool = false) -> MainWindowPresentations {
        MainWindowPresentations(newProject: { self.calls.append("newProject") }, cloneRepository: { self.calls.append("clone") },
            importAgentProjects: { self.calls.append("import") }, settle: { self.calls.append("settle:" + $0.title) },
            runScript: { self.calls.append("script:" + $0.title) }, toggleTerminal: { self.calls.append("terminal") },
            terminalVisible: { terminalVisible }, newWindow: { self.calls.append("window") }, openRemote: { self.calls.append("remote") },
            openSettings: { self.calls.append("settings") })
    }
}

private func keyEvent(_ window: NSWindow, keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false,
                      type: NSEvent.EventType = .keyDown) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, characters: characters,
                                  charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: keyCode))
}

@MainActor private func offscreenWindow() -> NSWindow {
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: .init(x: 0, y: 0, width: 400, height: 300))
    return window
}

@MainActor @Test func mainWindowCommandsFollowSelectionHistoryInspectorAndAppearance() throws {
    let f = try keyboardFixtureStore(); defer { try? FileManager.default.removeItem(at: f.root) }
    let store = f.store, t = f.threads, probe = PresentationProbe()
    let suite = "coincide-keyboard-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let controller = MainWindowController(store: store)
    controller.presentations = probe.presentations(); controller.defaults = defaults
    controller.pasteboard = NSPasteboard(name: .init("coincide-keyboard-" + UUID().uuidString)); defer { controller.pasteboard.releaseGlobally() }
    // Without a selection, thread actions disable and traversal starts at the ends.
    for command: KeybindingCommand in [.chatFind, .threadCopyReference, .threadPin, .threadStop, .threadSettle, .navigationBack, .viewReopenClosed, .terminalToggle] {
        #expect(!controller.canPerform(command), "\(command)")
    }
    #expect(!controller.perform(.threadPin) && controller.canPerform(.threadNext) && controller.canPerform(.threadJumps[3]) && !controller.canPerform(.threadJumps[4]))
    #expect(controller.perform(.threadNext) && store.selectedThreadID == t["a-pinned"]!.id)
    controller.selectionChanged(to: store.selectedThreadID)
    #expect(controller.perform(.threadJumps[3]) && store.selectedThreadID == t["b-one"]!.id && store.selectedProjectID == f.projects[1].id)
    controller.selectionChanged(to: store.selectedThreadID)
    #expect(controller.perform(.threadPrevious) && store.selectedThreadID == t["a-old"]!.id)
    controller.selectionChanged(to: store.selectedThreadID)
    // Back and forward replay the visited threads without recording new visits.
    #expect(controller.perform(.navigationBack) && store.selectedThreadID == t["b-one"]!.id)
    controller.selectionChanged(to: store.selectedThreadID)
    #expect(controller.perform(.navigationBack) && store.selectedThreadID == t["a-pinned"]!.id)
    controller.selectionChanged(to: store.selectedThreadID)
    #expect(controller.perform(.navigationForward) && store.selectedThreadID == t["b-one"]!.id)
    controller.selectionChanged(to: store.selectedThreadID)
    #expect(controller.canPerform(.navigationForward) && controller.history.back == [t["a-pinned"]!.id])
    // Copy Thread ID writes the stable ID and confirms it.
    #expect(controller.perform(.threadCopyReference) && controller.pasteboard.string(forType: .string) == t["b-one"]!.id.uuidString.lowercased())
    #expect(controller.notice == "Copied thread ID")
    // Show Changes toggles the inspector on its Changes tab.
    #expect(controller.perform(.diffToggle) && store.inspectorVisible && controller.inspectorRequest?.tab == .changes)
    controller.consumeInspectorRequest(controller.inspectorRequest!.id)
    #expect(controller.inspectorRequest == nil && controller.perform(.diffToggle) && !store.inspectorVisible)
    // A hidden inspector view can be reopened with its thread selected again.
    controller.inspectorWillHide()
    store.selectThread(t["a-new"]!.id); controller.selectionChanged(to: store.selectedThreadID)
    #expect(controller.canPerform(.viewReopenClosed) && controller.perform(.viewReopenClosed))
    #expect(store.selectedThreadID == t["b-one"]!.id && store.inspectorVisible && controller.inspectorRequest?.tab == .changes && controller.closedViews.isEmpty)
    // Find opens for the selected thread and closes when the selection moves on.
    #expect(controller.perform(.chatFind) && controller.find?.threadID == t["b-one"]!.id)
    let find = try #require(controller.find); controller.openFind()
    #expect(controller.find === find && find.focusGeneration == 1)
    controller.selectionChanged(to: t["a-new"]!.id)
    #expect(controller.find == nil)
    // Palette and appearance commands.
    #expect(controller.perform(.commandPaletteToggle) && controller.palette != nil)
    #expect(controller.perform(.commandPaletteToggle) && controller.palette == nil)
    #expect(controller.perform(.themeSelect) && controller.palette?.breadcrumb == "Change Appearance")
    controller.closePalette(returnFocus: false)
    #expect(controller.perform(.appearanceCycle) && defaults.string(forKey: "appearance") == "light" && controller.notice == "Appearance: Light")
    // Presentations stay owned by the window's views.
    for command: KeybindingCommand in [.projectNew, .projectClone, .projectImport, .windowNew, .remoteOpen] { #expect(controller.perform(command)) }
    #expect(probe.calls == ["newProject", "clone", "import", "window", "remote"])
    #expect(controller.label(for: .commandPaletteToggle) == "⌘K")
}

@MainActor @Test func keyboardFocusClassificationAndTypeToFocusPredicate() {
    _ = NSApplication.shared
    let composer = NSTextView(), field = NSTextView(), editor = NSTextView(), readOnly = NSTextView(), other = NSTextView()
    field.isFieldEditor = true; editor.setAccessibilityLabel("File editor"); readOnly.isEditable = false
    let terminal = LocalTerminalSession(restoring: TerminalTabArchive(id: UUID(), threadID: UUID(), workspacePath: "/tmp", directory: "/tmp", title: "zsh", text: "", isCommand: false, exitCode: 0))
    let cases: [(NSResponder?, KeyboardFocusKind)] = [
        (composer, .composer), (field, .editableText), (editor, .fileEditor), (readOnly, .passive), (other, .editableText),
        (terminal.view, .terminal), (NSButton(), .interactive), (NSTableView(), .interactive), (NSView(), .passive), (nil, .passive),
    ]
    for (responder, kind) in cases { #expect(KeyboardFocusKind.classify(responder, composer: composer) == kind, "\(String(describing: responder))") }
    #expect(KeyboardFocusKind.composer.isEditable && !KeyboardFocusKind.terminal.isEditable)
    func redirect(_ characters: String?, _ focus: KeyboardFocusKind = .passive, sheet: Bool = false, overlay: Bool = false, command: Bool = false, control: Bool = false) -> Bool {
        TypeToFocus.shouldRedirect(focus: focus, hasSheet: sheet, overlayOpen: overlay, command: command, control: control, characters: characters)
    }
    #expect(redirect("a") && redirect("É") && redirect("v", command: true))
    #expect(!redirect("a", .editableText) && !redirect("a", .interactive) && !redirect("a", .terminal) && !redirect("a", sheet: true) && !redirect("a", overlay: true))
    #expect(!redirect("c", command: true) && !redirect("a", control: true) && !redirect("\u{F700}") && !redirect("\r") && !redirect("\u{1b}") && !redirect(" ") && !redirect(nil))
}

@MainActor @Test(.timeLimit(.minutes(1))) func keyboardDispatcherResolvesWindowContextsPaletteNumbersAndTypeToFocus() async throws {
    let f = try keyboardFixtureStore(); defer { try? FileManager.default.removeItem(at: f.root) }
    let root = f.root.appendingPathComponent("keys", isDirectory: true)
    let keybindings = KeybindingsStore(fileURL: root.appendingPathComponent("keybindings.json"), watch: false)
    await keybindings.start()
    let store = f.store, window = offscreenWindow(); defer { window.close() }
    let controller = MainWindowController(store: store, keybindings: keybindings)
    controller.presentations = PresentationProbe().presentations()
    let dispatcher = keybindings.dispatcher
    dispatcher.register(controller, window: window); defer { dispatcher.uninstall() }
    #expect(dispatcher.controller(for: window) === controller && controller.window === window)
    // ⌘K opens the palette; inside it ⌘K closes it again.
    #expect(dispatcher.handle(try keyEvent(window, keyCode: 40, "k", .command)) == nil && controller.palette != nil)
    #expect(dispatcher.handle(try keyEvent(window, keyCode: 40, "k", .command)) == nil && controller.palette == nil)
    // With the palette open, ⌘2 chooses its second entry instead of jumping threads.
    store.selectedThreadID = f.threads["a-pinned"]!.id
    controller.openPalette()
    let second = try #require(controller.palette?.selectableItems.dropFirst().first)
    #expect(second.id == "action:new-thread-in")
    #expect(dispatcher.handle(try keyEvent(window, keyCode: 19, "2", .command)) == nil && controller.palette?.breadcrumb == "New Thread In…")
    controller.closePalette(returnFocus: false)
    // ⌘2 then jumps to the second visible thread; auto-repeat of a toggle is consumed without acting.
    #expect(dispatcher.handle(try keyEvent(window, keyCode: 19, "2", .command)) == nil && store.selectedThreadID == f.threads["a-new"]!.id)
    #expect(dispatcher.handle(try keyEvent(window, keyCode: 40, "k", .command, repeat: true)) == nil && controller.palette == nil)
    // ⇧⌘] arrives as "}" and still moves to the next thread, including on repeat.
    #expect(dispatcher.handle(try keyEvent(window, keyCode: 30, "}", [.command, .shift], repeat: true)) == nil && store.selectedThreadID == f.threads["a-old"]!.id)
    // A terminal keeps ⌘K: the rule's condition is false, so the event passes through.
    let terminal = LocalTerminalSession(restoring: TerminalTabArchive(id: UUID(), threadID: UUID(), workspacePath: "/tmp", directory: "/tmp", title: "zsh", text: "", isCommand: false, exitCode: 0))
    terminal.view.frame = .init(x: 0, y: 0, width: 200, height: 100)
    window.contentView?.addSubview(terminal.view)
    #expect(window.makeFirstResponder(terminal.view) && window.firstResponder === terminal.view)
    #expect(dispatcher.context(for: controller, focus: .terminal)["terminalFocus"])
    let passed = try keyEvent(window, keyCode: 40, "k", .command)
    #expect(dispatcher.handle(passed) === passed && controller.palette == nil)
    // Typing with no editable target moves focus to the composer and keeps the key.
    terminal.view.removeFromSuperview(); window.makeFirstResponder(nil)
    let composer = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 40)); window.contentView?.addSubview(composer)
    ComposerEditorRegistry.register(composer); defer { ComposerEditorRegistry.unregister(composer) }
    let typed = try keyEvent(window, keyCode: 0, "a")
    #expect(dispatcher.handle(typed) === typed && window.firstResponder === composer)
    // Unregistered windows are ignored.
    let otherWindow = offscreenWindow(); defer { otherWindow.close() }
    let foreign = try keyEvent(otherWindow, keyCode: 40, "k", .command)
    #expect(dispatcher.handle(foreign) === foreign && controller.palette == nil)
    // Holding ⌘ shows jump hints after a short delay; releasing hides them at once.
    _ = dispatcher.handle(try keyEvent(window, keyCode: 55, "", .command, type: .flagsChanged))
    let deadline = ContinuousClock.now + .seconds(3)
    while !controller.jumpHintsVisible, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(controller.jumpHintsVisible && controller.jumpHint(for: f.threads["a-pinned"]!.id) == "⌘1" && controller.jumpHint(for: f.threads["b-one"]!.id) == "⌘4")
    _ = dispatcher.handle(try keyEvent(window, keyCode: 55, "", [], type: .flagsChanged))
    #expect(!controller.jumpHintsVisible && controller.jumpHint(for: f.threads["a-pinned"]!.id) == nil)
}

@MainActor @Test(.timeLimit(.minutes(1))) func keybindingsStoreWritesDefaultsSavesOverridesAndReportsReloadIssues() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-keybindings-store-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("keybindings.json")
    let keybindings = KeybindingsStore(fileURL: url, watch: false)
    await keybindings.start(); await keybindings.start()
    #expect(keybindings.isLoaded && FileManager.default.fileExists(atPath: url.path) && keybindings.keybindings == KeybindingDefaults.resolved)
    let palette = try #require(keybindings.menuShortcut(.commandPaletteToggle))
    #expect(palette.key == KeyEquivalent("k") && palette.modifiers == .command && keybindings.label(for: .threadNext) == "⇧⌘]")
    try await keybindings.save(.init(key: "mod+shift+k", command: .commandPaletteToggle), replacing: .init(key: "mod+k", command: .commandPaletteToggle, when: "!terminalFocus"))
    #expect(keybindings.label(for: .commandPaletteToggle) == "⇧⌘K" && keybindings.menuShortcut(.commandPaletteToggle)?.modifiers == [.command, .shift])
    try await keybindings.remove(.init(key: "mod+shift+k", command: .commandPaletteToggle))
    #expect(keybindings.label(for: .commandPaletteToggle) == "⌘K")
    try Data("[{ \"key\": \"mod+g\", \"command\": \"terminal.toggle\" }, { \"key\": \"mod+h\", \"command\": \"nope\" }]".utf8).write(to: url)
    await keybindings.reload()
    #expect(keybindings.warning == "Entry 2: Unknown command “nope”." && keybindings.label(for: .terminalToggle) == "⌘G" && keybindings.reloadNotice == nil)
    try Data("[{ \"key\": \"mod+g\", \"command\": \"terminal.toggle\" }]".utf8).write(to: url)
    await keybindings.reload()
    #expect(keybindings.warning == nil && keybindings.issues.isEmpty && keybindings.reloadNotice == "Keybindings updated")
    for (key, expected) in [("enter", KeyEquivalent.return), ("arrowup", .upArrow), ("escape", .escape), ("backspace", .delete), (" ", .space), ("[", KeyEquivalent("["))] {
        #expect(KeybindingsStore.keyEquivalent(key) == expected, "\(key)")
    }
    #expect(KeybindingsStore.keyEquivalent("f5") != nil && KeybindingsStore.keyEquivalent("bogus") == nil)
}

@MainActor @Test func keyboardSurfacesRenderWithinTheirPanelsInLightAndDark() async throws {
    let f = try keyboardFixtureStore(); defer { try? FileManager.default.removeItem(at: f.root) }
    let keybindings = KeybindingsStore(fileURL: f.root.appendingPathComponent("keys/keybindings.json"), watch: false)
    await keybindings.start()
    f.store.selectedThreadID = f.threads["a-pinned"]!.id
    let controller = MainWindowController(store: f.store, keybindings: keybindings)
    controller.openPalette()
    let palette = try #require(controller.palette)
    let find = ThreadFindModel(threadID: f.threads["a-pinned"]!.id, messages: f.threads["a-pinned"]!.visibleMessages); find.query = "café"
    for scheme in [ColorScheme.light, .dark] {
        let views: [(String, AnyView, CGFloat)] = [
            ("palette", AnyView(CommandPaletteView(model: palette, label: controller.label(for:))), 640),
            ("find", AnyView(ThreadFindBar(model: find, close: {})), 540),
            ("banner", AnyView(KeybindingsIssueBanner(message: "Entry 3: Unknown command “not.a.command”.", keybindings: keybindings)), 540),
            ("notice", AnyView(KeyboardNoticeHUD(text: "Copied thread ID")), 400),
            ("settings", AnyView(KeybindingsSettingsView(keybindings: keybindings).frame(width: 620, height: 460)), 640),
        ]
        for (name, view, width) in views {
            let hosting = NSHostingController(rootView: view.environment(\.colorScheme, scheme).environment(controller))
            let size = hosting.sizeThatFits(in: .init(width: width, height: 900))
            #expect(size.width > 0 && size.width <= width + 1 && size.height > 0 && size.height <= 900, "\(name) \(scheme): \(size)")
        }
    }
    // The whole window still fits its minimum size with the keyboard surface installed.
    let workspace = NSHostingController(rootView: ContentView(store: f.store).environment(keybindings).frame(minWidth: 900, minHeight: 600))
    #expect(workspace.sizeThatFits(in: CGSize(width: 900, height: 600)).width <= 900)
    let settings = NSHostingController(rootView: SettingsView(store: f.store).environment(keybindings))
    #expect(settings.sizeThatFits(in: CGSize(width: 700, height: 600)).width <= 700)
}

@MainActor @Test(.timeLimit(.minutes(1))) func closingOverlaysReturnFocusToTheComposerAndSidebarToggleFindsTheNativeSplit() async throws {
    let f = try keyboardFixtureStore(); defer { try? FileManager.default.removeItem(at: f.root) }
    let window = offscreenWindow(); defer { window.close() }
    let controller = MainWindowController(store: f.store); controller.window = window
    let composer = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 40)), search = NSTextView(frame: .init(x: 0, y: 60, width: 200, height: 40))
    window.contentView?.addSubview(composer); window.contentView?.addSubview(search)
    ComposerEditorRegistry.register(composer); defer { ComposerEditorRegistry.unregister(composer) }
    func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }
    // Escape from the palette: nothing else took focus, so the composer gets it back.
    controller.openPalette(); window.makeFirstResponder(nil)
    controller.closePalette(); try await settle()
    #expect(window.firstResponder === composer)
    // An action that focused another field keeps that focus.
    controller.openPalette(); window.makeFirstResponder(nil)
    controller.closePalette(); window.makeFirstResponder(search); try await settle()
    #expect(window.firstResponder === search)
    // ⌘B toggles the window's NavigationSplitView sidebar through its split controller.
    let sidebar = NSViewController(), detail = NSViewController(); sidebar.view = NSView(); detail.view = NSView()
    let split = NSSplitViewController()
    split.addSplitViewItem(NSSplitViewItem(sidebarWithViewController: sidebar)); split.addSplitViewItem(NSSplitViewItem(viewController: detail))
    let splitWindow = NSWindow(contentViewController: split); splitWindow.isReleasedWhenClosed = false; defer { splitWindow.close() }
    controller.window = splitWindow
    let before = split.splitViewItems[0].isCollapsed
    #expect(controller.perform(.sidebarToggle))
    let deadline = ContinuousClock.now + .seconds(3)
    while split.splitViewItems[0].isCollapsed == before, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(split.splitViewItems[0].isCollapsed != before)
}
