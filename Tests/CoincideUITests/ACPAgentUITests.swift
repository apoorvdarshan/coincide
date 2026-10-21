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

@MainActor @Test(.timeLimit(.minutes(1))) func nativeAgentSettingsSaveSelectEditAndRemoveKeepExistingConversationConfiguration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-acp-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("workspace.sqlite"), store = WorkspaceStore(databaseURL: database)
    await store.load()
    do {
        var agent = ACPAgentConfiguration(name: "Native Fixture", executable: "/usr/bin/true", arguments: ["path with spaces", "$(literal)"])
        agent.experimentalV2 = true
        try await store.saveACPAgent(agent)
        #expect(store.snapshot.acpAgents == [agent])
        store.addProject(at: root); try await waitACPUI { store.snapshot.projects.count == 1 }
        store.newThread(); try await waitACPUI { store.selectedThreadID != nil }
        let id = try #require(store.selectedThreadID)
        store.setACPAgent(agent, id: id); try await waitACPUI { store.thread(id)?.acpAgent == agent }
        store.setAgentConfig("reasoning", value: "high", id: id)
        try await waitACPUI { store.thread(id)?.agentConfigValues?["reasoning"] == "high" }
        store.setAgentConfiguration("boolean", value: .bool(true), id: id)
        try await waitACPUI { store.thread(id)?.agentConfiguration?["boolean"] == .bool(true) }
        if ProcessInfo.processInfo.environment["COINCIDE_RENDER_ACP"] == "1" { try await captureACPSettings(store) }
        var updated = agent; updated.name = "Edited Fixture"; updated.arguments = ["different"]
        try await store.saveACPAgent(updated)
        #expect(store.snapshot.acpAgents == [updated] && store.thread(id)?.acpAgent == agent)
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
