import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private actor CodexAuthViewGate {
    private(set) var entered = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { released = true; let owned = waiters; waiters = []; owned.forEach { $0.resume() } }
}

private actor CodexAuthViewPeer {
    enum Call: Equatable, Sendable { case signIn(UUID?, Bool), activate(UUID), signOut(UUID), cancel(UUID), shutdown }
    nonisolated let instanceID: UUID
    nonisolated let clientID = UUID()
    private(set) var state: CodexAuthenticationState
    private(set) var reads = 0
    private(set) var calls: [Call] = []
    private var value: CodexAccountOverview
    private var readGate: CodexAuthViewGate?
    private var cancellationGate: CodexAuthViewGate?
    private var observers: [UUID: AsyncStream<CodexAuthenticationState>.Continuation] = [:]
    init(instanceID: UUID, overview: CodexAccountOverview = .init(binding: nil, profiles: [])) {
        self.instanceID = instanceID; state = .init(instanceID: instanceID); value = overview
    }
    nonisolated var client: CodexAuthenticationStore.Client {
        .init(id: clientID, instanceID: instanceID, state: { await self.state }, updates: { await self.updates() },
            overview: { try await self.read() }, start: { await self.start($0, $1) },
            activate: { await self.act(.activate($0)) }, signOut: { await self.act(.signOut($0)) },
            cancel: { await self.cancel($0) }, shutdown: { await self.shutdown() })
    }
    func configure(readGate: CodexAuthViewGate? = nil, cancellationGate: CodexAuthViewGate? = nil) {
        self.readGate = readGate; self.cancellationGate = cancellationGate
    }
    func emit(_ value: CodexAuthenticationState) {
        state = value; for observer in observers.values { observer.yield(value) }
    }
    func finish(_ phase: CodexAuthenticationPhase = .succeeded) {
        emit(.init(instanceID: instanceID, flowID: state.flowID, phase: phase, overview: value))
    }
    private func updates() -> AsyncStream<CodexAuthenticationState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation; continuation.yield(state)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func read() async throws -> CodexAccountOverview {
        reads += 1; let captured = value
        if let readGate { await readGate.wait() }
        return captured
    }
    private func start(_ profileID: UUID?, _ consent: Bool) -> UUID { act(.signIn(profileID, consent)) }
    private func act(_ call: Call) -> UUID {
        calls.append(call); let flow = UUID()
        emit(.init(instanceID: instanceID, flowID: flow, phase: .waitingForBrowser,
            authorizationURL: URL(string: "https://auth.openai.com/api/accounts/authorize?state=offline-fixture"),
            expiresAt: Date().addingTimeInterval(300)))
        return flow
    }
    private func cancel(_ id: UUID) async {
        calls.append(.cancel(id))
        if let cancellationGate { await cancellationGate.wait() }
        finish(.cancelled)
    }
    private func shutdown() async {
        calls.append(.shutdown)
        if let cancellationGate { await cancellationGate.wait() }
        let owned = observers.values; observers = [:]; owned.forEach { $0.finish() }
    }
}

private final class CodexAuthRuntimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    var client: CodexRuntimeStore.Client {
        .init(state: { .init() }, updates: { AsyncStream { $0.finish() } }, start: {
            self.lock.withLock { self.calls += 1 }; throw CoincideError("Offline installer must not run.")
        }, cancel: { _ in }, remove: { _ in }, inspect: { _ in
            self.lock.withLock { self.calls += 1 }; throw CoincideError("Offline executable probe must not run.")
        })
    }
}

