import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private actor NativeInstallationDrain {
    var entered: [UUID] = []
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold(_ id: UUID) async {
        entered.append(id)
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { released = true; let owned = waiters; waiters = []; owned.forEach { $0.resume() } }
}
private final class NativeInstallationClient: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AntigravityInstallationState
    private var observers: [UUID: AsyncStream<AntigravityInstallationState>.Continuation] = [:]
    private var starts = 0
    private var cancels: [UUID] = []
    private var removals: [[String]] = []
    let drain: NativeInstallationDrain?
    init(state: AntigravityInstallationState = .init(), drain: NativeInstallationDrain? = nil) {
        value = state; self.drain = drain
    }
    var state: AntigravityInstallationState { lock.withLock { value } }
    var startCount: Int { lock.withLock { starts } }
    var cancellations: [UUID] { lock.withLock { cancels } }
    var removedPaths: [[String]] { lock.withLock { removals } }
    var observerCount: Int { lock.withLock { observers.count } }
    func emit(_ state: AntigravityInstallationState) {
        let owned = lock.withLock { value = state; return Array(observers.values) }
        owned.forEach { $0.yield(state) }
    }
    var client: AntigravityInstallationStore.Client {
        .init(state: { self.state }, updates: {
            let id = UUID()
            return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let snapshot = self.lock.withLock { self.observers[id] = continuation; return self.value }
                continuation.yield(snapshot)
                continuation.onTermination = { [weak self] _ in
                    _ = self?.lock.withLock { self?.observers.removeValue(forKey: id) }
                }
            }
        }, start: {
            let id = UUID()
            self.lock.withLock { self.starts += 1 }
            self.emit(.init(operationID: id, phase: .downloading, downloadedBytes: 32, totalBytes: 128,
                version: "1.3.0", installedVersion: self.state.installedVersion))
            return id
        }, cancel: { id in
            self.lock.withLock { self.cancels.append(id) }
            guard self.state.operationID == id, self.state.phase.isWorking else { return }
            if let drain = self.drain { await drain.hold(id) }
            self.emit(.init(operationID: id, phase: .cancelled, version: "1.3.0"))
        }, remove: { paths in
            self.lock.withLock { self.removals.append(paths) }
            guard !paths.contains("/protected/custom-runtime") else { throw CoincideError("sensitive-error-canary") }
            self.emit(.init())
        })
    }
}
@MainActor private func waitNativeInstallation(file: StaticString = #fileID, line: UInt = #line,
                                              _ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("Installation fixture timed out at \(file):\(line).") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test @MainActor func nativeManagedRuntimeObservationDoesNotInstallAndClosingAnotherWindowDoesNotCancelTheOwner() async throws {
    let drain = NativeInstallationDrain(), peer = NativeInstallationClient(drain: drain)
    let owner = AntigravityInstallationStore(client: peer.client), observer = AntigravityInstallationStore(client: peer.client)
    try await waitNativeInstallation { peer.observerCount == 2 }
    #expect(peer.startCount == 0 && peer.cancellations.isEmpty)
    owner.start()
    let id = try #require(owner.state.operationID)
    try await waitNativeInstallation { observer.state.operationID == id }
    #expect(owner.progress == 0.25 && peer.startCount == 1)
    owner.start(); #expect(peer.startCount == 1, "A second click cannot start another installation while the first is running.")
    await observer.shutdown()
    #expect(peer.cancellations.isEmpty && owner.state.phase == .downloading)
    let firstClose = Task { await owner.shutdown() }
    try await waitNativeInstallation { await drain.entered == [id] }
    var secondEntered = false, secondFinished = false
    let secondClose = Task { secondEntered = true; await owner.shutdown(); secondFinished = true }
    try await waitNativeInstallation { secondEntered }
    #expect(!secondFinished && !owner.canStart)
    await drain.release(); await firstClose.value; await secondClose.value
    #expect(peer.cancellations == [id] && owner.state.phase == .cancelled)
    try await waitNativeInstallation { peer.observerCount == 0 }
}

@Test @MainActor func nativeManagedRuntimeRemovalUsesLatestProtectedPathsAndPreservesStateOnRefusal() async throws {
    let installed = AntigravityInstallationState(phase: .idle, version: "1.3.0", installedVersion: "1.3.0", canRemove: true)
    let peer = NativeInstallationClient(state: installed), model = AntigravityInstallationStore(client: peer.client)
    var paths = ["/old/custom-runtime"]
    model.bind(protectedCustomPaths: { paths })
    #expect(model.startTitle == "Verify Installed Runtime" && model.canRemove)
    paths = ["/protected/custom-runtime"]
    model.remove()
    #expect(peer.removedPaths == [["/protected/custom-runtime"]])
    #expect(model.state == installed && model.canRemove)
    #expect(!(model.errorMessage ?? "").contains("sensitive-error-canary"))
    paths = ["/separate/custom-runtime"]
    model.remove()
    #expect(peer.removedPaths.last == ["/separate/custom-runtime"] && !model.canRemove)
    #expect(peer.startCount == 0)
    await model.shutdown()
}

@Test @MainActor func nativeManagedRuntimeInstallSuccessDoesNotAuthenticateOrReplaceAccountConfiguration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-managed-account-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let account = AntigravityAccountStore(stateRoot: root, sessionFactory: { _, _, _ in
        throw CoincideError("Installing a runtime must not create an account session.")
    }, credentials: .init(read: { _ in Issue.record("Installing must not read Keychain."); return nil },
                          write: { _, _ in Issue.record("Installing must not write Keychain.") },
                          remove: { _ in Issue.record("Installing must not remove a credential.") }))
    let saved = account.configuration, peer = NativeInstallationClient()
    let model = AntigravityInstallationStore(client: peer.client)
    model.start(); let id = try #require(model.state.operationID)
    peer.emit(.init(operationID: id, phase: .succeeded, version: "1.3.0", installedVersion: "1.3.0", canRemove: true))
    try await waitNativeInstallation { model.state.phase == .succeeded }
    #expect(account.configuration == saved && account.accessState == nil && account.state.phase == .idle)
    #expect(model.canRemove && model.startTitle == "Verify Installed Runtime")
    await model.shutdown(); await account.shutdown()
}

