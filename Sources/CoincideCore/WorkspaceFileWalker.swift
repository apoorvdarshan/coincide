import Foundation

/// Shared, fresh, bounded candidates for native path and content searches. Explicit directory
/// browsing remains separate: it includes ignored children and labels them using Git's index.
enum WorkspaceFileWalker {
    static func entries(root: WorkspaceFileRoot, git: WorkspaceFileGit, deadline: ContinuousClock.Instant,
                        maximumEntries: Int = 25_000) async throws -> WorkspaceEntryPage {
        var pending = [""], visited = 0, truncated = false, entries: [WorkspaceEntry] = []
        while let directory = pending.popLast() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline, visited < maximumEntries else { truncated = true; break }
            let page: WorkspaceEntryPage
            do { page = try root.list(directory, deadline: deadline, limit: maximumEntries - visited) }
            catch let error as WorkspaceFileError where error.failure == .permissionDenied || error.failure == .missing {
                truncated = true; continue
            }
            let ignored: Set<String>
            do { ignored = try await git.ignored(page.entries.map(\.path), root: root, includeTracked: true, deadline: deadline) }
            catch let error as WorkspaceFileError where error.failure == .timedOut { truncated = true; break }
            truncated = truncated || page.truncated
            var directories: [String] = []
            for entry in page.entries {
                try Task.checkCancellation(); visited += 1
                if visited > maximumEntries || ContinuousClock.now >= deadline { truncated = true; break }
                if ignored.contains(entry.path) { continue }
                entries.append(entry)
                if entry.kind == .directory { directories.append(entry.path) }
            }
            pending.append(contentsOf: directories.reversed())
        }
        try root.validate()
        return .init(entries: entries.sorted { $0.path < $1.path }, truncated: truncated)
    }
}
