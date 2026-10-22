import AppKit
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private actor NativeAntigravityAccountPeer: AntigravityAuthenticationSession {
    let holdLogout: Bool
    init(holdLogout: Bool = false) { self.holdLogout = holdLogout }
    var authentications = 0
    var healthChecks = 0
    var closes = 0
    var logouts = 0
    var logoutWaiter: CheckedContinuation<Void, Never>?
    var applyEntered = false
    var applyWaiter: CheckedContinuation<Void, Never>?
    func authenticate() async throws -> [ProviderModel] { authentications += 1; return [.init(id: "native-test", name: "Native test")] }
    func logout() async throws {
        logouts += 1
        if holdLogout { await withCheckedContinuation { logoutWaiter = $0 }; throw CoincideError("native-test-lost-logout") }
    }
    func healthCheck() async throws -> JSONValue { healthChecks += 1; return .object(["initialized": .bool(true)]) }
    func close() async { closes += 1; logoutWaiter?.resume(); logoutWaiter = nil }
    func holdApply() async { applyEntered = true; await withCheckedContinuation { applyWaiter = $0 } }
    func releaseApply() { applyWaiter?.resume(); applyWaiter = nil }
}
private final class NativeAntigravityKeyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var writes: Set<UUID> = []
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }
    var stored: Set<UUID> { lock.withLock { writes } }
    var access: AntigravityCredentialAccess {
        .init(read: { _ in self.lock.withLock { self.reads += 1 }; return nil },
              write: { _, config in self.lock.withLock { _ = self.writes.insert(config.authGeneration) } },
              remove: { config in self.lock.withLock { _ = self.writes.remove(config.authGeneration) } })
    }
}
@MainActor private func waitNativeAntigravity(_ condition: () async -> Bool,
                                              file: StaticString = #fileID, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("Native Antigravity fixture boundary timed out at \(file):\(line).") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test @MainActor func nativeAntigravityAccountCommitsRegistryUnderLeaseAndShutdownWaitsForFinalApply() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-antigravity-native-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let peer = NativeAntigravityAccountPeer(), keys = NativeAntigravityKeyRecorder()
    let account = AntigravityAccountStore(stateRoot: root, sessionFactory: { _, _, _ in peer }, credentials: keys.access)
    account.bind(beginLease: { _ in UUID() }, endLease: { _ in }, apply: { _ in await peer.holdApply() })
    account.authMethod = .geminiAPIKey; account.apiKey = "native-fixture-only-key"
    let originalGeneration = account.configuration.authGeneration
    await account.signIn()
    try await waitNativeAntigravity { await peer.applyEntered && account.state.phase == .committing }
    #expect(account.apiKey.isEmpty && account.configuration.authGeneration != originalGeneration)
    #expect(account.accessState == .pending && !account.state.canCancel)
    let pending = try #require(try AntigravityAccountRegistry.load(rootURL: root))
    #expect(pending.accessState == .pending && keys.stored == [pending.configuration.authGeneration])
    #expect(throws: (any Error).self) { try AntigravityAccountRegistry.validateKnownGeneration(pending.configuration, rootURL: root) }
    let shutdown = Task { await account.shutdown() }
    await peer.releaseApply(); await shutdown.value
    let saved = try #require(try AntigravityAccountRegistry.load(rootURL: root))
    #expect(saved.accessState == .verified && saved.configuration == account.configuration)
    try AntigravityAccountRegistry.validateKnownGeneration(saved.configuration, rootURL: root)
    #expect(await peer.authentications == 1 && keys.readCount == 0)
    let reopened = AntigravityAccountStore(stateRoot: root, sessionFactory: { _, _, _ in peer }, credentials: keys.access)
    #expect(reopened.configuration == saved.configuration && reopened.accessState == .verified)
    #expect(reopened.state.models.isEmpty && !reopened.runtimeChecked)
    await reopened.shutdown()
}

@Test @MainActor func nativeAntigravityRuntimeCheckDoesNotRequireAnAccountAndADCDoesNotReuseAHiddenKey() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-antigravity-method-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let peer = NativeAntigravityAccountPeer(), keys = NativeAntigravityKeyRecorder()
    let account = AntigravityAccountStore(stateRoot: root, sessionFactory: { _, key, handler in
        #expect(key == nil)
        return peer
    }, credentials: keys.access)
    account.bind(beginLease: { _ in UUID() }, endLease: { _ in }, apply: { _ in })
    account.authMethod = .oauthBusiness
    #expect(account.selectedConfiguration == nil && account.runtimeConfiguration != nil)
    await account.checkRuntime()
    #expect(account.runtimeChecked && account.accessState == nil && !account.canStart)
    let healthChecks = await peer.healthChecks, authentications = await peer.authentications
    #expect(healthChecks == 1 && authentications == 0)
    account.runtimeSelection = .external
    account.executable = "/task-owned/other-server"
    #expect(!account.runtimeChecked)
    account.authMethod = .agentPlatform; account.agentPlatformCredentialMode = .project
    account.gcpProject = "isolated-project"; account.gcpLocation = "us-central1"
    account.apiKey = "ignored-hidden-native-fixture-key"; account.reuseStoredCredential = true
    #expect(account.canStart && !account.requiresAPIKey && !account.canReuseStoredCredential)
    await account.signIn()
    try await waitNativeAntigravity { account.state.phase == .succeeded }
    #expect(account.configuration.gcpProject == "isolated-project" && keys.stored.isEmpty && keys.readCount == 0)
    await account.shutdown()
}

