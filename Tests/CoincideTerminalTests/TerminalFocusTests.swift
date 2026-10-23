import AppKit
import CoincideCore
import CoincideTerminal
import Testing

@MainActor private func focusWindow() -> (NSWindow, NSTextView) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = NSView(frame: .init(x: 0, y: 0, width: 500, height: 300)); window.contentView = content
    let composer = NSTextView(frame: .init(x: 0, y: 250, width: 500, height: 40)); content.addSubview(composer)
    return (window, composer)
}
@MainActor private func restoredTerminal() -> LocalTerminalSession {
    let session = LocalTerminalSession(restoring: TerminalTabArchive(id: UUID(), threadID: UUID(), workspacePath: "/tmp", directory: "/tmp",
                                                                     title: "zsh", text: "saved output", isCommand: false, exitCode: 0))
    session.view.frame = .init(x: 0, y: 0, width: 500, height: 200)
    return session
}

/// T3 keyboard focus: restoring or switching threads never moves focus into a
/// terminal; an explicit open focuses it unless the user returned to typing.
@MainActor @Test func terminalsTakeFocusOnlyForExplicitRequestsAndRespectReturningToTyping() {
    let (window, composer) = focusWindow(); defer { window.close() }
    #expect(window.makeFirstResponder(composer))
    let restored = restoredTerminal()
    window.contentView?.addSubview(restored.view)
    #expect(window.firstResponder === composer && !LocalTerminalSession.isTerminalResponder(composer))
    restored.view.removeFromSuperview()

    let opened = restoredTerminal()
    opened.requestFocus(from: composer)
    window.contentView?.addSubview(opened.view)
    #expect(window.firstResponder === opened.view && LocalTerminalSession.isTerminalResponder(window.firstResponder))
    // Already attached: an explicit tab switch focuses at once.
    #expect(window.makeFirstResponder(composer))
    opened.requestFocus()
    #expect(window.firstResponder === opened.view)
    opened.view.removeFromSuperview()

    // The user typed into another field while the terminal was starting.
    let other = NSTextView(frame: .init(x: 0, y: 200, width: 500, height: 40)); window.contentView?.addSubview(other)
    #expect(window.makeFirstResponder(composer))
    let starting = restoredTerminal()
    starting.requestFocus(from: composer)
    #expect(window.makeFirstResponder(other))
    window.contentView?.addSubview(starting.view)
    #expect(window.firstResponder === other)
    // Without a known origin (no key window), an explicit open still focuses.
    starting.view.removeFromSuperview()
    let unknown = restoredTerminal()
    unknown.requestFocus(from: nil)
    window.contentView?.addSubview(unknown.view)
    #expect(window.firstResponder === unknown.view)
}

@MainActor @Test
func failedTerminalResumeCannotLaunchIntoAReplacementCheckoutOrStealComposerFocus() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-terminal-focus-\(UUID())").resolvingSymlinksInPath()
    let checkout = root.appendingPathComponent("checkout")
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let thread = CodingThread(project: .init(path: checkout.path))
    let identity = try TerminalWorkspaceIdentity.capture(thread: thread)
    let session = LocalTerminalSession(restoring: .init(id: UUID(), threadID: thread.id, workspacePath: checkout.path,
        directory: checkout.path, title: "Saved", text: "PRESERVED_CHECKOUT_OUTPUT", isCommand: false, exitCode: nil,
        workspaceIdentity: identity))
    let (window, composer) = focusWindow(); defer { window.close() }
    window.contentView?.addSubview(session.view)
    #expect(window.makeFirstResponder(composer))
    try FileManager.default.moveItem(at: checkout, to: root.appendingPathComponent("original-checkout"))
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    #expect(throws: (any Error).self) { try session.resumeShell(executable: "/bin/sh", arguments: []) }
    #expect(session.processID == 0 && session.isRestored && !identity.matches(thread: thread))
    #expect(session.visibleText.contains("PRESERVED_CHECKOUT_OUTPUT") && window.firstResponder === composer)
}
