import AppKit
import CoincideKit

/// T3 Code's project scripts: commands a project runs often, such as its dev server or tests, run in a terminal of the
/// thread (its worktree or the project folder). The one run last is the toolbar's one-click script, and scripts
/// marked for it run on their own in a worktree made for a new thread.
@MainActor
final class ProjectScripts {
    static let shared = ProjectScripts()
    /// Posted when a project's scripts or its last-run script change. `object` is the project id.
    static let didChangeNotification = Notification.Name("coincide.projectScriptsChanged")

    /// Shows the terminal of a thread a script just started in, when that thread is on screen.
    var onShowTerminal: ((UUID) -> Void)?

    private let store = AppStore.shared

    func start() {
        WorktreeService.shared.onWorktreeCreated = { [weak self] threadID, _ in self?.runSetupScripts(threadID: threadID) }
    }

    func project(ofThread threadID: UUID?) -> Project? {
        threadID.flatMap { store.summary($0) }.flatMap { store.project($0.projectID) }
    }

    /// The script one click runs: the one run last in the project, else its first.
    func primaryScript(in project: Project) -> ProjectScript? {
        let last = UIState.shared.values.lastScripts[project.id.uuidString]
        return project.scripts.first { $0.id.uuidString == last } ?? project.scripts.first
    }

    func run(_ script: ProjectScript, threadID: UUID) {
        guard let thread = store.summary(threadID), let project = store.project(thread.projectID) else { return }
        UIState.shared.update { $0.lastScripts[project.id.uuidString] = script.id.uuidString }
        TerminalSessionManager.shared.terminals(for: threadID).run(
            script, environment: Self.environment(project: project, worktree: thread.worktreePath))
        NotificationCenter.default.post(name: Self.didChangeNotification, object: project.id)
        onShowTerminal?(threadID)
    }

    /// Where the script runs, for commands such as copying `.env` from the main checkout into a worktree. T3 Code's
    /// names are set too, so scripts imported from `t3.json` work unchanged.
    static func environment(project: Project, worktree: String?) -> [String: String] {
        var environment = ["COINCIDE_PROJECT_ROOT": project.path, "T3CODE_PROJECT_ROOT": project.path]
        if let worktree {
            environment["COINCIDE_WORKTREE_PATH"] = worktree
            environment["T3CODE_WORKTREE_PATH"] = worktree
        }
        return environment
    }

    private func runSetupScripts(threadID: UUID) {
        guard let thread = store.summary(threadID), let project = store.project(thread.projectID) else { return }
        let setup = project.scripts.filter(\.runOnWorktreeCreate)
        guard !setup.isEmpty else { return }
        let terminals = TerminalSessionManager.shared.terminals(for: threadID)
        let environment = Self.environment(project: project, worktree: thread.worktreePath)
        for script in setup { terminals.run(script, environment: environment) }
        onShowTerminal?(threadID)
    }

    // MARK: Editing

    func save(_ script: ProjectScript, in projectID: UUID) {
        store.updateProject(projectID) { project in
            if let index = project.scripts.firstIndex(where: { $0.id == script.id }) {
                project.scripts[index] = script
            } else {
                project.scripts.append(script)
            }
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: projectID)
    }

    func delete(_ script: ProjectScript, from projectID: UUID) {
        store.updateProject(projectID) { $0.scripts.removeAll { $0.id == script.id } }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: projectID)
    }

    /// The project's `t3.json`, when it has one with scripts the project lacks.
    func importableT3Scripts(for project: Project) -> [ProjectScript] {
        guard let data = try? Data(contentsOf: project.url.appendingPathComponent("t3.json")) else { return [] }
        let names = Set(project.scripts.map(\.name))
        return ProjectScript.scripts(fromT3File: data).filter { !names.contains($0.name) }
    }

    func importT3Scripts(into project: Project) {
        for script in importableT3Scripts(for: project) { save(script, in: project.id) }
    }
}

extension ProjectScript.Icon {
    var symbolName: String {
        switch self {
        case .play: "play"
        case .test: "checkmark.seal"
        case .lint: "wand.and.stars"
        case .configure: "gearshape"
        case .build: "hammer"
        case .debug: "ladybug"
        }
    }

    var title: String {
        switch self {
        case .play: String(localized: "Run")
        case .test: String(localized: "Test")
        case .lint: String(localized: "Lint")
        case .configure: String(localized: "Configure")
        case .build: String(localized: "Build")
        case .debug: String(localized: "Debug")
        }
    }
}
