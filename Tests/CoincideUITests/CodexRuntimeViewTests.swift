import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private actor CodexRuntimeGate {
    private(set) var entered = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { released = true; let owned = waiters; waiters = []; owned.forEach { $0.resume() } }
}
private final class CodexRuntimeNativeClient: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CodexInstallationState
    private var observers: [UUID: AsyncStream<CodexInstallationState>.Continuation] = [:]
    private var starts = 0, inspected: [CodexRuntimeConfiguration] = [], cancelled: [UUID] = [], removed: [[String]] = []
    let inspectionGate: CodexRuntimeGate?
    let cancellationGate: CodexRuntimeGate?
    init(state: CodexInstallationState = .init(), inspectionGate: CodexRuntimeGate? = nil, cancellationGate: CodexRuntimeGate? = nil) {
        value = state; self.inspectionGate = inspectionGate; self.cancellationGate = cancellationGate
    }
    var state: CodexInstallationState { lock.withLock { value } }
    var startCount: Int { lock.withLock { starts } }
    var inspections: [CodexRuntimeConfiguration] { lock.withLock { inspected } }
    var cancellations: [UUID] { lock.withLock { cancelled } }
    var removals: [[String]] { lock.withLock { removed } }
    var observerCount: Int { lock.withLock { observers.count } }
    func emit(_ state: CodexInstallationState) {
        let owned = lock.withLock { value = state; return Array(observers.values) }; owned.forEach { $0.yield(state) }
    }
    var client: CodexRuntimeStore.Client {
        .init(state: { self.state }, updates: {
            let id = UUID()
            return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let snapshot = self.lock.withLock { self.observers[id] = continuation; return self.value }
                continuation.yield(snapshot)
                continuation.onTermination = { [weak owner = self] _ in
                    guard let owner else { return }
                    _ = owner.lock.withLock { owner.observers.removeValue(forKey: id) }
                }
            }
        }, start: {
            let id = UUID(); self.lock.withLock { self.starts += 1 }
            self.emit(.init(operationID: id, phase: .downloading, downloadedBytes: 10, totalBytes: 100, version: "0.156.1")); return id
        }, cancel: { id in
            self.lock.withLock { self.cancelled.append(id) }
            guard self.state.operationID == id, self.state.phase.isWorking else { return }
            if let gate = self.cancellationGate { await gate.wait() }
            self.emit(.init(operationID: id, phase: .cancelled, version: "0.156.1"))
        }, remove: { paths in
            self.lock.withLock { self.removed.append(paths) }
            guard !paths.contains("/protected/custom-codex") else { throw CoincideError("private-error-canary") }
            self.emit(.init())
        }, inspect: { configuration in
            self.lock.withLock { self.inspected.append(configuration) }
            if let gate = self.inspectionGate { await gate.wait() }
            return .init(executable: URL(fileURLWithPath: configuration.selection == .custom ? configuration.executable : "/fixture/bin/codex"),
                         source: configuration.selection, version: "0.163.7")
        })
    }
}
@MainActor private func waitCodexRuntime(file: StaticString = #fileID, line: UInt = #line,
                                        _ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("Codex runtime fixture timed out at \(file):\(line).") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private func codexRuntimeFixtureRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("coincide-codex-runtime-" + UUID().uuidString, isDirectory: true)
}

