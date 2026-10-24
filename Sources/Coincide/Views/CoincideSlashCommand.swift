import Foundation

/// App navigation has its own namespace so a CLI command of the same name is
/// never intercepted or submitted to the model by accident.
enum CoincideSlashCommand: String, CaseIterable, Identifiable {
    case new, model, compact, settings, skills, commands, mcp, plugins, hooks, configuration, sessions, help
    var id: String { rawValue }
    var name: String { "app:" + rawValue }
    var token: String { "/" + name }
    var detail: String {
        switch self {
        case .new: "Start a new Coincide chat in this project"
        case .model: "Choose a model from your connected agents"
        case .compact: "Review compacting the active provider's context"
        case .settings: "Open Coincide settings"
        case .skills: "Browse and import skills"
        case .commands: "Browse and import reusable commands"
        case .mcp: "Manage configured MCP servers"
        case .plugins: "Browse installed plugins"
        case .hooks: "Inspect configured agent hooks"
        case .configuration: "Edit native CLI configuration"
        case .sessions: "Inspect provider-owned agent sessions"
        case .help: "View keyboard shortcuts and commands"
        }
    }
    var settingsPage: SettingsPage? {
        switch self {
        case .new, .model, .compact: nil
        case .settings: .general
        case .help: .keyboard
        default: SettingsPage(rawValue: rawValue)
        }
    }
    static func parse(_ text: String) -> Self? {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first { $0.token == token }
    }
}

extension WorkspaceStore {
    func runAppCommand(_ command: CoincideSlashCommand) {
        switch command {
        case .new: newThread(projectID: selectedProject?.id)
        case .model: showChat(); modelPickerPresented = true
        case .compact:
            guard let id = selectedThreadID else { errorMessage = "Select a conversation before compacting its context."; return }
            showChat(); requestContextCompaction(threadID: id)
        default: if let page = command.settingsPage { showSettings(page) }
        }
    }
}
