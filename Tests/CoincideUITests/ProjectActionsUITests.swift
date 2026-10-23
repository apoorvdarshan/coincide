import AppKit
import CoincideCore
import CoincideTerminal
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import Coincide

@MainActor private func waitActionsUI(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The project actions fixture did not settle.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor private struct ProjectActionsFixture {
    let root: URL, checkout: URL
    let project: WorkspaceProject, thread: CodingThread
    let store: WorkspaceStore, terminals: TerminalWorkspaceStore
    static func make(fileScripts: [[String: Any]] = [["name": "File dev", "command": "printf 'FILE_OK\\n'"]]) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-actions-ui-\(UUID())").resolvingSymlinksInPath()
        let checkout = root.appendingPathComponent("Project ' actions")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["scripts": fileScripts, "worktreeSubmodules": "top-level", "defaultThreadEnvMode": "worktree"])
            .write(to: checkout.appendingPathComponent("t3.json"))
        let project = WorkspaceProject(path: checkout.path), thread = CodingThread(project: project)
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        let database = root.appendingPathComponent("workspace.sqlite")
        _ = try await WorkspaceDatabase(url: database).commit(snapshot, event: "fixture", commandID: UUID())
        let engine = try WorkspaceEngine(url: database, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine)
        await store.load()
        let terminals = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false); store.registerTerminals(terminals)
        return .init(root: root, checkout: checkout, project: project, thread: thread, store: store, terminals: terminals)
    }
    func cleanup() async { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func projectActionsRunDirectlyWithTheirDisplayedDigestAndRejectLaterEdits() async throws {
    let f = try await ProjectActionsFixture.make()
    do {
        let settings = f.store.projectSettings
        #expect(settings.root == ProjectSettingsFiles.root(dataRoot: f.root))
        let fileContext = try await f.store.projectScripts().load(for: f.thread)
        #expect(fileContext.catalog.origin == .checkoutFile && fileContext.catalog.scripts.map(\.script.name) == ["File dev"])
        try await settings.update(f.project) { $0.actions = try ProjectActions.adding(.init(name: "App dev", command: "printf '%s' \"$T3CODE_PROJECT_ROOT\" > action-root.txt; printf 'APP_ACTION_OK\\n'"), to: []) }
        let action = try #require(settings.document(for: f.project).actions?.first)
        let context = try await f.store.projectScripts().load(for: f.thread)
        #expect(context.catalog.origin == .projectActions && context.catalog.importable.map(\.name) == ["File dev"])
        let session = try await f.store.projectScripts().run(action, thread: f.thread, in: f.terminals)
        try await waitActionsUI { if case .exited = session.lifecycle { true } else { false } }
        #expect(session.title == "App dev" && session.lifecycle == .exited(0) && session.visibleText.contains("APP_ACTION_OK"))
        #expect(try String(contentsOf: f.checkout.appendingPathComponent("action-root.txt"), encoding: .utf8) == f.checkout.path)
        try await settings.update(f.project) { $0.actions = try ProjectActions.updating("app-dev", with: .init(name: "App dev", command: "printf changed"), in: $0.actions ?? []) }
        await #expect(throws: CoincideError.self) { try await f.store.projectScripts().run(context, actionID: action.id, expectedDigest: action.digest, in: f.terminals) }
        await #expect(throws: CoincideError.self) { try await f.store.projectScripts().run(action, thread: f.thread, in: f.terminals) }
        #expect(f.terminals.sessions[f.thread.id]?.count == 1, "A stale action never creates a terminal.")
        settings.rememberInvokedScript(action.id, for: f.project)
        #expect(settings.lastInvokedScriptID(for: f.project) == action.id)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func projectSettingsStorePersistsMigratesFallbackKeysAndPreservesCorruptFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-settings-store-\(UUID())").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "coincide.tests.project-settings.\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var project = WorkspaceProject(path: root.appendingPathComponent("checkout").path)
    let checkoutKey = ProjectSettingsKey.primary(for: project)
    let store = ProjectSettingsStore(root: root, defaults: defaults)
    try await store.update(project) { $0.worktreeSubmodules = .topLevel; $0.icon = .emoji("🚀") }
    #expect(try ProjectSettingsFiles.load(root: root, key: checkoutKey)?.worktreeSubmodules == .topLevel)
    project.repositoryIdentity = try RepositoryIdentity(remote: #require(RepositoryIdentity.normalizedRemote("https://github.com/acme/app.git")),
                                                        remoteName: "origin", rootPath: project.path, projectRelativePath: "")
    let repositoryKey = ProjectSettingsKey.primary(for: project)
    let fresh = ProjectSettingsStore(root: root, defaults: defaults)
    #expect(await fresh.load(project).worktreeSubmodules == .topLevel, "Settings saved before identity resolution stay visible.")
    #expect(fresh.icon(for: project) == .emoji("🚀"))
    try await fresh.update(project) { $0.defaultThreadEnvMode = .worktree }
    #expect(try ProjectSettingsFiles.load(root: root, key: repositoryKey)?.worktreeSubmodules == .topLevel)
    #expect(try ProjectSettingsFiles.load(root: root, key: checkoutKey) == nil, "The fallback file moves to the shared key.")
    fresh.appWorktreeSubmodules = ProjectWorktreeSubmoduleMode.none; fresh.appThreadEnvironmentMode = .local
    let reloaded = ProjectSettingsStore(root: root, defaults: defaults)
    #expect(reloaded.appWorktreeSubmodules == ProjectWorktreeSubmoduleMode.none && reloaded.appThreadEnvironmentMode == .local)
    try await reloaded.update(project) { $0 = .init(key: $0.key) }
    #expect(try ProjectSettingsFiles.load(root: root, key: repositoryKey) == nil)
    let corrupt = ProjectSettingsFiles.fileURL(root: root, key: repositoryKey)
    try Data("{broken".utf8).write(to: corrupt)
    let guarded = ProjectSettingsStore(root: root, defaults: defaults)
    await guarded.load(project)
    #expect(guarded.loadErrors[repositoryKey] != nil)
    await #expect(throws: CoincideError.self) { try await guarded.update(project) { $0.icon = nil } }
    #expect(try Data(contentsOf: corrupt) == Data("{broken".utf8), "A corrupt settings file is never overwritten.")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func resolvedProjectDefaultsUseT3JSONUntilAProjectOverrideExists() async throws {
    let f = try await ProjectActionsFixture.make()
    do {
        let initial = try #require(await f.store.projectDefaults(threadID: f.thread.id))
        #expect(initial.worktreeSubmodules == .init(value: .topLevel, source: .repository))
        #expect(initial.threadEnvironmentMode == .init(value: .worktree, source: .repository))
        try await f.store.projectSettings.update(f.project) { $0.worktreeSubmodules = .recursive }
        #expect(await f.store.projectDefaults(projectID: f.project.id)?.worktreeSubmodules == .init(value: .recursive, source: .project))
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor private final class PreviewOpenerSpy: PreviewOpening {
    var opened: [URL] = []
    func openPreview(_ url: URL) -> Bool { opened.append(url); return true }
}
@MainActor private final class PreviewRunningFlag { var value = true }
private actor ProbeCounter {
    var calls = 0, readyAfter: Int
    init(readyAfter: Int) { self.readyAfter = readyAfter }
    func probe() -> Bool { calls += 1; return calls > readyAfter }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func previewAutoOpenWaitsForTheLocalPortAndStopsWithItsTerminal() async throws {
    let spy = PreviewOpenerSpy(), counter = ProbeCounter(readyAfter: 2)
    let launcher = ScriptPreviewLauncher(opener: spy, probe: { _ in await counter.probe() }, timeout: .seconds(5), interval: .milliseconds(10))
    let script = try ProjectScript(name: "Dev", command: "bun dev", previewURL: "http://localhost:5173", autoOpenPreview: true)
    await launcher.scheduleAutoOpen(script, id: UUID(), isRunning: { true })?.value
    let calls = await counter.calls
    #expect(spy.opened == [URL(string: "http://localhost:5173")!] && calls == 3)
    let running = PreviewRunningFlag()
    let stopped = launcher.scheduleAutoOpen(script, id: UUID(), isRunning: { running.value })
    running.value = false; await stopped?.value
    #expect(spy.opened.count == 1, "A terminal that stops first never opens its preview.")
    #expect(launcher.scheduleAutoOpen(try ProjectScript(name: "Dev", command: "x", previewURL: "http://localhost:5173"), id: UUID(), isRunning: { true }) == nil)
    let remote = try ProjectScript(name: "Docs", command: "x", previewURL: "https://example.com/docs", autoOpenPreview: true)
    await launcher.scheduleAutoOpen(remote, id: UUID(), isRunning: { true })?.value
    #expect(spy.opened.last == URL(string: "https://example.com/docs"), "Non-local previews open without probing.")
    let never = ScriptPreviewLauncher(opener: spy, probe: { _ in false }, timeout: .milliseconds(50), interval: .milliseconds(10))
    await never.scheduleAutoOpen(script, id: UUID(), isRunning: { true })?.value
    #expect(spy.opened.count == 2 && never.lastError?.contains("did not respond") == true && never.pendingCount == 0)
    #expect(throws: ProjectActionError.self) { try launcher.open("javascript:alert(1)") }
}

@Test(.timeLimit(.minutes(1)))
func previewProbeConnectsOnlyToAListeningLoopbackPort() async throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0); try #require(fd >= 0)
    var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
    #expect(bound == 0 && listen(fd, 4) == 0)
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    let port = UInt16(bigEndian: address.sin_port)
    #expect(await ScriptPreviewLauncher.acceptsConnection(try PreviewURLPolicy.validate("http://127.0.0.1:\(port)")))
    close(fd)
    #expect(!(await ScriptPreviewLauncher.acceptsConnection(try PreviewURLPolicy.validate("http://127.0.0.1:\(port)"))))
}

@MainActor private func renderActionsView<V: View>(_ view: V, width: CGFloat, height: CGFloat, dark: Bool, name: String? = nil) async throws -> NSHostingView<AnyView> {
    _ = NSApplication.shared
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua)), previous = NSApp.appearance
    NSApp.appearance = appearance; defer { NSApp.appearance = previous }
    let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, dark ? .dark : .light).frame(width: width, height: height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))))
    host.appearance = appearance; host.frame = .init(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = host; defer { window.close() }
    host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    if let name, ProcessInfo.processInfo.environment["COINCIDE_RENDER_PROJECT_ACTIONS"] == "1" {
        appearance.performAsCurrentDrawingAppearance {
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("coincide-project-actions-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
    return host
}

@MainActor @Test(.timeLimit(.minutes(1)))
func projectActionViewsLayOutInLightAndDarkWithoutOverflow() async throws {
    let f = try await ProjectActionsFixture.make()
    do {
        try await f.store.projectSettings.update(f.project) {
            $0.actions = try ProjectActions.adding(.init(name: "Install dependencies with a long descriptive name", command: "npm ci && npm run build:all -- --verbose",
                                                         runOnWorktreeCreate: true, waitForSetup: true, shortcut: try .init(key: "d", option: true, control: true)), to: [])
        }
        let presenter = ProjectActionsPresenter()
        for dark in [false, true] {
            let id = try #require(f.store.projectSettings.document(for: f.project).actions?.first?.id)
            let editor = try await renderActionsView(ProjectActionEditorSheet(settings: f.store.projectSettings, project: f.project, actionID: id, close: { }),
                                                     width: 520, height: 760, dark: dark, name: "editor")
            #expect(editor.fittingSize.width <= 521 && editor.fittingSize.height > 200)
            let sheet = try await renderActionsView(ProjectSettingsSheet(store: f.store, projectID: f.project.id, close: { }).environment(presenter),
                                                    width: 600, height: 640, dark: dark, name: "settings")
            #expect(sheet.fittingSize.width <= 601 && sheet.fittingSize.height > 0)
            let control = try await renderActionsView(ProjectActionsToolbarControl(store: f.store, terminals: f.terminals,
                requests: .init(review: { _, _ in }, addAction: { _ in }, settings: { _ in })).fixedSize(), width: 320, height: 40, dark: dark, name: "toolbar")
            #expect(control.fittingSize.width <= 321)
            for presentation in [ProjectIconPresentation.monogram(text: "NA", color: .teal), .emoji("🚀"), .symbol(name: "hammer", color: .orange)] {
                let icon = try await renderActionsView(ProjectIconGlyph(presentation: presentation, size: 16), width: 16, height: 16, dark: dark)
                #expect(icon.fittingSize.width <= 17 && icon.fittingSize.height <= 17)
            }
        }
        f.store.selectedThreadID = f.thread.id
        try await waitActionsUI { f.store.selectedThread != nil }
        #expect(f.store.projectSettings.icon(for: f.project) == nil, "Without an override or checkout image, the sidebar uses the monogram.")
        await f.store.projectSettings.resolveIcon(for: f.project)
        #expect(f.store.projectSettings.detectedIcons[f.project.path] != nil)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}
