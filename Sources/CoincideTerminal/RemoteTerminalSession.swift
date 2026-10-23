import AppKit
import CoincideCore
import Foundation
import Observation
import SwiftTerm

/// A terminal emulator only: this type cannot launch a shell, PTY, or process.
/// The remote store owns transport ordering and lifecycle outside the NSView.
@MainActor @Observable
public final class RemoteTerminalSession: Identifiable, TerminalViewDelegate {
    public let id: UUID
    public private(set) var title = "Remote Terminal"
    public private(set) var isInteractive = false
    public private(set) var displayGeneration = UUID()
    public private(set) var cols = 80
    public private(set) var rows = 24
    @ObservationIgnored public var onInput: (@MainActor (Data) -> Void)?
    @ObservationIgnored public var onResize: (@MainActor (Int, Int) -> Void)?
    @ObservationIgnored private var terminalView: RemoteDisplayTerminalView?
    @ObservationIgnored private var output = Data()
    @ObservationIgnored private var appearance: TerminalAppearance?
    @ObservationIgnored private var appliedAppearance: (TerminalAppearance, Bool, Bool)?
    public static let transcriptByteLimit = 262_144

    public init(id: UUID = UUID()) { self.id = id }

    /// Lazily creating the renderer never opens a remote session. Prior output
    /// is restored as inert text, with OSC/CSI/query bytes removed beforehand.
    public var view: TerminalView {
        if let terminalView { return terminalView }
        var options = TerminalOptions(); options.scrollback = 5_000
        let view = RemoteDisplayTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 260),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular), options: options)
        view.nativeForegroundColor = .textColor; view.nativeBackgroundColor = .textBackgroundColor
        view.terminalDelegate = self
        view.remoteInputEnabled = isInteractive; view.allowMouseReporting = isInteractive
        view.setAccessibilityLabel("Remote workspace terminal")
        terminalView = view
        view.appearanceChanged = { [weak self] in self?.appliedAppearance = nil; if let appearance = self?.appearance { self?.apply(appearance) } }
        if let appearance { appliedAppearance = nil; apply(appearance) }
        view.feed(text: Self.inertText(output).replacingOccurrences(of: "\n", with: "\r\n"))
        return view
    }

    public var transcriptText: String { Self.inertText(output) }
    public var visibleText: String {
        guard let terminalView else { return transcriptText }
        return terminalView.visibleRowsText(0..<terminalView.terminalDimensions.rows).joined(separator: "\n")
    }
    public var hasCreatedView: Bool { terminalView != nil }

    public func setInteractive(_ enabled: Bool) {
        isInteractive = enabled
        terminalView?.remoteInputEnabled = enabled; terminalView?.allowMouseReporting = enabled
    }

    /// Binary live output preserves VT formatting. A gap/reset starts a fresh
    /// emulator with inert retained bytes, never replays terminal automation.
    public func acceptOutput(_ bytes: Data, reset: Bool = false, inert: Bool = false) {
        if reset { setInteractive(false); output = Data(); replaceView() }
        output.append(bytes)
        if output.count > Self.transcriptByteLimit { output.removeFirst(output.count - Self.transcriptByteLimit) }
        guard let terminalView else { return }
        if inert { terminalView.feed(text: Self.inertText(bytes).replacingOccurrences(of: "\n", with: "\r\n")) }
        else { terminalView.feed(byteArray: Array(bytes)[...]) }
    }

    public func prepareForReplay() {
        setInteractive(false)
        replaceView()
    }

    public func showFind() {
        let item = NSMenuItem(); item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        view.performTextFinderAction(item)
    }
    public func setFontSize(_ size: Double) {
        var next = appearance ?? .init(); next.fontSize = TerminalAppearance.clampedSize(size); apply(next)
    }
    /// Shares the local terminal font and colors; the remote PTY is not restarted.
    public func apply(_ appearance: TerminalAppearance) {
        self.appearance = appearance
        let view = view
        let key = (appearance, appearance.isDark(appearance: view.effectiveAppearance), NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        if let appliedAppearance, appliedAppearance == key { return }
        appliedAppearance = key
        appearance.apply(to: view)
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard source === terminalView else { return }
        let columns = min(500, max(2, newCols)), lines = min(500, max(2, newRows))
        guard columns != cols || lines != rows else { return }
        cols = columns; rows = lines
        if isInteractive { onResize?(columns, lines) }
    }
    public func setTerminalTitle(source: TerminalView, title: String) {
        guard source === terminalView else { return }
        let safe = title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        self.title = safe.isEmpty ? "Remote Terminal" : String(String.UnicodeScalarView(safe).prefix(120))
    }
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard source === terminalView, isInteractive, !data.isEmpty else { return }
        onInput?(Data(data))
    }
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { }
    public func scrolled(source: TerminalView, position: Double) { }
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) { }
    public func bell(source: TerminalView) { }
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { }
    public func clipboardCopy(source: TerminalView, content: Data) { }
    public func clipboardRead(source: TerminalView) -> Data? { nil }
    public func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }
    public func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { .denied }
    public func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult { .denied }
    public func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }

    private static func inertText(_ data: Data) -> String { TerminalTabArchive.displayText(String(decoding: data, as: UTF8.self)) }
    private func replaceView() {
        terminalView?.terminalDelegate = nil; terminalView?.appearanceChanged = nil
        terminalView = nil; appliedAppearance = nil; displayGeneration = UUID()
    }
}

private final class RemoteDisplayTerminalView: TerminalView {
    var remoteInputEnabled = false
    var appearanceChanged: (@MainActor () -> Void)?
    override func paste(_ sender: Any) { if remoteInputEnabled { super.paste(sender) } }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }
    /// Display-only actions; remote links and terminal commands stay with the host adapter.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: String(localized: "Remote Terminal"))
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, _ key: String, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; item.isEnabled = enabled; menu.addItem(item)
        }
        add(String(localized: "Copy"), #selector(copySelection(_:)), "c", enabled: selectionActive)
        add(String(localized: "Paste"), #selector(pasteInput(_:)), "v", enabled: remoteInputEnabled)
        add(String(localized: "Select All"), #selector(selectEverything(_:)), "a")
        add(String(localized: "Jump to Latest"), #selector(jumpToLatest(_:)), "")
        add(String(localized: "Find…"), #selector(showFindBar(_:)), "f")
        return menu
    }
    @objc private func copySelection(_ sender: Any?) { copy(self) }
    @objc private func pasteInput(_ sender: Any?) { paste(self) }
    @objc private func selectEverything(_ sender: Any?) { selectAll(nil) }
    @objc private func jumpToLatest(_ sender: Any?) { scroll(toPosition: 1) }
    @objc private func showFindBar(_ sender: Any?) {
        let item = NSMenuItem(); item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        performTextFinderAction(item)
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityValue() -> Any? { visibleRowsText(0..<terminalDimensions.rows).joined(separator: "\n") }
    override func accessibilityPerformPress() -> Bool {
        guard let window else { return false }
        return window.makeFirstResponder(self)
    }
}