@MainActor private func waitCodexAuthView(file: StaticString = #fileID, line: UInt = #line,
                                        _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("Codex auth fixture timed out at \(file):\(line).") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private func codexAuthViewRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("coincide-codex-auth-view-" + UUID().uuidString, isDirectory: true)
}
@MainActor private func withCodexAuthRuntime(_ body: (URL, CodexRuntimeStore, CodexAuthRuntimeProbe) async throws -> Void) async throws {
    let root = codexAuthViewRoot(), probe = CodexAuthRuntimeProbe()
    let runtime = CodexRuntimeStore(rootURL: root, client: probe.client)
    runtime.bind(apply: { _ in })
    runtime.authenticationMode = .ownedChatGPT; runtime.homeDirectory = root.appendingPathComponent("Shared Codex 工作").path
    await runtime.applySelection()
    do { try await body(root, runtime, probe) }
    catch { await runtime.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    await runtime.shutdown(); try FileManager.default.removeItem(at: root)
}

@Test @MainActor func nativeCodexAuthenticationRequiresAnExplicitSavedOwnedConnectionAndNeverStartsOnObservation() async throws {
    let instance = CodexRuntimeConfiguration.defaultInstanceID, peer = CodexAuthViewPeer(instanceID: instance)
    let model = CodexAuthenticationStore()
    await model.refreshAccounts(); await model.startSignIn()
    let initialReads = await peer.reads, initialCalls = await peer.calls
    #expect(initialReads == 0 && initialCalls.isEmpty)
    #expect(!model.canStart && !model.canRefresh && model.authorizationURL == nil)
    let config = CodexRuntimeConfiguration(homeDirectory: "/fixture/shared-codex", authenticationMode: .ownedChatGPT)
    await model.bind(client: peer.client, configuration: config)
    #expect(model.canStart && model.canRefresh)
    let boundReads = await peer.reads, boundCalls = await peer.calls
    #expect(boundReads == 0 && boundCalls.isEmpty)
    await model.startSignIn()
    try await waitCodexAuthView { model.state.phase == .waitingForBrowser }
    #expect(await peer.calls == [.signIn(nil, false)])
    #expect(model.state.phase == .waitingForBrowser && model.authorizationURL != nil && !model.canStart)
    let flow = try #require(model.state.flowID)
    await model.cancel()
    try await waitCodexAuthView { model.state.phase == .cancelled }
    #expect(await peer.calls == [.signIn(nil, false), .cancel(flow)])
    await model.shutdown()
}

@Test @MainActor func nativeCodexAuthenticationUsesOnlyOfferedProfilesAndCannotOpenAnUntrustedOrExpiredURL() async throws {
    let first = UUID(), second = UUID(), blocked = UUID(), instance = UUID()
    let binding = CodexAccountBinding(profileID: first, generation: UUID())
    let overview = CodexAccountOverview(binding: binding, profiles: [
        .init(id: first, email: "first-private-label@example.invalid", sharingEnabled: true, isActive: true, hasCredential: true, requiresReconnect: false),
        .init(id: second, email: "second-private-label@example.invalid", sharingEnabled: true, isActive: false, hasCredential: true, requiresReconnect: false),
        .init(id: blocked, email: nil, sharingEnabled: false, isActive: false, hasCredential: true, requiresReconnect: false)
    ])
    let peer = CodexAuthViewPeer(instanceID: instance, overview: overview)
    let config = CodexRuntimeConfiguration(instanceID: instance, homeDirectory: "/fixture/shared-codex", authenticationMode: .ownedChatGPT, accountBinding: binding)
    let model = CodexAuthenticationStore(configuration: config, client: peer.client)
    await model.refreshAccounts()
    #expect(model.profiles.count == 3)
    await model.selectProfile(first); await model.selectProfile(blocked); await model.selectProfile(UUID())
    #expect(await peer.calls.isEmpty)
    await model.selectProfile(second)
    #expect(await peer.calls == [.activate(second)])
    await peer.finish(); try await waitCodexAuthView { model.canStart }
    await model.reconnect(profileID: blocked)
    #expect(await peer.calls.last == .signIn(blocked, true))
    await peer.finish(); try await waitCodexAuthView { model.canStart }
    await model.signOut(profileID: first)
    #expect(await peer.calls.last == .signOut(first))
    let flow = UUID()
    await peer.emit(.init(instanceID: instance, flowID: flow, phase: .waitingForBrowser,
        authorizationURL: URL(string: "https://auth.openai.com.attacker.invalid/api/accounts/authorize"), expiresAt: Date().addingTimeInterval(300)))
    try await waitCodexAuthView { model.state.flowID == flow }
    #expect(model.authorizationURL == nil)
    let expired = UUID()
    await peer.emit(.init(instanceID: instance, flowID: expired, phase: .waitingForBrowser,
        authorizationURL: URL(string: "https://auth.openai.com/api/accounts/authorize"), expiresAt: .distantPast))
    try await waitCodexAuthView { model.state.flowID == expired }
    #expect(model.authorizationURL == nil)
    await model.shutdown()
}

@Test @MainActor func nativeCodexAuthenticationRetainsAndDrainsStaleAccountReadsWithoutPublishingThemAfterScopeChange() async throws {
    let instance = UUID(), profile = UUID(), gate = CodexAuthViewGate()
    let old = CodexAccountBinding(profileID: profile, generation: UUID())
    let peer = CodexAuthViewPeer(instanceID: instance, overview: .init(binding: old, profiles: [
        .init(id: profile, email: "stale-private-label@example.invalid", sharingEnabled: true, isActive: true, hasCredential: true, requiresReconnect: false)
    ]))
    await peer.configure(readGate: gate)
    let config = CodexRuntimeConfiguration(instanceID: instance, homeDirectory: "/fixture/shared-codex", authenticationMode: .ownedChatGPT, accountBinding: old)
    let model = CodexAuthenticationStore(configuration: config, client: peer.client)
    let read = Task { await model.refreshAccounts() }
    try await waitCodexAuthView { await gate.entered == 1 }
    model.updateConfiguration(config.replacingAccountBinding(.init(profileID: profile, generation: UUID())))
    var finished = false
    let closing = Task { await model.shutdown(); finished = true }
    try await Task.sleep(for: .milliseconds(20))
    #expect(!finished && model.overview == nil)
    await gate.release(); await read.value; await closing.value
    #expect(finished && model.overview == nil && !model.isRefreshing && !model.canStart)
}

@Test(arguments: [CodexAuthenticationPhase.cancelled, .failed, .unconfirmed])
@MainActor func nativeCodexAuthenticationMismatchedTerminalOverviewStillRetiresWorkingStateAndAuthorizationURL(phase: CodexAuthenticationPhase) async throws {
    let instance = UUID(), profile = UUID(), binding = CodexAccountBinding(profileID: profile, generation: UUID())
    let overview = CodexAccountOverview(binding: binding, profiles: [
        .init(id: profile, email: "mismatched-private-label@example.invalid", sharingEnabled: true, isActive: true, hasCredential: true, requiresReconnect: false)
    ])
    let peer = CodexAuthViewPeer(instanceID: instance, overview: overview)
    let config = CodexRuntimeConfiguration(instanceID: instance, homeDirectory: "/fixture/shared-home", authenticationMode: .ownedChatGPT)
    let model = CodexAuthenticationStore(configuration: config, client: peer.client)
    await model.startSignIn()
    try await waitCodexAuthView { model.state.phase == .waitingForBrowser }
    #expect(model.authorizationURL != nil && model.isWorking)
    await peer.emit(.init(instanceID: instance, flowID: model.state.flowID, phase: phase, overview: overview))
    try await waitCodexAuthView { model.state.phase == phase }
    #expect(!model.isWorking && model.authorizationURL == nil && model.overview == nil)
    #expect(model.configuration == config && model.canStart)
    await model.refreshAccounts()
    #expect(model.overview == overview && model.canSelectProfile(profile))
    #expect(await peer.calls == [.signIn(nil, false)])
    await model.shutdown()
}

@Test @MainActor func nativeCodexAuthenticationRebindingJoinsExactCancellationAndIgnoresTheRetiredController() async throws {
    let instance = UUID(), gate = CodexAuthViewGate(), peer = CodexAuthViewPeer(instanceID: instance)
    let config = CodexRuntimeConfiguration(instanceID: instance, homeDirectory: "/fixture/first-home", authenticationMode: .ownedChatGPT)
    let model = CodexAuthenticationStore(configuration: config, client: peer.client)
    await model.startSignIn(); await peer.configure(cancellationGate: gate)
    let cancelling = Task { await model.cancel() }
    try await waitCodexAuthView { await gate.entered == 1 }
    #expect(model.isCancelling && !model.canStart)
    let replacement = CodexAuthViewPeer(instanceID: instance)
    let newConfig = CodexRuntimeConfiguration(instanceID: instance, homeDirectory: "/fixture/second-home", authenticationMode: .ownedChatGPT)
    var rebound = false
    let binding = Task { await model.bind(client: replacement.client, configuration: newConfig); rebound = true }
    try await waitCodexAuthView { await gate.entered == 2 }
    #expect(!rebound)
    await gate.release(); await cancelling.value; await binding.value
    await peer.emit(.init(instanceID: instance, flowID: UUID(), phase: .unconfirmed, message: "Retired controller must not publish."))
    #expect(model.configuration == newConfig && model.overview == nil && model.state.phase == .idle)
    #expect(await replacement.calls.isEmpty)
    await model.shutdown()
}

@Test @MainActor func nativeCodexAuthenticationPublicationPreservesRuntimeAndDraftChoicesAndNeverFallsBackToCLIOnSignOut() async throws {
    try await withCodexAuthRuntime { root, runtime, probe in
        let original = runtime.configuration, binding = CodexAccountBinding(profileID: UUID(), generation: UUID())
        var applied: [CodexRuntimeConfiguration] = []
        runtime.bind(apply: { applied.append($0) })
        runtime.selection = .custom; runtime.executable = "/fixture/unsaved-future/codex"
        try await runtime.publishAccountBinding(binding, expectedInstanceID: original.instanceID)
        #expect(runtime.configuration == original.replacingAccountBinding(binding))
        #expect(runtime.selection == .custom && runtime.hasUnappliedChanges)
        #expect(runtime.draftConfiguration?.accountBinding == binding)
        let data = try Data(contentsOf: root.appendingPathComponent("CodexSettings/runtime.json"))
        #expect(try JSONDecoder().decode(CodexRuntimeConfiguration.self, from: data) == runtime.configuration)
        #expect(!String(decoding: data, as: UTF8.self).contains("@"))
        try await runtime.publishAccountBinding(nil, expectedInstanceID: original.instanceID)
        #expect(runtime.configuration.authenticationMode == .ownedChatGPT && runtime.configuration.accountBinding == nil)
        #expect(applied == [original.replacingAccountBinding(binding), original])
        #expect(probe.count == 0)
        let reopened = CodexRuntimeStore(rootURL: root, client: probe.client)
        #expect(reopened.configuration == original && reopened.authenticationMode == .ownedChatGPT)
        await reopened.shutdown()
    }
}

@Test @MainActor func nativeCodexAuthenticationPublicationFailureIsThrownAfterObservedAccountChangeWithoutClaimingRollback() async throws {
    try await withCodexAuthRuntime { root, runtime, probe in
        let binding = CodexAccountBinding(profileID: UUID(), generation: UUID())
        let preferences = root.appendingPathComponent("CodexSettings/runtime.json")
        runtime.bind(apply: { _ in
            try FileManager.default.removeItem(at: preferences)
            try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: false)
        })
        await #expect(throws: CoincideError.self) {
            try await runtime.publishAccountBinding(binding, expectedInstanceID: runtime.configuration.instanceID)
        }
        #expect(runtime.configuration.accountBinding == binding && runtime.configuration.authenticationMode == .ownedChatGPT)
        #expect(runtime.errorMessage?.contains("could not be saved") == true && runtime.hasUnappliedChanges == false && runtime.canApply)
        #expect(probe.count == 0)
    }
}

