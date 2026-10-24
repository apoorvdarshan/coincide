import AppKit
import CoincideCore
import SwiftUI
import Testing
@testable import Coincide

@MainActor private func waitACPUI(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The native agent UI did not settle") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func legacyAgentSettingsRejectNewAdmissionAndRemovalKeepsExistingConversationConfiguration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-acp-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("workspace.sqlite")
    var agent = ACPAgentConfiguration(name: "Native Fixture", executable: "/usr/bin/true", arguments: ["path with spaces", "$(literal)"])
    agent.experimentalV2 = true
    let project = WorkspaceProject(path: root.path)
    var legacy = CodingThread(project: project); legacy.provider = .acp; legacy.acpAgent = agent
    let supported = CodingThread(project: project)
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [legacy, supported]; snapshot.acpAgents = [agent]
    try WorkspaceJournal.validate(snapshot)
    try await WorkspaceDatabase(url: database).save(snapshot, event: "legacy.acp.ui.fixture")
    let store = WorkspaceStore(databaseURL: database)
    await store.load()
    do {
        #expect(store.snapshot.acpAgents == [agent])
        let id = legacy.id
        store.setACPAgent(agent, id: supported.id)
        #expect(store.thread(supported.id)?.provider == .codex && store.thread(supported.id)?.acpAgent == nil)
        #expect(store.errorMessage?.contains("Codex and Claude only") == true)
        store.setAgentConfig("reasoning", value: "high", id: id)
        try await waitACPUI { store.thread(id)?.agentConfigValues?["reasoning"] == "high" }
        store.setAgentConfiguration("boolean", value: .bool(true), id: id)
        try await waitACPUI { store.thread(id)?.agentConfiguration?["boolean"] == .bool(true) }
        if ProcessInfo.processInfo.environment["COINCIDE_RENDER_ACP"] == "1" { try await captureACPSettings(store) }
        var updated = agent; updated.name = "Edited Fixture"; updated.arguments = ["different"]
        await #expect(throws: WorkspaceCommandError.self) { try await store.saveACPAgent(updated) }
        #expect(store.snapshot.acpAgents == [agent] && store.thread(id)?.acpAgent == agent)
        #expect(store.errorMessage?.contains("Codex and Claude only") == true)
        store.removeACPAgent(agent.id); try await waitACPUI { store.snapshot.acpAgents.isEmpty }
        #expect(store.thread(id)?.acpAgent == agent)
        await store.shutdown()
        let reopened = WorkspaceStore(databaseURL: database)
        await reopened.load()
        #expect(reopened.thread(id)?.acpAgent == agent && reopened.thread(id)?.providerName == "Native Fixture")
        #expect(reopened.thread(id)?.agentConfigValues?["reasoning"] == "high")
        #expect(reopened.thread(id)?.agentConfiguration?["boolean"] == .bool(true) && reopened.thread(id)?.acpAgent?.experimentalV2 == true)
        reopened.resetAgentOptions(id)
        try await waitACPUI { reopened.thread(id)?.agentConfiguration == nil && reopened.thread(id)?.agentConfigValues == nil }
        await reopened.shutdown()
    } catch { await store.shutdown(); throw error }
}

@MainActor private func captureACPSettings(_ store: WorkspaceStore) async throws {
    _ = NSApplication.shared
    for scheme in [ColorScheme.light, .dark] {
        let hosting = NSHostingView(rootView: SettingsView(store: store).environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 700, height: 560), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-acp-settings-\(scheme == .light ? "light" : "dark").png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: path)
        print("Native ACP settings preview: \(path.path)"); window.close()
    }
}
