import Foundation

public enum ThreadProjectScriptRunPhase: String, Codable, Sendable {
    case waitingForCheckout, discovering, awaitingApproval, starting, running, succeeded, failed, interrupted, stopping, cancelled, skipped
}
public enum ProjectScriptStopAction: String, Codable, Sendable { case cancel, skip, retry }
public struct ThreadProjectScriptRun: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var plan: ProjectScriptExecutionPlan?
    public var phase: ThreadProjectScriptRunPhase
    public var commandExit: ProjectScriptCommandExit?
    public var error: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var pendingAction: ProjectScriptStopAction?
    public var previousPlans: [ProjectScriptExecutionPlan]
    public init(id: UUID = UUID(), now: Date = Date()) {
        self.id = id; phase = .waitingForCheckout; createdAt = now; updatedAt = now; previousPlans = []
    }
    public var providerReleased: Bool {
        phase == .skipped || phase == .succeeded || (phase == .stopping && pendingAction == .cancel && commandExit == .exited(0)) ||
        ([.running, .failed].contains(phase) && startedAt != nil && plan?.script.runsAsynchronously == true)
    }
    public var canApprove: Bool { phase == .awaitingApproval && plan != nil }
    public var canRetry: Bool { [.failed, .interrupted, .cancelled].contains(phase) }
    public var canSkip: Bool { ![.succeeded, .skipped, .stopping].contains(phase) }
    public static let discoveryError = "The project setup configuration could not be read. Review t3.json or continue without setup."
    public static let executionError = "The approved setup script could not be started or completed. Review its output before trying again."
    public static let interruptedError = "The app closed during project setup. Review the script before running it again; it may already have made changes."
    public static let settleDiscoveryError = "The settle script configuration could not be read. Review t3.json or resume without running it."
    public static let settleExecutionError = "The approved settle script could not be started or completed. Review its output before trying again."
    public static let settleInterruptedError = "The app closed during the settle script. Review it before running again; it may already have made changes."
    public static func discoveryError(for role: ProjectScriptRole) -> String { role == .setup ? discoveryError : settleDiscoveryError }
    public static func executionError(for role: ProjectScriptRole) -> String { role == .setup ? executionError : settleExecutionError }
    public static func interruptedError(for role: ProjectScriptRole) -> String { role == .setup ? interruptedError : settleInterruptedError }
    public func validate(workspacePath: String, role: ProjectScriptRole = .setup) throws {
        let dates = [createdAt, updatedAt] + [startedAt, endedAt].compactMap { $0 }
        guard dates.allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              (phase == .stopping) == (pendingAction != nil),
              error == nil || [Self.discoveryError, Self.executionError, Self.interruptedError, Self.settleDiscoveryError, Self.settleExecutionError, Self.settleInterruptedError].contains(error!),
              ![.awaitingApproval, .starting, .running, .succeeded].contains(phase) || plan != nil,
              phase != .running || startedAt != nil,
              phase != .succeeded || (commandExit == .exited(0) && startedAt != nil),
              phase != .waitingForCheckout || (plan == nil && startedAt == nil),
              Set(previousPlans.map(\.id) + [id]).count == previousPlans.count + 1 else {
            throw CoincideError("This conversation has inconsistent project setup state.")
        }
        if let plan { try plan.validate(); guard plan.id == id, plan.workspacePath == workspacePath,
            role == .setup ? plan.script.runOnWorktreeCreate : plan.script.runOnSettle else { throw CoincideError("The project script plan belongs to another workspace or role.") } }
        for previous in previousPlans { try previous.validate() }
        if let commandExit {
            switch commandExit {
            case .exited(let code): guard (0...255).contains(code) else { throw CoincideError("The project setup exit status is invalid.") }
            case .signaled(let code): guard (1...127).contains(code) else { throw CoincideError("The project setup exit status is invalid.") }
            }
            guard startedAt != nil else { throw CoincideError("An unstarted setup script cannot have an exit status.") }
        }
    }
}

public struct ProjectScriptPlanningContext: Sendable {
    public let id: UUID
    public let projectRoot: URL
    public let workspacePath: URL
    public let role: ProjectScriptRole
    public init(id: UUID, projectRoot: URL, workspacePath: URL, role: ProjectScriptRole = .setup) { self.id = id; self.projectRoot = projectRoot; self.workspacePath = workspacePath; self.role = role }
}
public enum ProjectScriptSetupPlanner {
    public static func plan(_ context: ProjectScriptPlanningContext) async throws -> ProjectScriptExecutionPlan? {
        if context.role == .settle,
           context.projectRoot.standardizedFileURL.resolvingSymlinksInPath().path == context.workspacePath.standardizedFileURL.resolvingSymlinksInPath().path { return nil }
        let files = WorkspaceFileService(root: context.workspacePath)
        do {
            let document = try await ProjectConfigurationService.load(using: files)
            guard document.exists else { await files.close(); return nil }
            guard let configuration = document.configuration, let revision = document.revision else { throw CoincideError(ThreadProjectScriptRun.discoveryError) }
            guard let index = configuration.scripts.firstIndex(where: { context.role == .setup ? $0.runOnWorktreeCreate : $0.runOnSettle }) else { await files.close(); return nil }
            let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            guard shellPath.hasPrefix("/") else { throw ProjectScriptExecutionError(.invalidPlan) }
            let plan = try await ProjectScriptExecutionPlan.capture(scriptIndex: index, using: files, projectRoot: context.projectRoot,
                shell: URL(fileURLWithPath: shellPath), id: context.id)
            guard plan.configurationRevision == ProjectScriptExecutionRevision(revision), plan.scriptIndex == index,
                  plan.script == configuration.scripts[index], context.role == .setup ? plan.script.runOnWorktreeCreate : plan.script.runOnSettle else { throw ProjectScriptExecutionError(.configurationChanged) }
            if context.role == .settle, plan.projectRootIdentity == plan.workspaceIdentity { await files.close(); return nil }
            await files.close(); try Task.checkCancellation(); return plan
        } catch { await files.close(); try Task.checkCancellation(); throw error }
    }
}

public struct ProjectScriptOutputSnapshot: Sendable, Equatable {
    public let runID: UUID
    public let sequence: UInt64
    public let text: String
    public let truncated: Bool
    public let isClosed: Bool
    public init(runID: UUID, sequence: UInt64, text: String, truncated: Bool, isClosed: Bool) {
        self.runID = runID; self.sequence = sequence; self.text = text; self.truncated = truncated; self.isClosed = isClosed
    }
}