@MainActor private final class CodexAuthViewGeometry { var frames: [String: CGRect] = [:] }

@Test @MainActor func nativeCodexAuthenticationActionsFitNarrowLongTextAndRTLWithoutAutomaticAccountOrRuntimeCalls() async throws {
    _ = NSApplication.shared
    for width in [320.0, 680.0] {
        for dark in [false, true] {
            for rtl in [false, true] {
                for phase in [CodexAuthenticationPhase.idle, .waitingForBrowser, .unconfirmed] {
                    try await withCodexAuthRuntime { _, runtime, probe in
                        let profile = UUID(), binding = CodexAccountBinding(profileID: profile, generation: UUID())
                        try await runtime.publishAccountBinding(binding, expectedInstanceID: runtime.configuration.instanceID)
                        let overview = CodexAccountOverview(binding: binding, profiles: [
                            .init(id: profile, email: String(repeating: "Private مرحبًا 工作 ", count: 20) + "@example.invalid", sharingEnabled: true, isActive: true, hasCredential: true, requiresReconnect: false)
                        ])
                        let peer = CodexAuthViewPeer(instanceID: runtime.configuration.instanceID, overview: overview)
                        let model = CodexAuthenticationStore(configuration: runtime.configuration, client: peer.client)
                        let flow = UUID()
                        await peer.emit(.init(instanceID: runtime.configuration.instanceID, flowID: flow, phase: phase,
                            authorizationURL: phase == .waitingForBrowser ? URL(string: "https://auth.openai.com/api/accounts/authorize?state=offline") : nil,
                            expiresAt: Date().addingTimeInterval(300), overview: overview,
                            message: phase == .unconfirmed ? String(repeating: "The saved account changed; refresh before continuing. مرحبًا 工作 ", count: 4) : nil))
                        try await waitCodexAuthView { model.state.flowID == flow }
                        let geometry = CodexAuthViewGeometry()
                        let content = CodexAuthenticationSection(authentication: model, runtime: runtime,
                            reportGeometry: { geometry.frames[$0] = $1 })
                        try await captureCodexAuthentication(content, geometry: geometry, width: width, dark: dark, rtl: rtl, phase: phase)
                        let reads = await peer.reads, calls = await peer.calls
                        #expect(reads == 0 && calls.isEmpty)
                        #expect(probe.count == 0)
                        await model.shutdown()
                    }
                }
            }
        }
    }
}

