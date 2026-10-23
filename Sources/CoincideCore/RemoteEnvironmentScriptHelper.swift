import Darwin
import Foundation

/// The preinstalled environment executable also hosts the existing managed
/// script protocol. No companion executable is resolved from the remote PATH.
public enum RemoteEnvironmentScriptHelper {
    public static func factory(executableURL: URL?, environment: [String: String]? = nil) throws -> WorkspaceEngine.ProjectScriptFactory {
        guard let executableURL, executableURL.isFileURL,
              executableURL.host == nil || executableURL.host == "" || executableURL.host == "localhost",
              executableURL.query == nil, executableURL.fragment == nil else {
            throw ProjectScriptExecutionError(.helperUnavailable)
        }
        let executable = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        var node = stat()
        guard lstat(executable.path, &node) == 0, node.st_mode & S_IFMT == S_IFREG,
              access(executable.path, X_OK) == 0 else {
            throw ProjectScriptExecutionError(.helperUnavailable)
        }
        // Capture once at host launch. The managed session validates both the
        // executable and this environment again before preparing any command.
        let captured = try NativeProjectScriptExecutionSession.sanitizedEnvironment(environment ?? ProcessChannel.environment())
        return { plan in
            try NativeProjectScriptExecutionSession(plan: plan, helperURL: executable, environment: captured)
        }
    }
}
