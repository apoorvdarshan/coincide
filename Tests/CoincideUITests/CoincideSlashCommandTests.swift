import CoincideCore
import Foundation
import Testing
@testable import Coincide

@MainActor @Test func appSlashCommandsNeverConsumeProviderCommandsOrArguments() {
    #expect(CoincideSlashCommand.parse(" /app:model \n") == .model)
    #expect(CoincideSlashCommand.parse("/app:compact") == .compact)
    for value in ["/model", "/compact", "/mcp", "/app:model gpt", "/app:settings\nkeep this draft", "/app:unknown"] {
        #expect(CoincideSlashCommand.parse(value) == nil)
    }
    let rows = ProviderCommandPicker.matching(commands: [], skills: [], query: "model", showSkills: false, appCommands: true)
    #expect(rows == [.app(.model)])
    #expect(ProviderCommandPicker.matching(commands: [], skills: [], query: "model", showSkills: false).isEmpty)
}

@MainActor @Test func appSlashSuggestionsReserveTheirNamespaceWithoutRenamingProviderCommands() {
    let commands = ["model", "mcp", "compact", "app:settings", "app:unknown", "app:plugin:action", "APP:settings"]
        .map { ProviderCommand(name: $0, source: "fixture") }
    let rows = ProviderCommandPicker.matching(commands: commands, skills: [], query: "", showSkills: false, appCommands: true)
    let native = rows.compactMap { row -> String? in
        guard case .command(let command) = row else { return nil }
        return command.name
    }
    #expect(native == ["model", "mcp", "compact", "APP:settings"])
    #expect(rows.filter { $0.token == "/app:settings" } == [.app(.settings)])
    #expect(!rows.contains { $0.token == "/app:unknown" || $0.token == "/app:plugin:action" })
    // Case and namespaces remain provider-owned outside the exact reserved
    // app prefix. A picker without app routing offers its entire native catalog.
    #expect(CoincideSlashCommand.parse("/APP:settings") == nil)
    let providerOnly = ProviderCommandPicker.matching(commands: commands, skills: [], query: "", showSkills: false)
    #expect(providerOnly == commands.map(ProviderComposerSuggestion.command))
    #expect(ProviderCommandPicker.matching(commands: commands, skills: [], query: "app:settings", showSkills: false, appCommands: true)
        .filter { $0.token == "/app:settings" } == [.app(.settings)])
}

@MainActor @Test func appNavigationCommandsPreserveConversationAndDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-app-command-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(databaseURL: root.appendingPathComponent("workspace.sqlite"), appMCPEnabled: false)
    let project = WorkspaceProject(path: root.path)
    var thread = CodingThread(project: project)
    thread.draft = "Keep this unsent draft"
    store.snapshot.projects = [project]; store.snapshot.threads = [thread]; store.selectedThreadID = thread.id
    for command in CoincideSlashCommand.allCases where command.settingsPage != nil {
        store.runAppCommand(command)
        #expect(store.showingSettings)
        #expect(store.settingsPage == command.settingsPage)
        #expect(store.selectedThread?.draft == "Keep this unsent draft")
    }
    store.runAppCommand(.model)
    #expect(store.modelPickerPresented && !store.showingSettings)
    #expect(store.snapshot.threads.count == 1 && store.selectedThread?.draft == "Keep this unsent draft")
    #expect(await store.submit("/app:settings", threadID: thread.id).value == false)
    #expect(await store.steer("/app:unknown", threadID: thread.id).value == false)
    #expect(store.selectedThread?.draft == "Keep this unsent draft")
    await store.shutdown()
}
