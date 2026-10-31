import AppKit
import CoincideKit
import Metal
import Testing

@testable import Coincide

/// The terminal on SwiftTerm 1.99: GPU rendering (Settings › General), the OSC 52 block, output notices from the I/O
/// thread, typing while no shell runs, and line numbers for selected output. Windows are borderless, offscreen and
/// transparent, and never ordered in.
@MainActor
@Suite(.serialized)
struct TerminalRenderingTests {
    private static func offscreenWindow(holding view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 320), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        window.contentView = view
        return window
    }

    private static func withGPUPreference<T>(_ preference: @escaping () -> Bool, _ body: () throws -> T) rethrows -> T {
        let saved = ShellTerminalView.prefersGPURendering
        ShellTerminalView.prefersGPURendering = preference
        defer { ShellTerminalView.prefersGPURendering = saved }
        return try body()
    }

    // MARK: Setting

    @Test func gpuRenderingIsOnByDefaultAndSurvivesUnreadableValues() throws {
        #expect(AppSettings().terminalGPURendering)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize": 15}"#.utf8)).terminalGPURendering)
        for value in ["null", "3", #""no""#, "[]"] {
            let settings = try JSONDecoder().decode(
                AppSettings.self, from: Data(#"{"terminalGPURendering": \#(value), "fontSize": 15}"#.utf8))
            #expect(settings.terminalGPURendering, "\(value) turned it off")
            #expect(settings.fontSize == 15)
        }
        var off = AppSettings()
        off.terminalGPURendering = false
        let saved = try JSONEncoder().encode(off)
        #expect(try !JSONDecoder().decode(AppSettings.self, from: saved).terminalGPURendering)
    }

    @Test func restoreDefaultsTurnsGPURenderingBackOn() {
        var settings = AppSettings()
        settings.terminalGPURendering = false
        GeneralSettingsView.restoreDefaults(in: &settings)
        #expect(settings.terminalGPURendering)
    }

    @Test func settingsSearchFindsGPURendering() throws {
        let entries = SettingsSearchResults.entries(kinds: [])
        for query in ["GPU", "metal", "gpu rendering"] {
            #expect(entries.contains { $0.setting == .terminalGPURendering && $0.matches(query) }, "\(query) doesn't find it")
        }
        let entry = try #require(entries.first { $0.setting == .terminalGPURendering })
        #expect(entry.pane == .section(.general))
    }

    // MARK: Renderer

    @Test func metalStartsOnlyInAWindowAndFollowsTheSetting() {
        let hasMetal = MTLCreateSystemDefaultDevice() != nil
        var prefersGPU = true
        Self.withGPUPreference({ prefersGPU }) {
            let terminal = ShellTerminalView(font: Theme.monoFont)
            terminal.updateRenderer()
            #expect(!terminal.isUsingMetalRenderer, "Metal started before the view was in a window")

            let window = Self.offscreenWindow(holding: terminal)
            defer { window.close() }
            #expect(terminal.isUsingMetalRenderer == hasMetal)

            prefersGPU = false
            terminal.updateRenderer()
            #expect(!terminal.isUsingMetalRenderer)

            prefersGPU = true
            terminal.updateRenderer()
            #expect(terminal.isUsingMetalRenderer == hasMetal)
        }
    }

    @Test func turningTheSettingOffSwitchesOpenTerminalsToCoreGraphics() throws {
        let saved = AppStore.shared.settings.terminalGPURendering
        defer { AppStore.shared.updateSettings { $0.terminalGPURendering = saved } }
        AppStore.shared.updateSettings { $0.terminalGPURendering = true }
        let terminal = ShellTerminalView(font: Theme.monoFont)
        let window = Self.offscreenWindow(holding: terminal)
        defer { window.close() }
        try #require(MTLCreateSystemDefaultDevice() != nil, "no Metal device on this Mac")
        #expect(terminal.isUsingMetalRenderer)
        AppStore.shared.updateSettings { $0.terminalGPURendering = false }
        #expect(!terminal.isUsingMetalRenderer)
        AppStore.shared.updateSettings { $0.terminalGPURendering = true }
        #expect(terminal.isUsingMetalRenderer)
    }

    // MARK: Clipboard, bell

    @Test func osc52CannotWriteOrReadTheClipboard() throws {
        let terminal = ShellTerminalView(font: Theme.monoFont)
        let delegate = try #require(terminal.terminalDelegate)
        #expect(delegate is ShellTerminalDelegate)
        let before = NSPasteboard.general.changeCount
        delegate.clipboardCopy(source: terminal, content: Data("from a remote host".utf8))
        #expect(NSPasteboard.general.changeCount == before)
        #expect(delegate.clipboardRead(source: terminal) == nil)
    }

    @Test func aTerminalOutsideAWindowStaysSilent() {
        let terminal = ShellTerminalView(font: Theme.monoFont)
        #expect(!terminal.canRingBell)
        let window = Self.offscreenWindow(holding: terminal)
        defer { window.close() }
        #expect(terminal.canRingBell)
        terminal.isHidden = true
        #expect(!terminal.canRingBell)
    }

    // MARK: Output and input

    @Test func outputNoticesArriveOnTheMainThreadOnceABurstIsDrained() async {
        final class Counter {
            var calls = 0
        }
        let counter = Counter()
        let signal = OutputSignal()
        DispatchQueue.global().sync {
            for _ in 0..<500 { signal.post { counter.calls += 1 } }
        }
        #expect(counter.calls == 0, "a notice ran before the main thread was free")
        for _ in 0..<20 where counter.calls == 0 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(counter.calls == 1)
        DispatchQueue.global().sync { signal.post { counter.calls += 1 } }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(counter.calls == 2)
    }

    @Test func shellOutputReachesTheSession() async throws {
        let terminal = ShellTerminalView(font: Theme.monoFont)
        var outputs = 0
        terminal.onOutput = { outputs += 1 }
        terminal.startProcess(executable: "/bin/echo", args: ["coincide"], environment: ["PATH=/usr/bin:/bin"])
        for _ in 0..<100 where outputs == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(outputs > 0)
        terminal.terminate()
    }

    private static func key(_ characters: String, keyCode: UInt16 = 0, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    @Test func typingWhileNoShellRunsReachesTheSession() {
        let terminal = ShellTerminalView(font: Theme.monoFont)
        var received: [UInt8] = []
        terminal.onInputWhileStopped = { received.append(contentsOf: $0) }
        #expect(terminal.handleKeyDown(Self.key("l")))
        #expect(terminal.handleKeyDown(Self.key("\r", keyCode: 36)))
        #expect(received == Array("l\r".utf8))
        // Arrows and shortcuts are not typing.
        #expect(!terminal.handleKeyDown(Self.key("\u{F700}", keyCode: 126)))
        #expect(!terminal.handleKeyDown(Self.key("p", flags: .control)))
        #expect(received == Array("l\r".utf8))
    }

    @Test func typedBytesSkipFunctionKeys() {
        #expect(ShellTerminalView.typedBytes(Self.key("é")) == Array("é".utf8))
        #expect(ShellTerminalView.typedBytes(Self.key("\u{F703}", keyCode: 124)) == nil)
        #expect(ShellTerminalView.typedBytes(Self.key("")) == nil)
    }

    // MARK: Selected lines

    @Test func selectedOutputIsFoundInTheBufferWhenItIsUnambiguous() {
        let buffer = "$ swift test\nBuilding…\nerror: boom\n  at App.swift:4\n$ \n"
        #expect(TerminalSelectionRows.locate("error: boom\n  at App.swift:4", in: buffer) == 2...3)
        // Partial first and last lines.
        #expect(TerminalSelectionRows.locate("ror: boom\n  at App", in: buffer) == 2...3)
        // Blank lines it starts with count, as MessageContext drops them and shifts the numbers itself.
        #expect(TerminalSelectionRows.locate("\nerror: boom", in: buffer) == 1...2)
        #expect(TerminalSelectionRows.locate("Building…", in: buffer) == 1...1)
    }

    @Test func ambiguousOrMissingSelectionsHaveNoLineNumbers() {
        let buffer = "$ ls\nREADME.md\n$ ls\nREADME.md\n"
        #expect(TerminalSelectionRows.locate("$ ls\nREADME.md", in: buffer) == nil)
        #expect(TerminalSelectionRows.locate("not there", in: buffer) == nil)
        #expect(TerminalSelectionRows.locate("   \n", in: buffer) == nil)
        // A line the terminal wrapped spans two rows that neither ends nor starts it.
        #expect(TerminalSelectionRows.locate("a long line that wrapped", in: "a long line th\nat wrapped\n") == nil)
    }
}