@MainActor private final class NativeInstallationGeometry { var frames: [String: CGRect] = [:] }
@Test @MainActor func nativeManagedRuntimeControlsKeepAllActionsInsideNarrowRTLAndLongStatusLayouts() async throws {
    _ = NSApplication.shared
    let cases: [(String, AntigravityInstallationState, [String])] = [
        ("installed", .init(phase: .idle, version: "1.3.0", installedVersion: "1.3.0", canRemove: true), ["start", "remove"]),
        ("downloading", .init(operationID: UUID(), phase: .downloading, downloadedBytes: 123_456, totalBytes: 111_456_962,
            version: "1.3.0"), ["start", "cancel"]),
        ("failed", .init(phase: .failed, version: "1.3.0", installedVersion: "1.2.0", canRemove: true,
            message: String(repeating: "Review the managed runtime before trying again. 工作 مرحبًا 🌍 ", count: 4)), ["start", "remove"])
    ]
    for width in [320.0, 680.0] {
        for dark in [false, true] {
            for rtl in [false, true] {
                for (name, state, regions) in cases {
                    let peer = NativeInstallationClient(state: state), model = AntigravityInstallationStore(client: peer.client)
                    let geometry = NativeInstallationGeometry()
                    let view = AntigravityManagedRuntimeControls(installation: model, reportGeometry: { geometry.frames[$0] = $1 })
                    try await captureManagedRuntime(view, geometry: geometry, regions: regions, name: name,
                                                    width: width, dark: dark, rtl: rtl)
                    #expect(peer.startCount == 0 && peer.cancellations.isEmpty)
                    await model.shutdown()
                }
            }
        }
    }
}
@MainActor private func captureManagedRuntime<V: View>(_ content: V, geometry: NativeInstallationGeometry,
                                                       regions: [String], name: String, width: CGFloat, dark: Bool, rtl: Bool) async throws {
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua)), previous = NSApp.appearance
    NSApp.appearance = appearance; defer { NSApp.appearance = previous }
    let root = content.padding(16).coincideSurface().environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight).environment(\.controlActiveState, .active)
    let host = NSHostingView(rootView: root.frame(width: width, height: 540, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = appearance; host.frame = .init(x: 0, y: 0, width: width, height: 540)
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: width, height: 540), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    let bounds = try #require(geometry.frames["bounds"])
    #expect(bounds.minX >= -1 && bounds.maxX <= width + 1 && bounds.height <= 540)
    for region in regions {
        let frame = try #require(geometry.frames[region])
        #expect(frame.width > 0 && frame.height > 0 && bounds.insetBy(dx: -1, dy: -1).contains(frame),
                "Every explicit runtime action must remain reachable within the managed runtime controls.")
    }
    guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_ANTIGRAVITY_INSTALLATION"] == "1" else { return }
    appearance.performAsCurrentDrawingAppearance {
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                let file = "coincide-antigravity-install-\(name)-\(Int(width))-\(dark ? "dark" : "light")-\(rtl ? "rtl" : "ltr").png"
                try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(file))
            }
        }
    }
}