@Test @MainActor func nativeCodexRuntimeKeepsExistingCLIByDefaultAndPersistsOnlyExplicitAcceptedChoice() async throws {
    let root = codexRuntimeFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let peer = CodexRuntimeNativeClient(), model = CodexRuntimeStore(rootURL: root, client: peer.client)
    let preferences = root.appendingPathComponent("CodexSettings/runtime.json")
    var applied: [CodexRuntimeConfiguration] = []
    model.bind(apply: { applied.append($0) })
    #expect(model.configuration == .init() && model.selection == .existingCLI && !model.canApply)
    #expect(peer.startCount == 0 && peer.inspections.isEmpty && !FileManager.default.fileExists(atPath: preferences.path))
    model.selection = .custom; model.executable = "/private/fixture/Codex 工作/bin/codex"; model.homeDirectory = "/private/fixture/Codex Home"
    #expect(model.configuration.selection == .existingCLI && applied.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: preferences.path))
    await model.checkRuntime()
    #expect(model.inspected?.version == "0.163.7" && model.inspected?.source == .custom)
    #expect(model.state.installedVersion == nil && applied.isEmpty, "A binary check cannot install a package or change account/runtime selection.")
    await model.applySelection()
    let accepted = try #require(applied.first)
    #expect(applied.count == 1 && model.configuration == accepted && !model.canApply)
    #expect(accepted.homeDirectory == "/private/fixture/Codex Home")
    let data = try Data(contentsOf: preferences)
    #expect(try JSONDecoder().decode(CodexRuntimeConfiguration.self, from: data) == accepted)
    let permissions = try FileManager.default.attributesOfItem(atPath: preferences.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    await model.shutdown()
    let reopened = CodexRuntimeStore(rootURL: root, client: peer.client)
    #expect(reopened.configuration == accepted && reopened.homeDirectory == accepted.homeDirectory)
    #expect(peer.startCount == 0 && peer.inspections.count == 1, "Loading saved preferences must not probe or authenticate a CLI.")
    await reopened.shutdown()
}

@Test @MainActor func nativeCodexRuntimeRejectsInvalidOrUnsafePreferencesAndFailedApplyPreservesSavedSelection() async throws {
    let root = codexRuntimeFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let peer = CodexRuntimeNativeClient(), model = CodexRuntimeStore(rootURL: root, client: peer.client)
    var attempts = 0
    model.bind(apply: { _ in attempts += 1; throw CoincideError("private-error-canary") })
    model.selection = .custom; model.executable = "/fixture/codex"; model.homeDirectory = "relative/home"
    #expect(!model.canApply && !model.canCheck)
    await model.applySelection(); #expect(attempts == 0)
    model.homeDirectory = ""; await model.applySelection()
    #expect(attempts == 1 && model.configuration.selection == .existingCLI)
    #expect(!(model.errorMessage ?? "").contains("private-error-canary"))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("CodexSettings/runtime.json").path))
    await model.shutdown()

    let unsafe = codexRuntimeFixtureRoot(), foreign = codexRuntimeFixtureRoot()
    defer { try? FileManager.default.removeItem(at: unsafe); try? FileManager.default.removeItem(at: foreign) }
    try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: unsafe.appendingPathComponent("CodexSettings"), withDestinationURL: foreign)
    let linked = CodexRuntimeStore(rootURL: unsafe, client: peer.client)
    linked.bind(apply: { _ in attempts += 1 })
    linked.selection = .managed; await linked.applySelection()
    #expect(linked.configuration.selection == .existingCLI && attempts == 1)
    #expect(!FileManager.default.fileExists(atPath: foreign.appendingPathComponent("runtime.json").path))
    await linked.shutdown()
}

@Test @MainActor func nativeCodexRuntimeDelayedInspectionCannotAttachToNewDraftAndShutdownJoinsItsOwnedCheck() async throws {
    let root = codexRuntimeFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let gate = CodexRuntimeGate(), peer = CodexRuntimeNativeClient(inspectionGate: gate)
    let model = CodexRuntimeStore(rootURL: root, client: peer.client)
    let check = Task { await model.checkRuntime() }
    try await waitCodexRuntime { await gate.entered == 1 }
    model.selection = .custom; model.executable = "/other/codex"
    var finished = false
    let close = Task { await model.shutdown(); finished = true }
    await Task.yield(); #expect(!finished)
    await gate.release(); await check.value; await close.value
    #expect(model.inspected == nil && model.inspectedConfiguration == nil && model.errorMessage == nil)
    #expect(peer.inspections == [.init()] && !model.canCheck)
}

@Test @MainActor func nativeCodexRuntimeInstallerObserverDoesNotCancelAnotherOwnerAndRemovalUsesFreshProtectedPaths() async throws {
    let root = codexRuntimeFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let gate = CodexRuntimeGate(), peer = CodexRuntimeNativeClient(cancellationGate: gate)
    let owner = CodexRuntimeStore(rootURL: root, client: peer.client), observer = CodexRuntimeStore(rootURL: root, client: peer.client)
    try await waitCodexRuntime { peer.observerCount == 2 }
    #expect(peer.startCount == 0 && peer.inspections.isEmpty)
    owner.startInstallation(); let id = try #require(owner.state.operationID)
    try await waitCodexRuntime { observer.state.operationID == id }
    owner.startInstallation(); #expect(peer.startCount == 1)
    await observer.shutdown(); #expect(peer.cancellations.isEmpty)
    let first = Task { await owner.shutdown() }
    try await waitCodexRuntime { await gate.entered == 1 }
    var secondFinished = false
    let second = Task { await owner.shutdown(); secondFinished = true }
    await Task.yield(); #expect(!secondFinished)
    await gate.release(); await first.value; await second.value
    #expect(peer.cancellations == [id])

    let installed = CodexInstallationState(phase: .succeeded, version: "0.156.1", installedVersion: "0.156.1", canRemove: true)
    peer.emit(installed)
    let removal = CodexRuntimeStore(rootURL: root, client: peer.client)
    let paths = NativeCodexProtectedPaths(["/old/codex"])
    removal.bind(apply: { _ in Issue.record("Removing a package must not switch runtime preferences.") }, protectedCustomPaths: { paths.values })
    paths.values = ["/protected/custom-codex"]; removal.removeManagedRuntime()
    #expect(peer.removals == [paths.values] && removal.state == installed)
    #expect(!(removal.errorMessage ?? "").contains("private-error-canary"))
    paths.values = ["/unrelated/codex"]; removal.removeManagedRuntime()
    #expect(peer.removals.last == paths.values && removal.configuration == .init())
    await removal.shutdown()
}