@MainActor private func captureCodexAuthentication<V: View>(_ content: V, geometry: CodexAuthViewGeometry,
                                                            width: CGFloat, dark: Bool, rtl: Bool, phase: CodexAuthenticationPhase) async throws {
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua)), previous = NSApp.appearance
    NSApp.appearance = appearance; defer { NSApp.appearance = previous }
    let height: CGFloat = 1_600
    let root = VStack(alignment: .leading) { content }.padding(16).coincideSurface()
        .environment(\.colorScheme, dark ? .dark : .light).environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        .environment(\.controlActiveState, .active)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    let host = NSHostingView(rootView: root)
    host.appearance = appearance; host.frame = .init(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = host; defer { window.close() }
    host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    let bounds = try #require(geometry.frames["bounds"])
    #expect(bounds.minX >= -1 && bounds.maxX <= width + 1 && bounds.height <= height)
    let actions = phase == .waitingForBrowser ? ["browser", "cancel", "sign-in", "refresh"] : ["sign-in", "refresh"]
    for action in actions {
        let frame = try #require(geometry.frames[action])
        #expect(frame.width > 0 && frame.height > 0 && bounds.insetBy(dx: -1, dy: -1).contains(frame))
    }
    guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_CODEX_AUTHENTICATION"] == "1" else { return }
    appearance.performAsCurrentDrawingAppearance {
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "coincide-codex-authentication-\(phase.rawValue)-\(Int(width))-\(dark ? "dark" : "light")-\(rtl ? "rtl" : "ltr").png"))
            }
        }
    }
}
