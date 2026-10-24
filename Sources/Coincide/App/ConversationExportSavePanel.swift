import AppKit
import CoincideCore
import UniformTypeIdentifiers

@MainActor
enum ConversationExportSavePanel {
    /// Capture the app-owned conversation before opening the panel. Selecting a
    /// different conversation or receiving a new token cannot change this export.
    static func present(thread: CodingThread, format: ConversationExportFormat, window: NSWindow?,
                        onError: @escaping @MainActor (String) -> Void) {
        guard let window, window.isVisible, !window.isMiniaturized, window.attachedSheet == nil else {
            onError(String(localized: "Open the conversation window and close its current sheet before exporting."))
            return
        }
        Task {
            do {
                let artifact = try await Task.detached(priority: .userInitiated) {
                    try ConversationExport.make(thread: thread, format: format)
                }.value
                // Never fall back to the current/key window after the await: it
                // may be another conversation or on the user's other display.
                guard window.isVisible, !window.isMiniaturized, window.attachedSheet == nil else { return }
                let panel = NSSavePanel()
                panel.title = String(localized: "Export conversation")
                panel.nameFieldStringValue = artifact.suggestedFilename
                panel.allowedContentTypes = [format == .json ? .json : (UTType(filenameExtension: "md") ?? .plainText)]
                panel.canCreateDirectories = true
                panel.isExtensionHidden = false
                panel.message = artifact.truncatedToolMessages > 0
                    ? String(localized: "Visible conversation text and attachment details. Long tool output will be shortened and marked in the export.")
                    : String(localized: "Visible conversation text and attachment details. Attachment files and private reasoning are excluded.")
                let completion: (NSApplication.ModalResponse) -> Void = { response in
                    guard response == .OK, let url = panel.url else { return }
                    do {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        try artifact.data.write(to: url, options: .atomic)
                    } catch { onError(error.localizedDescription) }
                }
                panel.beginSheetModal(for: window, completionHandler: completion)
            } catch { onError(error.localizedDescription) }
        }
    }
}
