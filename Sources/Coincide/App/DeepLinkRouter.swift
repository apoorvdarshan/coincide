import AppKit
import CoincideCore

/// Routes `coincide://` links (docs/DESKTOP_SHELL.md). A link only places text in a draft or
/// opens a folder; the person reads the draft and sends it. Existing drafts are replaced
/// or extended only after confirmation.
@MainActor
final class DeepLinkRouter {
    enum DraftChoice: Sendable { case replace, append, cancel }
    enum Outcome: Equatable {
        case openedDraft(threadID: UUID)
        case selectedThread(UUID)
        case rejected(String)
        case cancelled
    }
    private let store: WorkspaceStore
    private let banners: InAppBannerCenter
    private let confirmDraftReplacement: @MainActor (_ threadTitle: String) async -> DraftChoice
    private let providerAvailable: (@MainActor (ProviderKind) -> Bool)?

    init(store: WorkspaceStore, banners: InAppBannerCenter,
         confirmDraftReplacement: @escaping @MainActor (String) async -> DraftChoice = DeepLinkRouter.askAboutExistingDraft,
         providerAvailable: (@MainActor (ProviderKind) -> Bool)? = nil) {
        self.store = store; self.banners = banners; self.confirmDraftReplacement = confirmDraftReplacement
        self.providerAvailable = providerAvailable
    }

    static func isDeepLink(_ url: URL) -> Bool { url.scheme?.lowercased() == PromptLink.scheme }

    @discardableResult
    func open(_ url: URL) async -> Outcome {
        guard !Task.isCancelled else { return .cancelled }
        switch PromptLink.parse(url) {
        case .failure(let error): return reject(error.localizedDescription)
        case .success(let link):
            do { return try await route(link) }
            catch is CancellationError { return .cancelled }
            catch { return reject(error.localizedDescription) }
        }
    }

    private func reject(_ message: String) -> Outcome {
        banners.post(.error, title: String(localized: "Link not opened"), detail: message, key: "deep-link")
        return .rejected(message)
    }

    private func warnHidden(_ prompt: PromptLink.Prompt?) {
        guard let prompt, prompt.hiddenCharacters > 0 else { return }
        banners.post(.warning, title: String(localized: "Hidden characters removed"),
                     detail: String(localized: "This prompt contained \(prompt.hiddenCharacters) characters you could not see. It may be malicious; read the draft before sending it."),
                     key: "deep-link-hidden")
    }

    private func route(_ link: PromptLink.Link) async throws -> Outcome {
        try Task.checkCancellation()
        switch link {
        case .openFolder(let path):
            let folder = URL(fileURLWithPath: path)
            if let project = store.snapshot.projects.first(where: { $0.path.utf8.elementsEqual(WorkspaceProject(path: path).path.utf8) }),
               let empty = store.snapshot.threads.first(where: { $0.projectID == project.id && !$0.isArchived && $0.messages.isEmpty
                   && !$0.isBusy && $0.queuedTurns.isEmpty && $0.workspacePath.utf8.elementsEqual(project.path.utf8)
                   && $0.draftAttachments.isEmpty && store.snapshot.workspaceReady(for: $0)
                   && (store.thread($0.id)?.draft ?? $0.draft).isEmpty }) {
                select(empty); return .selectedThread(empty.id)
            }
            return .openedDraft(threadID: try await store.openDraftThread(projectID: nil, folder: folder, draft: ""))
        case let .newThread(prompt, repository, provider, model):
            guard let project = project(for: repository) else { return reject(String(localized: "Add a project before opening prompt links.")) }
            let requested = requestedProvider(provider, workspacePath: project.path)
            let id = try await store.openDraftThread(projectID: project.id, folder: nil, draft: prompt.text,
                requestedProvider: requested, requestedModel: requested == nil ? nil : model)
            try Task.checkCancellation()
            warnHidden(prompt)
            if requested != nil, let model, store.thread(id)?.model.isEmpty == true {
                banners.post(.info, title: String(localized: "Using the default model"),
                    detail: String(localized: "“\(model)” is not in this agent's loaded model list. Refresh models in Settings to choose it."), key: "deep-link-model")
            }
            return .openedDraft(threadID: id)
        case let .pullRequest(pullRequest, prompt):
            guard let project = project(for: pullRequest.repository) else { return reject(String(localized: "Add a project before opening prompt links.")) }
            let id = try await store.openDraftThread(projectID: project.id, folder: nil, draft: prompt?.text ?? "")
            try Task.checkCancellation()
            warnHidden(prompt)
            banners.post(.info, title: String(localized: "Pull request #\(pullRequest.number)"),
                         detail: String(localized: "This link opened a draft for \(pullRequest.repository.slug)#\(pullRequest.number). It did not check out code or send a message."),
                         key: "deep-link-pr")
            return .openedDraft(threadID: id)
        case let .thread(id, prompt):
            guard let thread = store.thread(id), store.snapshot.projects.contains(where: { $0.id == thread.projectID }) else {
                return reject(String(localized: "This conversation is not in this workspace."))
            }
            select(thread)
            guard let prompt else { return .selectedThread(id) }
            guard let expected = store.composerDraftSnapshot(id) else { return reject(String(localized: "This conversation is not in this workspace.")) }
            if expected.text.utf8.elementsEqual(prompt.text.utf8) {
                warnHidden(prompt); return .selectedThread(id)
            }
            var text = prompt.text
            if !expected.text.isEmpty || !expected.attachments.isEmpty {
                switch await confirmDraftReplacement(thread.title) {
                case .cancel: return .cancelled
                case .append: text = expected.text + (expected.text.isEmpty ? "" : expected.text.hasSuffix("\n") ? "\n" : "\n\n") + prompt.text
                case .replace: break
                }
            }
            try Task.checkCancellation()
            guard let current = store.thread(id), current.createdAt == thread.createdAt,
                  let currentDraft = store.composerDraftSnapshot(id), currentDraft.matches(expected) else {
                return reject(String(localized: "The conversation or draft changed while the link was waiting. Your current draft was kept."))
            }
            let replacement = ComposerDraftReplacement(expected: expected, text: text, attachments: expected.attachments)
            switch await store.replaceComposerDraft(id: UUID(), replacement: replacement) {
            case .applied: break
            case .rejected:
                return reject(String(localized: "The conversation or draft changed while the link was waiting. Your current draft was kept."))
            case .unknown:
                return reject(String(localized: "The draft result could not be confirmed. Check the current draft before opening the link again."))
            }
            warnHidden(prompt)
            return .selectedThread(id)
        }
    }

