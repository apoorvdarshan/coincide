import Foundation

extension WorkspaceDecision {
    /// Stashing, restoring and attaching a converted paste are draft mutations.
    /// They never start a provider or consume a pending context-transfer intent.
    mutating func replaceComposerDraft(_ replacement: ComposerDraftReplacement) throws {
        let expected = replacement.expected
        guard replacement.text.utf8.count <= 8 * 1_024 * 1_024,
              let index = snapshot.threads.firstIndex(where: { $0.id == expected.threadID }),
              !snapshot.threads[index].isArchived else {
            throw WorkspaceCommandError("The draft is unavailable or exceeds its bounded storage limit.")
        }
        try AttachmentLimits.validate(expected.attachments)
        try AttachmentLimits.validate(replacement.attachments)
        let thread = snapshot.threads[index]
        let current = ComposerDraftSnapshot(threadID: thread.id, projectID: thread.projectID,
            workspacePath: thread.workspacePath, text: thread.draft, attachments: thread.draftAttachments)
        guard expected.matches(current) else {
            throw WorkspaceCommandError("The composer changed. Your current draft and saved prompt were kept.")
        }
        snapshot.threads[index].draft = replacement.text
        snapshot.threads[index].draftAttachments = replacement.attachments
    }
}
