import AppKit
import CoincideKit
import Testing
@testable import Coincide

@MainActor @Suite(.serialized)
struct ComposerProviderCompletionTests {
    private final class Provider: AgentProvider {
        let kind: ProviderKind
        let executableNames = ["sh"]
        let setupHint = ""
        init(_ kind: ProviderKind) { self.kind = kind }
        func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus { .init(state: .ready) }
        func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] { [] }
        func makeSession(_ launch: AgentLaunch) -> AgentSession { fatalError("The picker must not start a turn") }
        func commands(executable: URL, environment: [String: String], directory: URL) async -> [ProviderCommand]? {
            try? await Task.sleep(for: .milliseconds(20))
            return [ProviderCommand(name: "deploy", kind: .skill, path: directory.appendingPathComponent("SKILL.md").path,
                isSlashCommand: kind != .codex)]
        }
    }

    private func textView(in root: NSView) -> ComposerTextView? {
        if let field = root as? ComposerTextView { return field }
        for child in root.subviews { if let field = textView(in: child) { return field } }
        return nil
    }

    @Test(arguments: ProviderKind.allCases)
    func anAlreadyTypedSkillRefreshesWhenTheProviderCatalogArrives(kind: ProviderKind) async throws {
        let folder = TemporaryDirectory("composer-commands")
        let store = AppStore(directory: folder.url)
        let provider = Provider(kind)
        let registry = ProviderRegistry(store: store, providers: [provider])
        await registry.refresh()
        let runner = ThreadRunner(store: store, registry: registry)
        let project = store.addProject(at: folder.url)
        let thread = store.createThread(in: project.id, selection: ModelSelection(provider: kind, modelID: "default"))
        let composer = ComposerViewController(store: store, registry: registry, runner: runner)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = composer.view
        window.orderBack(nil)
        defer { composer.suggestions.hide(); window.orderOut(nil) }
        composer.threadID = thread.id
        let field = try #require(textView(in: composer.view))
        window.makeFirstResponder(field)
        field.string = "$"
        field.setSelectedRange(NSRange(location: 1, length: 0))
        composer.textDidChange(Notification(name: NSText.didChangeNotification, object: field))
        for _ in 0..<200 {
            if composer.suggestions.items.contains(where: {
                if case .agentCommand(let command, _, let token) = $0 { return command.name == "deploy" && token == "$" }
                return false
            }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The already typed $ did not refresh for \(kind.rawValue)")
    }

    /// A list that arrives after its window left the screen, such as commands or pull requests that took a while,
    /// stays hidden: ordering it in would bring the window back with it.
    @Test func aListThatArrivesAfterItsWindowLeftTheScreenStaysHidden() {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 60))
        window.contentView?.addSubview(anchor)
        let suggestions = ComposerSuggestionPanel()
        window.orderBack(nil)
        defer { suggestions.hide(); window.orderOut(nil) }
        suggestions.show([], emptyText: "Loading…", listLabel: "Commands", above: anchor)
        #expect(suggestions.isVisible)
        suggestions.hide()
        window.orderOut(nil)
        suggestions.show([], emptyText: "No matching files or folders.", listLabel: "Files and folders", above: anchor)
        #expect(!suggestions.isVisible)
        #expect(!window.isVisible)
        #expect(window.childWindows?.isEmpty ?? true)
    }
}
