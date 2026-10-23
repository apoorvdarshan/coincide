import Foundation

/// T3's `projectScriptRuntimeEnv` for every drawer terminal: the project root,
/// plus the linked worktree path when the conversation runs in another checkout.
public enum TerminalRuntimeEnvironment {
    public static let projectRootKey = "T3CODE_PROJECT_ROOT"
    public static let worktreePathKey = "T3CODE_WORKTREE_PATH"
    public static let keys: Set<String> = [projectRootKey, worktreePathKey]

    /// Returns no variables for paths that are not absolute local paths.
    public static func variables(projectRoot: String, workspacePath: String) -> [String: String] {
        guard isLocalPath(projectRoot), isLocalPath(workspacePath) else { return [:] }
        let root = URL(fileURLWithPath: projectRoot).standardizedFileURL
        let workspace = URL(fileURLWithPath: workspacePath).standardizedFileURL
        var environment = [projectRootKey: root.path]
        if root.resolvingSymlinksInPath().path != workspace.resolvingSymlinksInPath().path {
            environment[worktreePathKey] = workspace.path
        }
        return environment
    }

    private static func isLocalPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0") && path.utf8.count <= 16_384
    }
}
