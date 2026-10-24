import Foundation

extension WorkspaceStore {
    /// Menu commands, the rail, model picker, and local control share one route.
    func showSettings(_ page: SettingsPage? = nil) {
        if let page { settingsPage = page }
        modelPickerPresented = false
        showingSettings = true
    }

    /// Returning from Settings preserves the selected conversation and its draft.
    func showChat() {
        modelPickerPresented = false
        showingSettings = false
    }
}