    private func select(_ thread: CodingThread) {
        store.selectThread(thread.id)
    }

    /// The most recently active project for the repository (forks count only for their
    /// own owner), otherwise the current project with a note.
    private func project(for repository: PromptLink.Repository?) -> WorkspaceProject? {
        let projects = store.snapshot.projects.filter { $0.clone?.isReady ?? true }
        func activity(_ project: WorkspaceProject) -> Date {
            store.snapshot.threads.filter { $0.projectID == project.id }.map(\.updatedAt).max() ?? project.updatedAt ?? .distantPast
        }
        let current = (store.selectedProjectID ?? store.selectedThread?.projectID).flatMap { id in projects.first { $0.id == id } }
            ?? projects.max { activity($0) < activity($1) }
        guard let repository else { return current }
        if let match = projects.filter({ $0.repositoryIdentity?.canonicalKey == repository.canonicalKey }).max(by: { activity($0) < activity($1) }) {
            return match
        }
        if let current {
            banners.post(.info, title: String(localized: "\(repository.slug) is not open in Coincide"),
                         detail: String(localized: "The draft opened in \(current.name). Add or clone the repository to work on it."), key: "deep-link-repo")
        }
        return current
    }

    private static let providerAliases: [String: ProviderKind] = [
        "codex": .codex, "claude": .claude, "claudeagent": .claude, "claude-code": .claude,
    ]

    /// Availability is captured before creation. The Store captures the requested
    /// provider and scoped advertised model in the original create command.
    private func requestedProvider(_ provider: String?, workspacePath: String) -> ProviderKind? {
        guard let provider else { return nil }
        guard let kind = Self.providerAliases[provider],
              providerAvailable?(kind) ?? store.promptLinkProviderAvailable(kind, workspacePath: workspacePath) else {
            banners.post(.info, title: String(localized: "Using your default agent"),
                         detail: String(localized: "The link asked for “\(provider)”, which is not set up on this Mac."), key: "deep-link-provider")
            return nil
        }
        return kind
    }

    static func askAboutExistingDraft(_ threadTitle: String) async -> DraftChoice {
        let alert = NSAlert()
        alert.messageText = String(localized: "Replace the draft in “\(threadTitle)”?")
        alert.informativeText = String(localized: "A link wants to put a prompt in this conversation's composer. Nothing is sent until you press Send.")
        alert.addButton(withTitle: String(localized: "Replace Draft"))
        alert.addButton(withTitle: String(localized: "Add to Draft"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .append
        default: return .cancel
        }
    }
}
