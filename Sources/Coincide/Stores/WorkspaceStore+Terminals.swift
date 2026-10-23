import AppKit
import CoincideCore
import CoincideTerminal
import Foundation

/// Terminal integration kept outside the WorkspaceStore hub: conversation lookup,
/// checkout gates, T3CODE_* variables, links, running indicators and idle closure.
extension WorkspaceStore {
    func configureTerminalIntegration(_ terminals: TerminalWorkspaceStore) {
        terminals.integration = TerminalIntegration(
            thread: { [weak self] in self?.thread($0) },
            canOpen: { [weak self] in self?.canOpenTerminal(for: $0) ?? false },
            environment: { [weak self] in self?.terminalEnvironment(for: $0) ?? [:] },
            openFile: { [weak self] path, line, column, thread in
                self?.openTerminalFile(path, line: line, column: column, thread: thread)
            },
            openURL: { NSWorkspace.shared.open($0) },
            report: { [weak self] in self?.errorMessage = $0 })
    }

    /// T3CODE_PROJECT_ROOT, plus T3CODE_WORKTREE_PATH for a linked checkout.
    func terminalEnvironment(for thread: CodingThread) -> [String: String] {
        guard let project = snapshot.projects.first(where: { $0.id == thread.projectID }) else { return [:] }
        return TerminalRuntimeEnvironment.variables(projectRoot: project.path, workspacePath: thread.workspacePath)
    }

    /// Terminal processes running for a conversation across every window.
    func runningTerminalCount(threadID: UUID) -> Int {
        liveTerminalStores.reduce(0) { $0 + $1.runningCount(threadID: threadID) }
    }

    /// Selects the conversation and opens its terminal drawer in windows that own its terminals.
    func showTerminals(threadID: UUID) {
        guard let target = thread(threadID) else { return }
        selectedProjectID = target.projectID; showArchived = target.isArchived; selectedThreadID = threadID
        for terminals in liveTerminalStores where terminals.sessions[threadID] != nil {
            terminals.setVisible(true, threadID: threadID)
        }
    }

    /// Optionally closes verified idle shells after settling, retaining output.
    /// Manual terminals keep their normal lifetime unless this setting is enabled.
    @discardableResult func closeIdleTerminals(for settled: CodingThread) async -> Int {
        guard UserDefaults.standard.bool(forKey: TerminalAppearance.closeIdleOnSettleKey),
              let generation = settled.settlement?.id else { return 0 }
        var closed = 0
        for terminals in liveTerminalStores {
            guard !Task.isCancelled, let current = thread(settled.id), current.projectID == settled.projectID,
                  current.createdAt == settled.createdAt, current.settlement?.id == generation,
                  current.settlement?.phase == .settled,
                  current.workspacePath.utf8.elementsEqual(settled.workspacePath.utf8),
                  current.workspacePreparation?.id == settled.workspacePreparation?.id else { break }
            closed += await terminals.closeIdle(threadID: settled.id)
        }
        return closed
    }

    /// Files inside the conversation's checkout open in the Files inspector at the
    /// line; other existing files and folders are revealed in Finder. Nothing is executed.
    func openTerminalFile(_ path: String, line: Int?, column: Int?, thread: CodingThread) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return String(localized: "“\(url.lastPathComponent)” was not found.")
        }
        let root = URL(fileURLWithPath: thread.workspacePath).standardizedFileURL.resolvingSymlinksInPath()
        let resolved = url.resolvingSymlinksInPath()
        if !isDirectory.boolValue, resolved.path.hasPrefix(root.path + "/"), canAccessWorkspaceFiles(thread.workspacePath) {
            openFile(resolved, line: line, workspacePath: thread.workspacePath)
            return nil
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return nil
    }
}
