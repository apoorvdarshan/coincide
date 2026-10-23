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
    private let providerAvailable: @MainActor (ProviderKind) -> Bool
    private let settleTimeout: Duration

    init(store: WorkspaceStore, banners: InAppBannerCenter,
         confirmDraftReplacement: @escaping @MainActor (String) async -> DraftChoice = DeepLinkRouter.askAboutExistingDraft,
         providerAvailable: @escaping @MainActor (ProviderKind) -> Bool = { ProcessChannel.findExecutable($0.executable) != nil },
         settleTimeout: Duration = .seconds(3)) {
        self.store = store; self.banners = banners; self.confirmDraftReplacement = confirmDraftReplacement
        self.providerAvailable = providerAvailable; self.settleTimeout = settleTimeout
    }

    static func isDeepLink(_ url: URL) -> Bool { url.scheme?.lowercased() == PromptLink.scheme }

    @discardableResult
    func open(_ url: URL) async -> Outcome {
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
        switch link {
        case .openFolder(let path):
            let folder = URL(fileURLWithPath: path)
            if let project = store.snapshot.projects.first(where: { $0.path == WorkspaceProject(path: path).path }),
               let empty = store.snapshot.threads.first(where: { $0.projectID == project.id && !$0.isArchived && $0.messages.isEmpty
                   && !$0.isBusy && $0.queuedTurns.isEmpty && (store.thread($0.id)?.draft ?? $0.draft).isEmpty }) {
                select(empty); return .selectedThread(empty.id)
            }
            return .openedDraft(threadID: try await store.openDraftThread(projectID: nil, folder: folder, draft: ""))
        case let .newThread(prompt, repository, provider, model):
            guard let project = project(for: repository) else { return reject(String(localized: "Add a project before opening prompt links.")) }
            let id = try await store.openDraftThread(projectID: project.id, folder: nil, draft: prompt.text)
            warnHidden(prompt)
            await applyProvider(provider, model: model, threadID: id)
            return .openedDraft(threadID: id)
        case let .pullRequest(pullRequest, prompt):
            guard let project = project(for: pullRequest.repository) else { return reject(String(localized: "Add a project before opening prompt links.")) }
            let id = try await store.openDraftThread(projectID: project.id, folder: nil, draft: prompt?.text ?? "")
            warnHidden(prompt)
            banners.post(.info, title: String(localized: "Pull request #\(pullRequest.number)"),
                         detail: String(localized: "Links never check out code. Open Pull Requests to check out \(pullRequest.repository.slug)#\(pullRequest.number) before sending."),
                         key: "deep-link-pr")
            return .openedDraft(threadID: id)
        case let .thread(id, prompt):
            guard let thread = store.thread(id), store.snapshot.projects.contains(where: { $0.id == thread.projectID }) else {
                return reject(String(localized: "This conversation is not in this workspace."))
            }
            select(thread)
            guard let prompt else { return .selectedThread(id) }
            let existing = thread.draft
            var text = prompt.text
            if !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, existing != prompt.text {
                switch await confirmDraftReplacement(thread.title) {
                case .cancel: return .cancelled
                case .append: text = existing + (existing.hasSuffix("\n") ? "\n" : "\n\n") + prompt.text
                case .replace: break
                }
            }
            guard store.thread(id) != nil else { return reject(String(localized: "This conversation is not in this workspace.")) }
            store.setDraft(text, id: id)
            warnHidden(prompt)
            return .selectedThread(id)
        }
    }

    private func select(_ thread: CodingThread) {
        store.selectedProjectID = thread.projectID; store.showArchived = thread.isArchived; store.selectedThreadID = thread.id
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
        "codex": .codex, "claude": .claude, "claudeagent": .claude, "claude-code": .claude, "opencode": .opencode,
        "pi": .pi, "muse": .muse, "antigravity": .antigravity,
    ]

    /// Uses the provider and model only when they are set up here; otherwise the defaults stay and a banner says so.
    private func applyProvider(_ provider: String?, model: String?, threadID: UUID) async {
        guard let provider else { return }
        guard let kind = Self.providerAliases[provider], providerAvailable(kind) else {
            banners.post(.info, title: String(localized: "Using your default agent"),
                         detail: String(localized: "The link asked for “\(provider)”, which is not set up on this Mac."), key: "deep-link-provider")
            return
        }
        if store.thread(threadID)?.provider != kind {
            store.setProvider(kind, id: threadID)
            let deadline = ContinuousClock.now + settleTimeout
            while store.thread(threadID).map({ $0.provider != kind }) == true, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        guard let model, let thread = store.thread(threadID), thread.provider == kind else { return }
        let lowered = model.lowercased()
        if let row = store.models(for: thread).first(where: { $0.id.lowercased() == lowered || $0.name.lowercased() == lowered || $0.catalogID?.lowercased() == lowered }) {
            store.setModel(row.id, id: threadID)
        } else {
            banners.post(.info, title: String(localized: "Using the default model"),
                         detail: String(localized: "“\(model)” is not in this agent's loaded model list. Refresh models in Settings to choose it."), key: "deep-link-model")
        }
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