@MainActor private final class NativeCodexProtectedPaths {
    var values: [String]
    init(_ values: [String]) { self.values = values }
}
@MainActor private final class CodexRuntimeGeometry { var frames: [String: CGRect] = [:] }
@Test @MainActor func nativeCodexRuntimeSettingsKeepActionsReachableInNarrowLongTextAndRTLLayouts() async throws {
    _ = NSApplication.shared
    let cases: [(String, CodexRuntimeSelection, CodexInstallationState, [String])] = [
        ("installed", .managed, .init(phase: .succeeded, version: "0.156.1", installedVersion: "0.156.1", canRemove: true), ["apply", "check", "install", "remove"]),
        ("downloading", .managed, .init(operationID: UUID(), phase: .downloading, downloadedBytes: 123_456,
             totalBytes: 111_456_962, version: "0.156.1"), ["apply", "check", "install", "cancel"]),
        ("custom", .custom, .init(), ["apply", "check"])
    ]
    for width in [320.0, 680.0] {
        for dark in [false, true] {
            for rtl in [false, true] {
                for (name, selection, state, actions) in cases {
                    let root = codexRuntimeFixtureRoot(), peer = CodexRuntimeNativeClient(state: state)
                    let model = CodexRuntimeStore(rootURL: root, client: peer.client), geometry = CodexRuntimeGeometry()
                    model.bind(apply: { _ in Issue.record("Rendering must not change the runtime selection.") })
                    model.selection = selection
                    if selection == .custom { model.executable = "/fixture/" + String(repeating: "Long path 工作 مرحبًا ", count: 4) + "/codex" }
                    let content = CodexRuntimeSettingsSection(runtime: model, reportGeometry: { geometry.frames[$0] = $1 })
                    try await captureCodexRuntime(content, geometry: geometry, actions: actions, name: name, width: width, dark: dark, rtl: rtl)
                    #expect(peer.startCount == 0 && peer.inspections.isEmpty)
                    await model.shutdown(); try? FileManager.default.removeItem(at: root)
                }
            }
        }
    }
}
@MainActor private func captureCodexRuntime<V: View>(_ content: V, geometry: CodexRuntimeGeometry, actions: [String],
                                                   name: String, width: CGFloat, dark: Bool, rtl: Bool) async throws {
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua)), previous = NSApp.appearance
    NSApp.appearance = appearance; defer { NSApp.appearance = previous }
    let root = VStack(alignment: .leading) { content }.padding(16).coincideSurface()
        .environment(\.colorScheme, dark ? .dark : .light).environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        .environment(\.controlActiveState, .active)
    let height: CGFloat = 1_100
    let host = NSHostingView(rootView: root.frame(width: width, height: height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = appearance; host.frame = .init(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = host; defer { window.close() }
    host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    let bounds = try #require(geometry.frames["bounds"])
    #expect(bounds.minX >= -1 && bounds.maxX <= width + 1 && bounds.height <= height)
    for action in actions {
        let frame = try #require(geometry.frames[action])
        #expect(frame.width > 0 && frame.height > 0 && bounds.insetBy(dx: -1, dy: -1).contains(frame))
    }
    guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_CODEX_RUNTIME"] == "1" else { return }
    appearance.performAsCurrentDrawingAppearance {
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "coincide-codex-runtime-\(name)-\(Int(width))-\(dark ? "dark" : "light")-\(rtl ? "rtl" : "ltr").png"))
            }
        }
    }
}
