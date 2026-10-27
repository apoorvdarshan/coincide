import Foundation

/// Builds `session/prompt` content the way T3 Code does for ACP agents: the user's text with a
/// note for each attachment, Coincide's interaction-mode instructions when they change, and
/// images inline when the agent accepts them.
public enum ACPPrompt {
    /// Image types most agents accept inline (T3 Code's provider-wide list).
    public nonisolated static let commonImageTypes = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
    ]
    public nonisolated static let maxImageBytes = 10 * 1024 * 1024

    /// ACP has no system prompt, so the interaction mode travels with the first prompt of a
    /// session and with every prompt that changes it. Native slash commands stay untouched.
    public nonisolated static func text(_ text: String, mode: InteractionMode, previousMode: InteractionMode?) -> String {
        guard previousMode != mode, !isSlashCommand(text) else { return text }
        return "<coincide_instructions>\n\(instructions(for: mode))\n</coincide_instructions>\n\n<user_request>\n\(text)\n</user_request>"
    }

    /// The prompt's text blocks: the handoff recap in front of the message, wrapped in the interaction-mode
    /// instructions when they are due. A native slash command stays untouched, so after a recap it travels
    /// as a block of its own, last. `instructed` says the instructions were included.
    public nonisolated static func texts(
        message: String, recap: String?, mode: InteractionMode, previousMode: InteractionMode?
    ) -> (blocks: [String], instructed: Bool) {
        if isSlashCommand(message) {
            guard let recap, !recap.isEmpty else { return ([message], false) }
            return ([recap, message], false)
        }
        let combined = Handoff.compose(message: message, recap: recap)
        let wrapped = text(combined, mode: mode, previousMode: previousMode)
        return ([wrapped], wrapped != combined)
    }

    public nonisolated static func isSlashCommand(_ text: String) -> Bool {
        text.drop(while: \.isWhitespace).hasPrefix("/")
    }

    nonisolated static func instructions(for mode: InteractionMode) -> String {
        switch mode {
        case .build:
            """
            ## Coincide interaction mode: Default

            Prefer making reasonable assumptions and carrying out the user's request. Ask a concise question only when a missing user decision would materially change the result. Treat this mode as active until Coincide supplies a different interaction-mode instruction.
            """
        case .plan:
            """
            ## Coincide interaction mode: Plan

            Investigate with read-only actions and do not edit files or otherwise execute the implementation. Resolve discoverable facts before asking questions. When the requirements are decision complete, return a concrete implementation plan and do not start implementing it. Treat this mode as active until Coincide supplies a different interaction-mode instruction.
            """
        }
    }

    /// The user's text followed by a note naming each attached image's path, so the agent can
    /// open it even when the image is also sent inline.
    public nonisolated static func messageText(_ text: String, imagePaths: [String]) -> String {
        imagePaths.reduce(text) { text, path in
            let note = "[Attached image \"\((path as NSString).lastPathComponent)\" is saved at: \(path)]"
            return text.isEmpty ? note : "\(text)\n\n\(note)"
        }
    }

    /// An inline image block, or nil when the type is not accepted or the file is unreadable or too large.
    public nonisolated static func imageBlock(_ path: String, types: [String: String]) -> ACPContentBlock? {
        guard let mimeType = types[(path as NSString).pathExtension.lowercased()],
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            (attributes[.size] as? NSNumber)?.intValue ?? 0 <= maxImageBytes,
            let data = FileManager.default.contents(atPath: path), !data.isEmpty, data.count <= maxImageBytes
        else { return nil }
        return .image(mimeType: mimeType, data: data.base64EncodedString(), uri: nil)
    }
}
