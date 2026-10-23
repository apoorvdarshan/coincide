import SwiftUI

/// Prompt-link copy items in Edit and setup/licenses items in Help.
@MainActor
struct DesktopShellCommands: Commands {
    let store: WorkspaceStore
    let shell: DesktopShell
    @FocusedValue(\.remoteWorkspacePresentation) private var remotePresentation: RemoteWorkspacePresentation?

    private var hasDraft: Bool {
        remotePresentation == nil && store.selectedThread.map { !$0.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
    }

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Prompt Link") { shell.copyPromptLink(includeContext: false) }
                .disabled(!hasDraft)
                .accessibilityIdentifier("copy-prompt-link")
            Button("Copy Prompt Link with Repository and Model") { shell.copyPromptLink(includeContext: true) }
                .disabled(!hasDraft)
            Button("Copy Conversation Link") { shell.copyConversationLink() }
                .disabled(remotePresentation != nil || store.selectedThreadID == nil)
        }
        CommandGroup(after: .help) {
            Button("Welcome to Coincide…") { shell.showWelcome() }
                .disabled(!store.hasLoadedWorkspace)
            Button("Open-Source Licenses") { shell.showLicenses() }
        }
    }
}
