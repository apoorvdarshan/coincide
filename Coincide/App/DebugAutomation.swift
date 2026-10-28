#if DEBUG
import AppKit
import CoincideKit

/// Debug-only scripted driver for end-to-end checks without touching the keyboard or mouse.
///
/// Launch with `COINCIDE_AUTOMATION=/path/script.json` (a JSON array of steps) and the app runs the
/// steps against real providers, writing progress to `<script>.log`. Steps:
/// - `{"newThread": {"project": "name", "provider": "claude", "model": "haiku", "effort": "low"}}`
/// - `{"select": {"provider": "codex", "model": "gpt-6-luna", "effort": "low"}}`
/// - `{"access": "approval" | "fullAccess"}`, `{"mode": "plan" | "build"}`
/// - `{"send": "text"}`
/// - `{"waitIdle": seconds}`: waits until the turn ends
/// - `{"approve": "allow"}`: answers the latest pending approval with the option of that kind or id
/// - `{"openThread": "title"}`: opens an existing thread
/// - `{"request": "approval" | "question"}`: adds a sample request waiting for an answer, to check how it looks
/// - `{"toggle": "sidebar" | "terminal" | "diff"}`, `{"appearance": "light" | "dark" | "system"}`
/// - `{"settings": "general" | "providers" | "models" | "keyboard" | "about"}`: opens the settings window
/// - `{"find": "text"}`: opens the find bar searching for the text; `{"findNext": 2}`, `{"findPrevious": 1}`,
///   `{"closeFind": true}`
/// - `{"palette": {"query": "model", "enter": true, "file": "/path.png"}}`: lays out the command palette for a
///   query (optionally running the chosen result, which opens a nested list) and draws it into a PNG, offscreen
/// - `{"snapshot": "/path.png"}`: draws the main window's content into a PNG
/// - `{"sleep": seconds}`, `{"log": "text"}`, `{"quit": true}`
enum DebugAutomation {
    static func startIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["COINCIDE_AUTOMATION"], !path.isEmpty else { return }
        Task { await run(scriptAt: URL(fileURLWithPath: path)) }
    }

    private static func run(scriptAt url: URL) async {
        let logURL = url.appendingPathExtension("log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        func log(_ text: String) {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        }
        guard let data = try? Data(contentsOf: url), let steps = JSONValue.parse(data)?.array else {
            log("error: cannot read script")
            return
        }
        let store = AppStore.shared
        let registry = ProviderRegistry.shared
        let runner = ThreadRunner.shared
        await registry.refresh()
        while registry.isRefreshing { try? await Task.sleep(for: .milliseconds(200)) }
        log("providers: " + registry.orderedKinds.map { "\($0.rawValue)=\(registry.status($0).state.rawValue)" }.joined(separator: " "))
        var threadID: UUID?

        func selection(_ spec: JSONValue) -> ModelSelection? {
            guard let raw = spec["provider"]?.string, let kind = ProviderKind(rawValue: raw) else { return nil }
            let models = registry.models(for: kind)
            let wanted = spec["model"]?.string
            let model = models.first { $0.modelID == wanted } ?? models.first { $0.modelID.contains(wanted ?? "\u{0}") }
            let modelID = model?.modelID ?? wanted ?? "default"
            return ModelSelection(provider: kind, modelID: modelID, effort: spec["effort"]?.string ?? model?.defaultEffort)
        }

        for step in steps {
            guard let (name, value) = step.object?.first else { continue }
            log("step \(name): \(value.compactJSON)")
            switch name {
            case "newThread":
                let projectName = value["project"]?.string
                guard let project = store.projects.first(where: { $0.name == projectName }) ?? store.projects.first else {
                    log("error: no project")
                    return
                }
                let thread = store.createThread(in: project.id, selection: selection(value))
                threadID = thread.id
                AppEvents.openThread(thread.id)
                log("thread \(thread.id) selection \(thread.selection)")
            case "openThread":
                guard let thread = store.recentThreads.first(where: { $0.title == value.string }) else {
                    log("no thread named \(value.displayText)")
                    continue
                }
                threadID = thread.id
                AppEvents.openThread(thread.id)
            case "request":
                guard let threadID else { continue }
                store.append(sampleRequest(value.string ?? "approval"), to: threadID)
            case "toggle":
                let window = NSApp.windows.compactMap { $0.windowController as? MainWindowController }.first
                switch value.string {
                case "sidebar": window?.toggleSidebarPanel(nil)
                case "terminal": window?.toggleTerminalPanel(nil)
                case "diff": window?.toggleDiffPanel(nil)
                default: log("unknown panel \(value.displayText)")
                }
            case "settings":
                AppEvents.showSettings(section: value.string.flatMap(SettingsSection.init(rawValue:)))
            case "appearance":
                guard let mode = value.string.flatMap(AppearanceMode.init(rawValue:)) else { continue }
                store.updateSettings { $0.appearance = mode }
            case "select":
                guard let threadID, let selection = selection(value) else { continue }
                store.updateThread(threadID) { $0.selection = selection }
                log("selected \(selection)")
            case "access":
                guard let threadID, let mode = value.string.flatMap(AccessMode.init(rawValue:)) else { continue }
                store.updateThread(threadID) { $0.accessMode = mode }
            case "mode":
                guard let threadID, let mode = value.string.flatMap(InteractionMode.init(rawValue:)) else { continue }
                store.updateThread(threadID) { $0.interactionMode = mode }
            case "send":
                guard let threadID, let text = value.string else { continue }
                Task { await runner.send(threadID: threadID, text: text) }
                try? await Task.sleep(for: .milliseconds(500))
            case "waitIdle":
                guard let threadID else { continue }
                let deadline = Date().addingTimeInterval(value.number ?? 120)
                while runner.isRunning(threadID), Date() < deadline {
                    if !runner.pendingApprovals(threadID).isEmpty || !runner.pendingQuestions(threadID).isEmpty { break }
                    try? await Task.sleep(for: .milliseconds(300))
                }
                let items = store.thread(threadID)?.items ?? []
                log("idle=\(!runner.isRunning(threadID)) items=\(items.count) last=\(items.last.map { "\($0.kind.rawValue): \($0.text.prefix(200))" } ?? "-")")
            case "approve":
                guard let threadID, let item = runner.pendingApprovals(threadID).last, let approval = item.approval else {
                    log("no pending approval")
                    continue
                }
                let wanted = value.string ?? "allow"
                let option =
                    approval.options.first { $0.id == wanted }
                    ?? approval.options.first { $0.kind == (wanted == "deny" ? .deny : .allowOnce) }
                if let option { runner.respond(threadID: threadID, itemID: item.id, optionID: option.id) }
                log("answered approval with \(option?.label ?? "nothing")")
            case "find":
                guard let chat = mainWindow?.splitController.content.chat, let text = value.string else { continue }
                chat.find(text)
            case "findNext", "findPrevious":
                guard let chat = mainWindow?.splitController.content.chat else { continue }
                for _ in 0..<max(1, value.int ?? 1) {
                    if name == "findNext" { chat.findNext() } else { chat.findPrevious() }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            case "closeFind":
                mainWindow?.splitController.content.chat.closeFindBar()
            case "palette":
                guard let window = mainWindow, let query = value["query"]?.string, let file = value["file"]?.string else { continue }
                drawPalette(for: window, query: query, enter: value["enter"]?.bool ?? false, to: URL(fileURLWithPath: file))
            case "snapshot":
                guard let content = mainWindow?.window?.contentView, let file = value.string else { continue }
                draw(content, to: URL(fileURLWithPath: file))
            case "zoom":
                guard let window = mainWindow?.window else { continue }
                window.zoom(nil)
                try? await Task.sleep(for: .milliseconds(600))
                log("zoomed=\(window.isZoomed) frame=\(NSStringFromRect(window.frame)) visible=\(NSStringFromRect(window.screen?.visibleFrame ?? .zero))")
            case "sleep":
                try? await Task.sleep(for: .seconds(value.number ?? 1))
            case "log":
                log(value.displayText)
            case "quit":
                store.flush()
                log("quit")
                NSApp.terminate(nil)
            default:
                log("unknown step \(name)")
            }
        }
        store.flush()
        log("done")
    }

    private static var mainWindow: MainWindowController? {
        NSApp.windows.compactMap { $0.windowController as? MainWindowController }.first
    }

    /// Draws a view hierarchy into a PNG, as it would look on screen (glass is left out).
    private static func draw(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The command palette's list for a query, laid out offscreen the way the palette panel shows it.
    private static func drawPalette(for window: MainWindowController, query: String, enter: Bool, to url: URL) {
        let palette = PaletteViewController()
        palette.windowController = window
        palette.reset()
        let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        backdrop.appearance = window.window?.effectiveAppearance
        palette.view.frame = backdrop.bounds
        backdrop.addSubview(palette.view)
        guard let field = editableField(in: palette.view) else { return }
        func typeQuery(_ text: String) {
            field.stringValue = text
            palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        typeQuery(query)
        if enter {
            _ = palette.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        }
        backdrop.frame.size.height = palette.preferredHeight
        palette.view.frame = backdrop.bounds
        draw(backdrop, to: url)
    }

    private static func editableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = editableField(in: subview) { return field }
        }
        return nil
    }

    private static func sampleRequest(_ kind: String) -> TranscriptItem {
        if kind == "question" {
            let question = UserQuestion(
                id: "q1", header: "Database", prompt: "Which database should the sample app use?",
                options: [
                    .init(label: "SQLite", detail: "A file next to the app"), .init(label: "Postgres", detail: "Needs a server"),
                ])
            return TranscriptItem(
                kind: .question, status: .waiting, provider: .claude,
                questions: UserInputRequest(id: "r1", title: "Pick a database", questions: [question]))
        }
        return TranscriptItem(
            kind: .approval, title: "Run `rm -rf .build && swift build`", detail: "rm -rf .build && swift build -c release",
            category: .command, status: .waiting, provider: .claude,
            approval: ApprovalInfo(
                requestID: "a1",
                options: [
                    ApprovalOption(id: "allow", label: "Allow", kind: .allowOnce),
                    ApprovalOption(id: "always", label: "Always Allow", kind: .allowAlways),
                    ApprovalOption(id: "deny", label: "Deny", kind: .deny),
                ]))
    }
}
#endif
