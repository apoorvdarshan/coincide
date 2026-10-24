import CoincideCore
import Foundation
import Observation

@MainActor @Observable
final class ProviderIntegrationsStore {
    struct Scope: Equatable, Sendable {
        var workspacePath: String?
        var codexHome: String?
        var claudeHome: String?
    }
    let libraryRoot: URL
    private(set) var scope: Scope?
    private(set) var items: [ProviderIntegrationItem] = []
    private(set) var issues: [ProviderIntegrationIssue] = []
    private(set) var checkedAt: Date?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private var generation = UUID()

    init(libraryRoot: URL) { self.libraryRoot = libraryRoot }

    func refresh(scope: Scope) async {
        let generation = UUID(); self.generation = generation
        if self.scope != scope { items = []; issues = []; checkedAt = nil }
        self.scope = scope; isLoading = true; errorMessage = nil
        let root = libraryRoot
        defer { if self.generation == generation { isLoading = false } }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try ProviderIntegrationCatalog.scan(workspacePath: scope.workspacePath,
                    codexHome: scope.codexHome, claudeHome: scope.claudeHome, libraryRoot: root)
            }.value
            guard self.generation == generation else { return }
            items = result.items; issues = result.issues; checkedAt = result.checkedAt
        } catch {
            guard self.generation == generation else { return }
            errorMessage = "Integrations could not be read. Check the source folders and refresh."
        }
    }

    @discardableResult
    func importItems(_ ids: [String]) async throws -> Int {
        guard !isSaving, !isLoading, let scope else { throw CoincideError("Wait for integrations to finish loading.") }
        let selected = ids.compactMap { id in items.first { $0.id == id && !$0.imported && $0.available } }
        guard selected.count == Set(ids).count else { throw CoincideError("The integration selection changed. Refresh and select it again.") }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        let root = libraryRoot
        do {
            let count = try await Task.detached(priority: .userInitiated) {
                var count = 0
                for item in selected {
                    try Task.checkCancellation()
                    _ = try ProviderIntegrationCatalog.importItem(item, libraryRoot: root)
                    count += 1
                }
                return count
            }.value
            await refresh(scope: self.scope ?? scope)
            return count
        } catch {
            await refresh(scope: self.scope ?? scope)
            errorMessage = ((error as? CoincideError)?.message ?? "Some items could not be imported.") + " Completed imports are retained; review the list before retrying."
            throw CoincideError(errorMessage!)
        }
    }

    func removeImport(_ id: String) async throws {
        guard !isSaving, let scope, items.contains(where: { $0.id == id && $0.imported }) else {
            throw CoincideError("This library item is no longer available.")
        }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        let root = libraryRoot
        do {
            try await Task.detached { try ProviderIntegrationCatalog.removeImport(id: id, libraryRoot: root) }.value
            await refresh(scope: self.scope ?? scope)
        } catch {
            errorMessage = "The library item could not be removed. Its original CLI configuration is unchanged."
            throw CoincideError(errorMessage!)
        }
    }

    func invocation(for item: ProviderIntegrationItem) async throws -> String {
        guard let current = items.first(where: { $0.id == item.id }), current == item, item.available,
              item.kind == .skills || item.kind == .commands else { throw CoincideError("Refresh this skill or command before using it.") }
        let root = libraryRoot
        return try await Task.detached { try ProviderIntegrationCatalog.invocationText(for: item, libraryRoot: root) }.value
    }
}
