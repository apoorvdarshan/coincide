import Darwin
import Foundation

public struct ProjectScriptExecutionNode: Codable, Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64
    public init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
    init(_ value: stat) { self.init(device: UInt64(truncatingIfNeeded: value.st_dev), inode: value.st_ino) }
}

/// Complete configuration identity, including the resolved in-workspace target of an internal link.
public struct ProjectScriptExecutionRevision: Codable, Sendable, Equatable {
    public let root: ProjectScriptExecutionNode
    public let file: ProjectScriptExecutionNode
    public let relativePath: String
    public let digest: Data
    init(_ value: WorkspaceFileRevision) {
        root = .init(device: value.rootDevice, inode: value.rootInode)
        file = .init(device: value.device, inode: value.inode)
        relativePath = value.path; digest = value.digest
    }
}

/// Immutable local launch data. Capturing or decoding a plan never executes repository commands.
/// Inherited environment values are deliberately absent from the persistable plan.
public struct ProjectScriptExecutionPlan: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let scriptIndex: Int
    public let script: ProjectScript
    public let projectRoot: String
    public let workspacePath: String
    public let shellPath: String
    public let projectRootIdentity: ProjectScriptExecutionNode
    public let workspaceIdentity: ProjectScriptExecutionNode
    public let shellIdentity: ProjectScriptExecutionNode
    public let configurationRevision: ProjectScriptExecutionRevision

    public static func capture(scriptIndex: Int, using files: WorkspaceFileService, projectRoot: URL,
                               shell: URL, id: UUID = UUID()) async throws -> Self {
        let document = try await ProjectConfigurationService.load(using: files)
        guard let configuration = document.configuration, let revision = document.revision,
              configuration.scripts.indices.contains(scriptIndex) else { throw ProjectScriptExecutionError(.invalidPlan) }
        let script = configuration.scripts[scriptIndex]
        _ = try ProjectScriptInvocation(script: script, projectRoot: projectRoot, worktreePath: files.root)
        guard shell.isFileURL, shell.host == nil || shell.host == "" || shell.host == "localhost",
              shell.query == nil, shell.fragment == nil else { throw ProjectScriptExecutionError(.invalidPlan) }
        let rootPath = projectRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let shellPath = shell.standardizedFileURL.resolvingSymlinksInPath().path
        let value = try await Task.detached {
            try Task.checkCancellation()
            let root = try WorkspaceFileRoot(root: URL(fileURLWithPath: rootPath))
            defer { root.close() }
            var executable = stat()
            guard lstat(shellPath, &executable) == 0, executable.st_mode & S_IFMT == S_IFREG,
                  access(shellPath, X_OK) == 0 else { throw ProjectScriptExecutionError(.invalidPlan) }
            let plan = Self(id: id, scriptIndex: scriptIndex, script: script, projectRoot: root.path,
                workspacePath: files.root.path, shellPath: shellPath,
                projectRootIdentity: .init(device: root.device, inode: root.inode),
                workspaceIdentity: .init(device: revision.rootDevice, inode: revision.rootInode),
                shellIdentity: .init(executable), configurationRevision: .init(revision))
            try plan.validate(); return plan
        }.value
        try Task.checkCancellation()
        _ = try await files.metadata()
        return value
    }

    public func validate() throws {
        try script.validate()
        guard (0..<50).contains(scriptIndex), Self.path(projectRoot), Self.path(workspacePath), Self.path(shellPath),
              projectRootIdentity.inode != 0, workspaceIdentity.inode != 0, shellIdentity.inode != 0,
              configurationRevision.root == workspaceIdentity, configurationRevision.file.inode != 0,
              configurationRevision.digest.count == 32,
              !configurationRevision.relativePath.hasPrefix("/"), !configurationRevision.relativePath.contains("\0"),
              !configurationRevision.relativePath.isEmpty,
              configurationRevision.relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              configurationRevision.relativePath.utf16.count <= 4_096 else { throw ProjectScriptExecutionError(.invalidPlan) }
    }
    static func path(_ value: String) -> Bool {
        value.hasPrefix("/") && value != "/" && !value.contains("\0") && value.utf16.count <= 4_096 &&
        value.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); scriptIndex = try c.decode(Int.self, forKey: .scriptIndex)
        script = try c.decode(ProjectScript.self, forKey: .script)
        projectRoot = try c.decode(String.self, forKey: .projectRoot); workspacePath = try c.decode(String.self, forKey: .workspacePath)
        shellPath = try c.decode(String.self, forKey: .shellPath)
        projectRootIdentity = try c.decode(ProjectScriptExecutionNode.self, forKey: .projectRootIdentity)
        workspaceIdentity = try c.decode(ProjectScriptExecutionNode.self, forKey: .workspaceIdentity)
        shellIdentity = try c.decode(ProjectScriptExecutionNode.self, forKey: .shellIdentity)
        configurationRevision = try c.decode(ProjectScriptExecutionRevision.self, forKey: .configurationRevision)
        try validate()
    }
    private init(id: UUID, scriptIndex: Int, script: ProjectScript, projectRoot: String, workspacePath: String,
                 shellPath: String, projectRootIdentity: ProjectScriptExecutionNode, workspaceIdentity: ProjectScriptExecutionNode,
                 shellIdentity: ProjectScriptExecutionNode, configurationRevision: ProjectScriptExecutionRevision) {
        self.id = id; self.scriptIndex = scriptIndex; self.script = script; self.projectRoot = projectRoot
        self.workspacePath = workspacePath; self.shellPath = shellPath; self.projectRootIdentity = projectRootIdentity
        self.workspaceIdentity = workspaceIdentity; self.shellIdentity = shellIdentity; self.configurationRevision = configurationRevision
    }
    private enum CodingKeys: String, CodingKey {
        case id, scriptIndex, script, projectRoot, workspacePath, shellPath, projectRootIdentity, workspaceIdentity, shellIdentity, configurationRevision
    }
}

public enum ProjectScriptCommandExit: Codable, Sendable, Equatable {
    case exited(Int32), signaled(Int32)
}
public struct ProjectScriptOutputChunk: Sendable, Equatable {
    public let sequence: UInt64
    public let data: Data
}
public struct ProjectScriptExecutionError: Error, LocalizedError, Sendable, Equatable {
    public enum Failure: String, Sendable { case invalidPlan, configurationChanged, helperUnavailable, launchFailed, protocolViolation, closed, alreadyStarted, outputAlreadyConsumed, inputBusy }
    public let failure: Failure
    public init(_ failure: Failure) { self.failure = failure }
    public var errorDescription: String? {
        switch failure {
        case .invalidPlan: "Choose an existing local script, workspace and executable shell."
        case .configurationChanged: "The script configuration or workspace changed. Review it again before running."
        case .helperUnavailable: "The managed script helper is unavailable."
        case .launchFailed: "The managed script could not be started."
        case .protocolViolation: "The managed script helper returned an invalid response."
        case .closed: "This managed script session is closed."
        case .alreadyStarted: "This managed script has already been started."
        case .outputAlreadyConsumed: "This managed script already has an output consumer."
        case .inputBusy: "The managed script input queue is full. Wait before sending more input."
        }
    }
}

public protocol ProjectScriptExecutionSession: AnyObject, Sendable {
    func prepare() async throws
    func start() throws
    func waitUntilStarted() async throws
    func waitForCommandExit() async throws -> ProjectScriptCommandExit
    func consumeOutput(_ receive: @escaping @Sendable (ProjectScriptOutputChunk) async -> Void) async throws
    func sendInput(_ data: Data) async throws
    func resize(columns: Int, rows: Int) async throws
    func close() async
}