private func nativeAntigravityPermission(question: Bool, long: Bool = false) throws -> AntigravityPermissionRequest {
    try .init(params: .object([
        "sessionId": .string("native-session"),
        "toolCall": .object(["toolCallId": .string(question ? "interaction_native" : "write-native"),
            "title": .string(long ? String(repeating: "Review exact workspace changes 工作 مرحبًا 🌍\n", count: 40) : "Review workspace access")]),
        "options": .array([
            .object(["optionId": .string("allow-one-exact"), "name": .string(long ? String(repeating: "Allow this exact operation 工作 🌍 ", count: 12) : "Allow this operation"), "kind": .string("allow_once")]),
            .object(["optionId": .string("allow-persistent-exact"), "name": .string("Always allow this scope"), "kind": .string("allow_always"),
                "_meta": .object(["agy.security.warning": .object(["message": .string(long ? String(repeating: "This grants persistent access to the reviewed scope. مرحبًا 工作\n", count: 10) : "This grants persistent access to the reviewed scope.")])])]),
            .object(["optionId": .string("deny-exact"), "name": .string("Decline"), "kind": .string("reject_once")])])
    ]))
}

@Test @MainActor func nativeAntigravityPermissionKeepsExactOfferedChoicesWarningsAndPendingFence() throws {
    for question in [false, true] {
        let native = try nativeAntigravityPermission(question: question)
        let presentation = try AntigravityPermissionRequest.presentation(native.approval(localID: .number(7)))
        #expect(presentation.options == native.options && presentation.isQuestion == question)
        #expect(presentation.options[1].securityWarning == "This grants persistent access to the reviewed scope.")
        var choices: [String] = [], cancellations = 0
        let view = AntigravityPermissionView(request: presentation, isResponding: false,
            onOption: { choices.append($0) }, onCancel: { cancellations += 1 })
        #expect(choices.isEmpty && cancellations == 0)
        view.choose("unoffered"); #expect(choices.isEmpty)
        view.choose("allow-persistent-exact"); view.cancel()
        #expect(choices == ["allow-persistent-exact"] && cancellations == 1)
        let pending = AntigravityPermissionView(request: presentation, isResponding: true,
            onOption: { choices.append($0) }, onCancel: { cancellations += 1 })
        pending.choose("deny-exact"); pending.cancel()
        #expect(choices == ["allow-persistent-exact"] && cancellations == 1)
        #expect(try presentation.response(optionID: nil)["outcome"]["outcome"] == .string("cancelled"))
    }
}

@Test @MainActor func nativeAntigravityUncertainLogoutDowngradesOnlyItsExactRegistryGeneration() async throws {
    for replaced in [false, true] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-antigravity-signout-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = AntigravityConfiguration(authGeneration: UUID()), other = AntigravityConfiguration(authGeneration: UUID())
        try AntigravityAccountRegistry.save(.init(configuration: source, accessState: .verified), rootURL: root)
        let peer = NativeAntigravityAccountPeer(holdLogout: true), keys = NativeAntigravityKeyRecorder()
        let account = AntigravityAccountStore(stateRoot: root, sessionFactory: { _, _, _ in peer }, credentials: keys.access)
        account.bind(beginLease: { _ in UUID() }, endLease: { _ in }, apply: { _ in Issue.record("Unknown logout must not apply a new generation.") })
        await account.signOut()
        try await waitNativeAntigravity { await peer.logouts == 1 }
        if replaced { try AntigravityAccountRegistry.save(.init(configuration: other, accessState: .verified), rootURL: root) }
        await account.cancel()
        try await waitNativeAntigravity { account.state.phase == .unconfirmed }
        let saved = try #require(try AntigravityAccountRegistry.load(rootURL: root))
        #expect(saved.configuration == (replaced ? other : source))
        #expect(saved.accessState == (replaced ? .verified : .pending))
        await account.signOut()
        #expect(await peer.logouts == 1)
        await account.shutdown()
    }
}

@Test @MainActor func nativeAntigravityPermissionsAndAccountFormSupportNarrowLongRTLLayouts() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-antigravity-render-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let peer = NativeAntigravityAccountPeer(), keys = NativeAntigravityKeyRecorder()
    let account = AntigravityAccountStore(stateRoot: root, sessionFactory: { _, _, _ in peer }, credentials: keys.access)
    account.authMethod = .oauthBusiness
    for width in [320.0, 680.0] {
        for dark in [false, true] {
            for rtl in [false, true] {
                for question in [false, true] {
                    let content = AntigravityPermissionView(request: try nativeAntigravityPermission(question: question, long: true),
                        isResponding: false, onOption: { _ in }, onCancel: {})
                    try captureAntigravity(content, name: question ? "question" : "permission", width: width, dark: dark, rtl: rtl)
                }
                try captureAntigravity(Form { AntigravitySettingsSection(account: account) }.formStyle(.grouped),
                    name: "account", width: width, dark: dark, rtl: rtl)
            }
        }
    }
    await account.shutdown()
}
@MainActor private func captureAntigravity<V: View>(_ content: V, name: String, width: CGFloat, dark: Bool, rtl: Bool) throws {
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    let previous = NSApp.appearance; NSApp.appearance = appearance; defer { NSApp.appearance = previous }
    appearance.performAsCurrentDrawingAppearance {
        let view = NSHostingView(rootView: content.padding(16).frame(width: width, height: 600, alignment: .topLeading)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = appearance; view.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        view.layoutSubtreeIfNeeded()
        #expect(view.bounds.width == width && view.bounds.height == 600)
        guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_ANTIGRAVITY"] == "1",
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            let file = "coincide-antigravity-\(name)-\(Int(width))-\(dark ? "dark" : "light")-\(rtl ? "rtl" : "ltr").png"
            try? png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(file))
        }
    }
}
