import CoincideCore
import Foundation
import Observation

@MainActor @Observable final class ProviderConfigurationEditorStore {
    struct Destination: Equatable, Sendable {
        let provider: ProviderKind
        let scope: ProviderConfigurationScope
        let sourceURL: URL
    }
    var provider: ProviderKind = .codex
    var scope: ProviderConfigurationScope = .user
    private(set) var document: ProviderConfigurationDocument?
    private(set) var drafts: [String: String] = [:]
    private(set) var isBusy = false
    private(set) var message: String?
    private(set) var errorMessage: String?
    @ObservationIgnored private let editor = ProviderConfigurationEditor()
    @ObservationIgnored private var generation = UUID()
    private struct SourceIdentity: Hashable {
        let provider: String
        let scope: String
        let source: URL
        init(_ document: ProviderConfigurationDocument) {
            provider = document.provider.rawValue; scope = document.scope.rawValue; source = document.sourceURL.standardizedFileURL
        }
        init(provider: ProviderKind, scope: ProviderConfigurationScope, source: URL) {
            self.provider = provider.rawValue; self.scope = scope.rawValue; self.source = source.standardizedFileURL
        }
    }
    private struct PendingDraft {
        let document: ProviderConfigurationDocument
        let values: [String: String]
    }
    @ObservationIgnored private var pendingDrafts: [SourceIdentity: PendingDraft] = [:]

    var changes: [String: String] {
        guard let document else { return [:] }
        return Dictionary(uniqueKeysWithValues: document.fields.compactMap { field in
            guard let draft = drafts[field.id], draft != field.value else { return nil }
            return (field.id, draft)
        })
    }
    var hasChanges: Bool { !changes.isEmpty }
    var groups: [String] {
        document?.fields.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } } ?? []
    }
    func value(_ field: ProviderConfigurationField) -> String { drafts[field.id] ?? field.value }
    func setValue(_ value: String, for field: ProviderConfigurationField) {
        guard !isBusy, field.isEditable else { return }
        drafts[field.id] = value; message = nil; errorMessage = nil
    }
    /// Only route sources this structured editor actually manages. An imported
    /// link from another profile must never silently select the current home.
    static func destination(for item: ProviderIntegrationItem, codex: CodexRuntimeConfiguration,
                            claude: ClaudeRuntimeProfile, workspacePath: String?) -> Destination? {
        guard item.available, item.importMode != .copied,
              item.kind == .mcp || item.kind == .plugins || item.kind == .hooks,
              let scope = ProviderConfigurationScope(rawValue: item.scope.lowercased()),
              let source = try? ProviderConfigurationEditor.sourceURL(provider: item.provider, scope: scope,
                  codex: codex, claude: claude, workspacePath: workspacePath) else { return nil }
        let original = URL(fileURLWithPath: item.sourcePath).standardizedFileURL
        if original == source.standardizedFileURL { return .init(provider: item.provider, scope: scope, sourceURL: source) }
        if item.provider == .claude, item.kind == .plugins,
           let user = try? ProviderConfigurationEditor.sourceURL(provider: .claude, scope: .user,
               codex: codex, claude: claude, workspacePath: workspacePath),
           original == user.deletingLastPathComponent().appendingPathComponent("plugins/installed_plugins.json").standardizedFileURL {
            return .init(provider: .claude, scope: scope, sourceURL: source)
        }
        return nil
    }
    func selectSource(_ destination: Destination, codex: CodexRuntimeConfiguration,
                      claude: ClaudeRuntimeProfile, workspacePath: String?) async throws {
        guard !isBusy else { throw CoincideError("Wait for the current configuration operation to finish.") }
        let source = try ProviderConfigurationEditor.sourceURL(provider: destination.provider, scope: destination.scope,
            codex: codex, claude: claude, workspacePath: workspacePath)
        guard source.standardizedFileURL == destination.sourceURL.standardizedFileURL else {
            throw CoincideError("The integration's configuration source changed. Refresh it before opening settings.")
        }
        provider = destination.provider; scope = destination.scope
        // Navigation retains both the previous draft and any destination draft.
        // Only explicit Reload may replace a captured document/revision.
        await load(codex: codex, claude: claude, workspacePath: workspacePath)
        guard document?.provider == destination.provider, document?.scope == destination.scope,
              document?.sourceURL.standardizedFileURL == source.standardizedFileURL else {
            throw CoincideError(errorMessage ?? "This configuration source is no longer available.")
        }
    }
    func load(codex: CodexRuntimeConfiguration, claude: ClaudeRuntimeProfile, workspacePath: String?, force: Bool = false) async {
        if provider == .codex && scope == .local { scope = .user }
        let requestedURL: URL
        do {
            requestedURL = try ProviderConfigurationEditor.sourceURL(provider: provider, scope: scope, codex: codex, claude: claude, workspacePath: workspacePath)
        } catch {
            retainDraft()
            generation = UUID(); isBusy = false; document = nil; drafts = [:]; message = nil
            errorMessage = (error as? CoincideError)?.message ?? "The selected configuration could not be loaded safely."
            return
        }
        let identity = SourceIdentity(provider: provider, scope: scope, source: requestedURL)
        // Returning to the Settings page must not silently reload over a draft.
        // Source identity includes scope and path, so a runtime/profile change
        // can never present an old document as the new configuration source.
        if !force, let document, SourceIdentity(document) == identity { return }
        retainDraft()
        let token = UUID(); generation = token
        isBusy = true; errorMessage = nil; message = nil; document = nil; drafts = [:]
        defer { if generation == token { isBusy = false } }
        if !force, let pending = pendingDrafts[identity] {
            document = pending.document; drafts = pending.values
            message = "Restored your unsaved changes for this configuration source."
            return
        }
        pendingDrafts.removeValue(forKey: identity)
        do {
            let loaded = try await editor.load(provider: provider, scope: scope, sourceURL: requestedURL)
            guard generation == token, !Task.isCancelled else { return }
            document = loaded; drafts = Dictionary(uniqueKeysWithValues: loaded.fields.map { ($0.id, $0.value) })
        } catch { if generation == token { errorMessage = (error as? CoincideError)?.message ?? "The selected configuration could not be loaded safely." } }
    }
    func save() async {
        guard !isBusy, let document, hasChanges else { return }
        let edits = changes
        let token = generation
        isBusy = true; errorMessage = nil; message = nil
        defer { if generation == token { isBusy = false } }
        do {
            let saved = try await editor.save(document, changes: edits)
            pendingDrafts.removeValue(forKey: SourceIdentity(document))
            guard generation == token else { return }
            self.document = saved; drafts = Dictionary(uniqueKeysWithValues: saved.fields.map { ($0.id, $0.value) })
            message = "Saved to the provider's configuration file."
        } catch { if generation == token { errorMessage = (error as? CoincideError)?.message ?? "The provider configuration could not be saved safely." } }
    }
    func discard() {
        guard !isBusy, let document else { return }
        pendingDrafts.removeValue(forKey: SourceIdentity(document))
        drafts = Dictionary(uniqueKeysWithValues: document.fields.map { ($0.id, $0.value) })
        errorMessage = nil; message = nil
    }
    private func retainDraft() {
        guard let document else { return }
        let identity = SourceIdentity(document)
        if hasChanges { pendingDrafts[identity] = .init(document: document, values: drafts) }
        else { pendingDrafts.removeValue(forKey: identity) }
    }
}
