import Foundation

/// Constructed by the Engine for each call after resolving the session lease.
/// Neither this live authority nor a transport credential is journal data.
public struct AppMCPContext: Sendable {
    public let scope: MCPInvocationScope
    public let runID: UUID?
    public let configuration: ProviderConfiguration
    public init(scope: MCPInvocationScope, runID: UUID?, configuration: ProviderConfiguration) {
        self.scope = scope; self.runID = runID; self.configuration = configuration
    }
}

/// A transient read frame. Tool responses use explicit projections below;
/// encoding an entire workspace or provider configuration is never supported.
public struct AppMCPView: Sendable {
    public let snapshot: WorkspaceSnapshot
    public let sequence: Int64
    public init(snapshot: WorkspaceSnapshot, sequence: Int64) { self.snapshot = snapshot; self.sequence = sequence }
}

public typealias AppMCPToolDescriptor = MCPToolDefinition
public typealias AppMCPToolResult = MCPToolResult

public struct AppMCPModelSelection: Codable, Sendable, Equatable {
    public let instanceID: UUID?
    public let provider: ProviderKind?
    public let model: String?
    /// nil preserves inherited choices; an empty dictionary explicitly clears.
    public let options: [String: JSONValue]?
    public init(instanceID: UUID? = nil, provider: ProviderKind? = nil, model: String? = nil, options: [String: JSONValue]? = nil) {
        self.instanceID = instanceID; self.provider = provider; self.model = model; self.options = options
    }
}
public struct AppMCPThreadCreation: Sendable, Equatable {
    public let title: String?
    public let prompt: String?
    public let target: AppMCPModelSelection?
    public let permission: PermissionMode?
    public init(title: String? = nil, prompt: String? = nil, target: AppMCPModelSelection? = nil, permission: PermissionMode? = nil) {
        self.title = title; self.prompt = prompt; self.target = target; self.permission = permission
    }
}
public enum AppMCPWorkspaceStrategy: Sendable, Equatable {
    case root
    case worktree(baseRef: String, branch: String, startFromOrigin: Bool)
    case existingWorktree(path: String, branch: String?)
}
public struct AppMCPThreadLaunch: Sendable, Equatable {
    public let projectID: UUID
    public let creation: AppMCPThreadCreation
    public let workspace: AppMCPWorkspaceStrategy
    public init(projectID: UUID, creation: AppMCPThreadCreation, workspace: AppMCPWorkspaceStrategy = .root) {
        self.projectID = projectID; self.creation = creation; self.workspace = workspace
    }
}
public struct AppMCPProjectCreate: Sendable, Equatable {
    public let title: String
    public let workspaceRoot: String?
    public let createWorkspaceRootIfMissing: Bool
    public init(title: String, workspaceRoot: String? = nil, createWorkspaceRootIfMissing: Bool = false) {
        self.title = title; self.workspaceRoot = workspaceRoot; self.createWorkspaceRootIfMissing = createWorkspaceRootIfMissing
    }
}
public enum AppMCPSendMode: String, Sendable, Equatable { case auto, queue, steer, restart }
public enum AppMCPThreadOrganization: String, Sendable, Equatable { case pin, unpin, archive, unarchive, settle, unsettle }
public struct AppMCPDelegation: Codable, Sendable, Equatable {
    public let task: String
    public let title: String?
    public let target: AppMCPModelSelection?
    public let permission: PermissionMode?
    public let role: DelegatedTaskRole
    public let isolation: DelegatedTaskIsolation
    public let mode: DelegatedTaskMode
    public let timeoutMilliseconds: Int
    public let clientRequestID: String?
    public init(task: String, title: String? = nil, target: AppMCPModelSelection? = nil, permission: PermissionMode? = nil,
                role: DelegatedTaskRole = .general, isolation: DelegatedTaskIsolation = .shared,
                mode: DelegatedTaskMode = .async, timeoutMilliseconds: Int = TaskOrchestration.defaultWaitMilliseconds,
                clientRequestID: String? = nil) {
        self.task = task; self.title = title; self.target = target; self.permission = permission
        self.role = role; self.isolation = isolation; self.mode = mode
        self.timeoutMilliseconds = timeoutMilliseconds; self.clientRequestID = clientRequestID
    }
}

/// Domain actions contain no credentials, authorization headers or launch paths.
/// The Engine MUST revalidate the live caller and target under its command queue,
/// including after asynchronous preparation. A prior `read` is not authorization.
public enum AppMCPAction: Sendable, Equatable {
    case scheduledTask(ScheduledTaskMCPAction)
    case capabilities(search: String?)
    case wait(threadID: UUID, runID: UUID?, timeoutMilliseconds: Int)
    case createThreads([AppMCPThreadCreation], clientRequestID: String?)
    case launchThread(AppMCPThreadLaunch)
    case createProject(AppMCPProjectCreate)
    case updateProject(projectID: UUID, title: String)
    case deleteProject(projectID: UUID, force: Bool)
    case renameThread(threadID: UUID, title: String, clientRequestID: String?)
    case organizeThread(threadID: UUID, action: AppMCPThreadOrganization)
    case configureThread(threadID: UUID, selection: AppMCPModelSelection)
    case send(threadID: UUID, message: String, mode: AppMCPSendMode, clientRequestID: String?)
    case interrupt(threadID: UUID, runID: UUID?, reason: String?)
    case editQueued(threadID: UUID, queuedRunID: UUID, text: String)
    case cancelQueued(threadID: UUID, queuedRunID: UUID)
    case reorderQueued(threadID: UUID, queuedRunID: UUID, beforeRunID: UUID?)
    case promoteQueued(threadID: UUID, queuedRunID: UUID, targetRunID: UUID)
    case answerQuestion(threadID: UUID, requestID: JSONValue, answers: [String: String])
    case forkThread(threadID: UUID, runID: UUID, title: String?)
    case forkContext(threadID: UUID, sourcePoint: ContextTransferSourcePoint, title: String?)
    case mergeContext(sourceThreadID: UUID, targetThreadID: UUID, sourcePoint: ContextTransferSourcePoint)
    case delegateTask(AppMCPDelegation)
    case delegatedTaskStatus(taskID: UUID)
    case cancelDelegatedTask(taskID: UUID, reason: String?, clientRequestID: String?)
}

public struct AppMCPError: Error, Sendable, Equatable, LocalizedError {
    public enum Code: String, Sendable { case invalidRequest = "invalid_request", notFound = "not_found", capabilityDenied = "capability_denied", staleCaller = "parent_not_active", permissionDenied = "runtime_mode_escalation_denied", unsupported, unavailable = "orchestration_error", cancelled }
    public let code: Code
    public init(_ code: Code) { self.code = code }
    public var errorDescription: String? {
        switch code {
        case .invalidRequest: "The tool arguments are invalid."
        case .notFound: "The requested app record was not found."
        case .capabilityDenied: "This session cannot use this tool."
        case .staleCaller: "The calling provider no longer owns this app session."
        case .permissionDenied: "The target requires broader permissions than the calling provider."
        case .unsupported: "This operation is not supported by this app capability."
        case .unavailable: "The app operation could not be completed."
        case .cancelled: "The app operation was cancelled."
        }
    }
}

/// Pinned T3 app tools over the native Engine. Unsupported backends (
/// secret requests, browser/device automation, PR monitoring, upload,
/// and active worktree handoff) are not advertised as working tools.
public struct AppMCPTools: Sendable {
    public struct Client: Sendable {
        public let read: @Sendable (AppMCPContext) async throws -> AppMCPView
        public let perform: @Sendable (AppMCPAction, AppMCPContext) async throws -> JSONValue
        public let contextRead: (@Sendable (JSONValue, AppMCPContext) async throws -> JSONValue)?
        public init(read: @escaping @Sendable (AppMCPContext) async throws -> AppMCPView,
                    perform: @escaping @Sendable (AppMCPAction, AppMCPContext) async throws -> JSONValue,
                    contextRead: (@Sendable (JSONValue, AppMCPContext) async throws -> JSONValue)? = nil) {
            self.read = read; self.perform = perform; self.contextRead = contextRead
        }
    }
    private let client: Client
    private let allowedToolNames: Set<String>?
    public init(client: Client, allowedToolNames: Set<String>? = nil) { self.client = client; self.allowedToolNames = allowedToolNames }

    public static let unsupportedCapabilities = ["secret_requests", "preview", "device", "html_render", "pull_request_links_and_watch", "review_guides", "attachment_upload", "active_worktree_handoff", "environment_preferences", "queued_steering_input_text_revision", "managed_project_allocation", "missing_workspace_creation", "restart_delivery", "remote_worktree_fetch"]
    public var descriptors: [MCPToolDefinition] { Self.catalog.filter { allowedToolNames?.contains($0.name) ?? true } }

    public func call(name: String, arguments: JSONValue, context: AppMCPContext) async -> MCPToolResult {
        do {
            try Task.checkCancellation()
            guard let descriptor = descriptors.first(where: { $0.name == name }) else { throw AppMCPError(.unsupported) }
            guard context.scope.capabilities.contains(descriptor.capability) else { throw AppMCPError(.capabilityDenied) }
            guard descriptor.readOnly || context.runID != nil else { throw AppMCPError(.staleCaller) }
            guard context.configuration.workspacePath == context.scope.workspacePath,
                  context.configuration.provider == context.scope.provider else { throw AppMCPError(.staleCaller) }
            let input = try Input(arguments)
            // This frame is live-validated by the Engine. Execution still needs
            // its own atomic check: do not pass a plain WorkspaceCommand here.
            let view = try await client.read(context)
            try Task.checkCancellation()
            guard let caller = view.snapshot.threads.first(where: { $0.id == context.scope.threadID }),
                  caller.projectID == context.scope.projectID else { throw AppMCPError(.staleCaller) }
            let value: JSONValue
            switch name {
            case "t3_context_read":
                guard let contextRead = client.contextRead else { throw AppMCPError(.unsupported) }
                try input.only(["transferId", "itemId", "afterPosition", "textOffset", "limit", "maxBytesPerItem"])
                _ = try input.uuid("transferId", required: true)
                _ = try input.text("itemId", maximum: 4_096)
                _ = try input.integer("afterPosition", default: -1, range: 0...Int.max)
                _ = try input.integer("textOffset", default: 0, range: 0...Int.max)
                _ = try input.integer("limit", default: 20, range: 1...100)
                _ = try input.integer("maxBytesPerItem", default: 4_096, range: 1...65_536)
                value = try await contextRead(arguments, context)
            case "orchestrator_capabilities":
                try input.only(["search"])
                value = try await client.perform(.capabilities(search: input.text("search", maximum: 200)), context)
            case "t3_environment_read":
                try input.only([])
                value = .object(["label": .string("Coincide"), "platform": .string("macOS"),
                    "toolNames": .array(descriptors.map { .string($0.name) }),
                    "unsupportedCapabilities": .array(Self.unsupportedCapabilities.map(JSONValue.string))])
            case "t3_project_list":
                try input.only(["cursor", "limit"])
                let (start, count) = try input.page()
                let projects = view.snapshot.projects
                let end = min(projects.count, start + min(count, max(0, projects.count - start)))
                value = .object(["projects": .array(start < projects.count ? projects[start..<end].map(Self.project) : []), "nextCursor": end < projects.count ? .number(Double(end)) : .null])
            case "t3_project_read":
                try input.only(["projectId"])
                let id = try input.uuid("projectId", required: true)!
                guard let project = view.snapshot.projects.first(where: { $0.id == id }) else { throw AppMCPError(.notFound) }
                value = Self.project(project)
            case "t3_thread_list": value = try Self.threadList(input, view: view, caller: caller)
            case "t3_thread_read": value = try Self.threadRead(input, view: view)
            case "t3_thread_search": value = try Self.search(input, view: view, caller: caller)
            case "t3_thread_transfers":
                try input.only(["threadId", "cursor", "limit"])
                let target = try Self.thread(input, view: view, caller: caller)
                let (start, limit) = try input.page()
                let transfers = (view.snapshot.contextTransfers ?? []).filter { $0.sourceThreadID == target.id || $0.targetThreadID == target.id }
                var all: [(Date, String, JSONValue)] = transfers.map { transfer in (transfer.updatedAt, transfer.id.uuidString, .object([
                    "id": Self.id(transfer.id), "type": .string(transfer.review.kind.rawValue),
                    "sourceThreadId": Self.id(transfer.sourceThreadID), "targetThreadId": Self.id(transfer.targetThreadID),
                    "sourceRunId": Self.id(transfer.review.sourcePoint.runID), "status": .string(transfer.status.rawValue),
                    "strategy": .string(transfer.review.strategy.rawValue), "targetRunId": transfer.targetRunID.map(Self.id) ?? .null,
                    "deliveryStatus": transfer.delivery.map { .string($0.status.rawValue) } ?? .null,
                    "updatedAt": Self.date(transfer.updatedAt)])) }
                all += (view.snapshot.delegatedTaskTransfers ?? []).filter { $0.sourceThreadID == target.id || $0.targetThreadID == target.id }.map { transfer in
                    (transfer.createdAt, transfer.id.uuidString, .object(["id": Self.id(transfer.id),
                        "type": .string(transfer.kind == .subagentResult ? "subagent_result" : "subagent_spawn"),
                        "sourceThreadId": Self.id(transfer.sourceThreadID), "targetThreadId": Self.id(transfer.targetThreadID),
                        "sourceRunId": Self.id(transfer.sourceRunID), "targetRunId": Self.id(transfer.targetRunID),
                        "taskId": Self.id(transfer.taskID), "status": .string("consumed"), "createdBy": .string("system"),
                        "createdAt": Self.date(transfer.createdAt), "consumedAt": Self.date(transfer.consumedAt)]))
                }
                all.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
                let rows = Array(all.dropFirst(start).prefix(limit)).map(\.2)
                value = .object(["transfers": .array(rows), "totalCount": .number(Double(all.count)),
                    "nextCursor": start + rows.count < all.count ? .number(Double(start + rows.count)) : .null])
            case "t3_thread_configuration":
                try input.only(["threadId"])
                let thread = try Self.thread(input, view: view, caller: caller)
                value = try Self.configuration(thread)
            case "t3_queue_list", "t3_queue_read": value = try Self.queue(name, input: input, view: view, caller: caller)
            case "t3_pending_request_list", "t3_pending_request_read": value = try Self.questions(name, input: input, view: view, caller: caller)
            case "t3_worktree_status":
                try input.only([])
                guard let project = view.snapshot.projects.first(where: { $0.id == caller.projectID }) else { throw AppMCPError(.notFound) }
                value = .object(["threadId": Self.id(caller.id), "workspaceRoot": .string(project.path), "worktreePath": .string(caller.workspacePath),
                    "attached": .bool(caller.workspacePreparation?.isReady == true && caller.workspacePath != project.path),
                    "canHandoff": .bool(false), "handoffUnsupported": .bool(true)])
            default:
                let action = try Self.action(name, input: input, view: view, caller: caller)
                if Self.environmentWrite(action), context.configuration.permission != .fullAccess { throw AppMCPError(.capabilityDenied) }
                value = try await client.perform(action, context)
            }
            try Task.checkCancellation()
            try MCPProtocol.validateJSON(value)
            let data = try JSONEncoder().encode(value)
            guard let text = String(data: data, encoding: .utf8) else { throw AppMCPError(.unavailable) }
            let result = MCPToolResult(content: [text], structuredContent: value)
            // Text + structuredContent intentionally duplicate the semantic
            // result. Bound the actual transport envelope, not just one copy.
            guard (try JSONEncoder().encode(result.json)).count <= MCPProtocol.maximumBodyBytes - 256 else { throw AppMCPError(.unavailable) }
            return result
        } catch {
            let failure = error as? AppMCPError ?? AppMCPError(error is CancellationError ? .cancelled : .unavailable)
            let value: JSONValue = .object(["code": .string(failure.code.rawValue), "message": .string(failure.errorDescription ?? "The app operation could not be completed.")])
            return .init(content: [failure.errorDescription ?? "The app operation could not be completed."], structuredContent: value, isError: true)
        }
    }

    private static func action(_ name: String, input: Input, view: AppMCPView, caller: CodingThread) throws -> AppMCPAction {
        switch name {
        case "read_scheduled_task":
            try input.only(["scheduledTaskId", "revision", "offset", "maxBytes"])
            return try .scheduledTask(.read(id: input.uuid("scheduledTaskId", required: true)!, revision: input.uuid("revision", required: true)!,
                offset: input.integer("offset", default: 0, range: 0...524_288), maximumBytes: input.integer("maxBytes", default: 16_384, range: 4...65_536)))
        case "list_scheduled_tasks":
            try input.only(["projectId", "cursor", "limit"])
            return try .scheduledTask(.list(projectID: input.uuid("projectId"), cursor: input.integer("cursor", default: 0, range: 0...100), limit: input.integer("limit", default: 20, range: 1...20)))
        case "schedule_task", "update_scheduled_task":
            try input.only(["scheduledTaskId", "revision", "title", "prompt", "enabled", "schedule", "bindToCurrentThread", "commandId"])
            let updating = name == "update_scheduled_task"
            let schedule = try input.object["schedule"].map { try scheduledTaskSchedule($0) }
            let enabled = try input.object["enabled"] == nil ? nil : input.boolean("enabled", default: false)
            let bound = try input.object["bindToCurrentThread"] == nil ? nil : input.boolean("bindToCurrentThread", default: true)
            return try .scheduledTask(.save(id: input.uuid("scheduledTaskId", required: updating), revision: input.uuid("revision", required: updating),
                title: input.text("title", maximum: 1024, required: !updating), prompt: input.text("prompt", maximum: 120_000, required: !updating),
                enabled: enabled, schedule: schedule, bindToCurrentThread: bound, commandID: input.uuid("commandId", required: true)!))
        case "delete_scheduled_task":
            try input.only(["scheduledTaskId", "revision", "commandId"])
            return try .scheduledTask(.delete(id: input.uuid("scheduledTaskId", required: true)!, revision: input.uuid("revision", required: true)!, commandID: input.uuid("commandId", required: true)!))
        case "run_scheduled_task_now":
            try input.only(["taskId", "commandId"])
            return try .scheduledTask(.run(id: input.uuid("taskId", required: true)!, commandID: input.uuid("commandId", required: true)!))
        case "acknowledge_scheduled_task_run":
            try input.only(["runId", "commandId"])
            return try .scheduledTask(.acknowledge(id: input.uuid("runId", required: true)!, commandID: input.uuid("commandId", required: true)!))
        case "delegate_task":
            try input.only(["task", "title", "target", "role", "isolation", "mode", "timeoutMs", "clientRequestId", "runtimeMode", "interactionMode"])
            let task = try input.text("task", maximum: 120_000, required: true)!
            guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let role = DelegatedTaskRole(rawValue: try input.text("role", maximum: 32) ?? "general"),
                  let isolation = DelegatedTaskIsolation(rawValue: try input.text("isolation", maximum: 32) ?? "shared"),
                  let mode = DelegatedTaskMode(rawValue: try input.text("mode", maximum: 32) ?? "async") else { throw AppMCPError(.invalidRequest) }
            return try .delegateTask(.init(task: task, title: input.text("title", maximum: 512), target: selection(input.value["target"]),
                permission: permission(input), role: role, isolation: isolation, mode: mode,
                timeoutMilliseconds: input.integer("timeoutMs", default: TaskOrchestration.defaultWaitMilliseconds, range: 0...TaskOrchestration.maximumWaitMilliseconds),
                clientRequestID: input.text("clientRequestId", maximum: 256)))
        case "task_status":
            try input.only(["taskId"])
            return try .delegatedTaskStatus(taskID: input.uuid("taskId", required: true)!)
        case "task_cancel":
            try input.only(["taskId", "reason", "clientRequestId"])
            return try .cancelDelegatedTask(taskID: input.uuid("taskId", required: true)!, reason: input.text("reason", maximum: 2_000),
                clientRequestID: input.text("clientRequestId", maximum: 256))
        case "t3_thread_wait":
            try input.only(["threadId", "runId", "timeoutMs"])
            return try .wait(threadID: input.uuid("threadId", required: true)!, runID: input.uuid("runId"), timeoutMilliseconds: input.integer("timeoutMs", default: 600_000, range: 0...600_000))
        case "create_threads":
            try input.only(["threads", "clientRequestId"])
            guard let rows = input.value["threads"].array, (1...20).contains(rows.count) else { throw AppMCPError(.invalidRequest) }
            let requests = try rows.map { try creation(Input($0)) }
            return .createThreads(requests, clientRequestID: try input.text("clientRequestId", maximum: 256))
        case "t3_thread_launch":
            try input.only(["projectId", "title", "modelSelection", "runtimeMode", "interactionMode", "workspaceStrategy", "message"])
            let request = try AppMCPThreadCreation(title: input.text("title", maximum: 512, required: true), prompt: input.text("message", maximum: 120_000),
                target: selection(input.value["modelSelection"]), permission: permission(input))
            let project = try input.uuid("projectId") ?? caller.projectID
            guard view.snapshot.projects.contains(where: { $0.id == project }) else { throw AppMCPError(.notFound) }
            return .launchThread(.init(projectID: project, creation: request, workspace: try workspace(input.value["workspaceStrategy"])))
        case "t3_project_create":
            try input.only(["title", "workspaceRoot", "createWorkspaceRootIfMissing"])
            return .createProject(try .init(title: input.text("title", maximum: 512, required: true)!, workspaceRoot: input.absolutePath("workspaceRoot"),
                createWorkspaceRootIfMissing: input.boolean("createWorkspaceRootIfMissing", default: false)))
        case "t3_project_update":
            try input.only(["projectId", "title"])
            return try .updateProject(projectID: input.uuid("projectId", required: true)!, title: input.text("title", maximum: 512, required: true)!)
        case "t3_project_delete":
            try input.only(["projectId", "force"])
            return try .deleteProject(projectID: input.uuid("projectId", required: true)!, force: input.boolean("force", default: false))
        case "t3_thread_update":
            try input.only(["threadId", "action", "title", "clientRequestId"])
            guard try input.text("action", maximum: 32, required: true) == "rename" else { throw AppMCPError(.unsupported) }
            return try .renameThread(threadID: thread(input, view: view, caller: caller).id, title: input.text("title", maximum: 512, required: true)!,
                clientRequestID: input.text("clientRequestId", maximum: 256))
        case "t3_thread_organize":
            try input.only(["threadId", "action"])
            guard let action = AppMCPThreadOrganization(rawValue: try input.text("action", maximum: 32, required: true)!) else { throw AppMCPError(.unsupported) }
            return .organizeThread(threadID: try thread(input, view: view, caller: caller).id, action: action)
        case "t3_thread_configure":
            try input.only(["threadId", "modelSelection"])
            guard let selection = try selection(input.value["modelSelection"]), selection.model != nil else { throw AppMCPError(.invalidRequest) }
            return .configureThread(threadID: try thread(input, view: view, caller: caller).id, selection: selection)
        case "t3_thread_send":
            try input.only(["threadId", "message", "mode", "clientRequestId"])
            guard let mode = AppMCPSendMode(rawValue: try input.text("mode", maximum: 32) ?? "auto") else { throw AppMCPError(.invalidRequest) }
            return try .send(threadID: input.uuid("threadId", required: true)!, message: input.text("message", maximum: 120_000, required: true)!,
                mode: mode, clientRequestID: input.text("clientRequestId", maximum: 256))
        case "t3_thread_interrupt":
            try input.only(["threadId", "runId", "reason"])
            return try .interrupt(threadID: input.uuid("threadId", required: true)!, runID: input.uuid("runId"), reason: input.text("reason", maximum: 2_000))
        case "t3_queue_edit", "t3_queue_cancel", "t3_queue_reorder", "t3_queue_promote_to_steer":
            try input.only(["threadId", "queuedRunId"] + (name == "t3_queue_edit" ? ["text"] : name == "t3_queue_reorder" ? ["beforeRunId"] : name == "t3_queue_promote_to_steer" ? ["targetRunId"] : []))
            let threadID = try thread(input, view: view, caller: caller).id, queuedID = try input.uuid("queuedRunId", required: true)!
            switch name {
            case "t3_queue_edit": return .editQueued(threadID: threadID, queuedRunID: queuedID, text: try input.text("text", maximum: 100_000, required: true, empty: true)!)
            case "t3_queue_cancel": return .cancelQueued(threadID: threadID, queuedRunID: queuedID)
            case "t3_queue_reorder":
                guard input.object.keys.contains("beforeRunId") else { throw AppMCPError(.invalidRequest) }
                return .reorderQueued(threadID: threadID, queuedRunID: queuedID, beforeRunID: try input.uuid("beforeRunId"))
            default: return .promoteQueued(threadID: threadID, queuedRunID: queuedID, targetRunID: try input.uuid("targetRunId", required: true)!)
            }
        case "t3_pending_request_respond":
            try input.only(["threadId", "requestId", "answers"])
            let target = try thread(input, view: view, caller: caller), requestID = try input.requestID()
            guard target.runtimeRequests.contains(where: { $0.id == requestID && $0.request.isQuestion && !$0.responding }) else { throw AppMCPError(.notFound) }
            guard let values = input.value["answers"].object, !values.isEmpty, values.count <= 64 else { throw AppMCPError(.invalidRequest) }
            var answers: [String: String] = [:]
            for (questionID, value) in values {
                guard !questionID.isEmpty, questionID.utf16.count <= 256, let text = value.string, text.utf16.count <= 16_000 else { throw AppMCPError(.invalidRequest) }
                answers[questionID] = text
            }
            return .answerQuestion(threadID: target.id, requestID: requestID, answers: answers)
        case "t3_thread_fork":
            try input.only(["threadId", "sourcePoint", "title"])
            let target = try thread(input, view: view, caller: caller)
            return .forkContext(threadID: target.id, sourcePoint: try contextPoint(input.value["sourcePoint"], thread: target), title: try input.text("title", maximum: 512))
        case "t3_thread_merge_back":
            try input.only(["sourceThreadId", "targetThreadId", "sourcePoint"])
            let sourceID = try input.uuid("sourceThreadId") ?? caller.id
            guard let source = view.snapshot.threads.first(where: { $0.id == sourceID }), !source.isArchived else { throw AppMCPError(.notFound) }
            return .mergeContext(sourceThreadID: sourceID, targetThreadID: try input.uuid("targetThreadId", required: true)!,
                sourcePoint: try contextPoint(input.value["sourcePoint"], thread: source))
        default: throw AppMCPError(.unsupported)
        }
    }

    private static func contextPoint(_ value: JSONValue, thread: CodingThread) throws -> ContextTransferSourcePoint {
        let point = try Input(value)
        try point.only(["type", "runId", "checkpointId"])
        switch try point.text("type", maximum: 32, required: true) {
        case "latest_stable":
            guard point.value["runId"] == .null, point.value["checkpointId"] == .null else { throw AppMCPError(.invalidRequest) }
            return .latestStable
        case "run":
            guard point.value["checkpointId"] == .null else { throw AppMCPError(.invalidRequest) }
            return .run(try point.uuid("runId", required: true)!)
        case "checkpoint":
            guard point.value["runId"] == .null else { throw AppMCPError(.invalidRequest) }
            let id = try point.uuid("checkpointId", required: true)!
            guard let run = thread.runHistory?.first(where: { $0.removedByHistoryOperationID == nil && $0.checkpoints?.postRun?.id == id }),
                  let attempt = run.checkpoints?.postRun else { throw AppMCPError(.notFound) }
            return .checkpoint(runID: run.id, attemptID: id, digest: try ContextTransferProtocol.digest(attempt))
        default: throw AppMCPError(.unsupported)
        }
    }

    private static func creation(_ input: Input) throws -> AppMCPThreadCreation {
        try input.only(["prompt", "title", "target", "runtimeMode", "interactionMode"])
        return try .init(title: input.text("title", maximum: 512), prompt: input.text("prompt", maximum: 120_000),
            target: selection(input.value["target"]), permission: permission(input))
    }
    private static func selection(_ value: JSONValue) throws -> AppMCPModelSelection? {
        if value == .null { return nil }
        let input = try Input(value)
        try input.only(["instanceId", "providerInstanceId", "driverKind", "model", "options"])
        let first = try input.uuid("instanceId"), second = try input.uuid("providerInstanceId")
        guard first == nil || second == nil || first == second else { throw AppMCPError(.invalidRequest) }
        let provider: ProviderKind?
        if let raw = try input.text("driverKind", maximum: 64) {
            guard let parsed = ProviderKind(rawValue: raw) else { throw AppMCPError(.invalidRequest) }; provider = parsed
        } else { provider = nil }
        var options: [String: JSONValue]?
        if let raw = input.object["options"] {
            if let values = raw.object { options = values }
            else if let rows = raw.array, rows.count <= 64 {
                var values: [String: JSONValue] = [:]
                for row in rows {
                    let item = try Input(row); try item.only(["id", "value"])
                    let id = try item.text("id", maximum: 128, required: true)!
                    guard values[id] == nil, let value = item.object["value"] else { throw AppMCPError(.invalidRequest) }
                    values[id] = value
                }
                options = values
            } else { throw AppMCPError(.invalidRequest) }
            guard options!.count <= 64 else { throw AppMCPError(.invalidRequest) }
            for (optionID, value) in options! {
                guard !optionID.isEmpty, optionID.utf16.count <= 128 else { throw AppMCPError(.invalidRequest) }
                switch value {
                case .string(let text): guard text.utf16.count <= 4_096 else { throw AppMCPError(.invalidRequest) }
                case .bool: break
                case .number(let number): guard number.isFinite else { throw AppMCPError(.invalidRequest) }
                default: throw AppMCPError(.invalidRequest)
                }
            }
        }
        return .init(instanceID: first ?? second, provider: provider, model: try input.text("model", maximum: 512), options: options)
    }
    private static func permission(_ input: Input) throws -> PermissionMode? {
        if let interaction = try input.text("interactionMode", maximum: 32), !["inherit", "default"].contains(interaction) { throw AppMCPError(.unsupported) }
        switch try input.text("runtimeMode", maximum: 32) {
        case nil, "inherit": return nil
        case "approval-required": return .supervised
        case "auto-accept-edits": return .autoAcceptEdits
        case "full-access": return .fullAccess
        default: throw AppMCPError(.unsupported)
        }
    }
    private static func workspace(_ value: JSONValue) throws -> AppMCPWorkspaceStrategy {
        if value == .null { return .root }
        let input = try Input(value)
        switch try input.text("type", maximum: 32, required: true) {
        case "root": try input.only(["type"]); return .root
        case "worktree":
            try input.only(["type", "baseRef", "branch", "startFromOrigin"])
            return try .worktree(baseRef: input.text("baseRef", maximum: 1_024, required: true)!, branch: input.text("branch", maximum: 256, required: true)!, startFromOrigin: input.boolean("startFromOrigin", default: false))
        case "existing_worktree":
            try input.only(["type", "worktreePath", "branch"])
            return try .existingWorktree(path: input.absolutePath("worktreePath", required: true)!, branch: input.text("branch", maximum: 256))
        default: throw AppMCPError(.unsupported)
        }
    }

    private static func environmentWrite(_ action: AppMCPAction) -> Bool {
        switch action { case .createProject, .updateProject, .deleteProject: true; default: false }
    }
    private static func thread(_ input: Input, view: AppMCPView, caller: CodingThread) throws -> CodingThread {
        let id = try input.uuid("threadId") ?? caller.id
        guard let thread = view.snapshot.threads.first(where: { $0.id == id }) else { throw AppMCPError(.notFound) }; return thread
    }
    private static func threadList(_ input: Input, view: AppMCPView, caller: CodingThread) throws -> JSONValue {
        try input.only(["projectId", "statuses", "titleContains", "settled", "cursor", "limit"])
        let projectID = try input.uuid("projectId") ?? caller.projectID
        var threads = view.snapshot.threads.filter { $0.projectID == projectID && !$0.isArchived }
        if let query = try input.text("titleContains", maximum: 256) { threads = threads.filter { $0.title.localizedCaseInsensitiveContains(query) } }
        if input.object["settled"] != nil { let settled = try input.boolean("settled", default: false); threads = threads.filter { $0.isSettled == settled } }
        if let raw = input.object["statuses"] {
            guard let values = raw.array, values.count <= 10, values.allSatisfy({ $0.string != nil }) else { throw AppMCPError(.invalidRequest) }
            let states = Set(values.compactMap(\.string))
            guard states.isSubset(of: ["idle", "running", "awaitingApproval", "failed", "interrupted"]) else { throw AppMCPError(.invalidRequest) }
            threads = threads.filter { states.contains($0.state.rawValue) }
        }
        let (start, count) = try input.page(), end = min(threads.count, start + min(count, max(0, threads.count - start)))
        return .object(["projectId": id(projectID), "currentThreadId": id(caller.id), "threads": .array(start < threads.count ? threads[start..<end].map(detail) : []),
            "total": .number(Double(threads.count)), "nextCursor": end < threads.count ? .number(Double(end)) : .null])
    }
    private static func threadRead(_ input: Input, view: AppMCPView) throws -> JSONValue {
        try input.only(["threadId", "itemId", "textOffset", "view", "afterPosition", "limit", "runLimit", "maxCharsPerItem"])
        let target = try input.uuid("threadId", required: true)!
        guard let thread = view.snapshot.threads.first(where: { $0.id == target }) else { throw AppMCPError(.notFound) }
        let mode = try input.text("view", maximum: 16) ?? "messages"
        guard ["messages", "activity"].contains(mode) else { throw AppMCPError(.invalidRequest) }
        let messages = thread.messages.filter { $0.removedByHistoryOperationID == nil && (mode == "activity" || [.user, .assistant].contains($0.role)) }
        let limit = try input.integer("limit", default: 20, range: 1...100), maximum = try input.integer("maxCharsPerItem", default: 4_000, range: 1...50_000)
        let offset = try input.integer("textOffset", default: 0, range: 0...Int.max)
        let selectedID = try input.text("itemId", maximum: 512)
        guard selectedID != nil || offset == 0 else { throw AppMCPError(.invalidRequest) }
        let after = try input.integer("afterPosition", default: -1, range: 0...Int.max)
        var items: [JSONValue] = [], next = after, remaining = 100_000, encodedBytes = 0
        for (position, message) in messages.enumerated() where (selectedID == nil ? position > after : message.id == selectedID) {
            guard items.count < limit, remaining > 0 else { break }
            let text = slice(message.text, offset: offset, maximum: min(maximum, remaining)); remaining -= text.text.utf16.count
            let item: JSONValue = .object(["position": .number(Double(position)), "itemId": .string(message.id), "messageId": .string(message.id),
                "runId": message.runReference.map { id($0.runID) } ?? .null, "type": .string(message.role.rawValue), "text": .string(text.text),
                "textTruncated": .bool(text.truncated), "nextTextOffset": text.truncated ? .number(Double(text.next)) : .null, "updatedAt": date(message.createdAt)])
            let bytes = try JSONEncoder().encode(item).count
            guard encodedBytes + bytes <= 350_000 else { break }
            encodedBytes += bytes; items.append(item)
            next = position
            if selectedID != nil { break }
        }
        if selectedID != nil, items.isEmpty { throw AppMCPError(.notFound) }
        let runLimit = try input.integer("runLimit", default: 10, range: 1...50)
        let runs = Array((thread.runHistory ?? []).filter { $0.removedByHistoryOperationID == nil }.suffix(runLimit)).map { run in
            JSONValue.object(["runId": id(run.id), "status": .string(run.status.rawValue), "model": .string(run.configuration.model),
                "provider": .string(run.configuration.provider.rawValue), "startedAt": date(run.startedAt), "completedAt": run.endedAt.map(date) ?? .null])
        }
        return .object(["thread": detail(thread), "recentRuns": .array(runs), "items": .array(items), "nextPosition": items.isEmpty ? .null : .number(Double(next)),
            "hasMore": .bool(selectedID == nil && next < messages.count - 1)])
    }
    private static func search(_ input: Input, view: AppMCPView, caller: CodingThread) throws -> JSONValue {
        try input.only(["query", "projectId", "limit"])
        let query = try input.text("query", maximum: 256, required: true)!, projectID = try input.uuid("projectId") ?? caller.projectID
        let limit = try input.integer("limit", default: 20, range: 1...100)
        let matches = view.snapshot.threads.filter { thread in
            thread.projectID == projectID && !thread.isArchived && (thread.title.localizedCaseInsensitiveContains(query) ||
                thread.messages.contains { $0.removedByHistoryOperationID == nil && $0.text.localizedCaseInsensitiveContains(query) })
        }.prefix(limit).map { thread in JSONValue.object(["threadId": id(thread.id), "projectId": id(thread.projectID), "title": .string(thread.title), "updatedAt": date(thread.updatedAt)]) }
        return .object(["matches": .array(matches)])
    }
    private static func queue(_ name: String, input: Input, view: AppMCPView, caller: CodingThread) throws -> JSONValue {
        try input.only(name == "t3_queue_list" ? ["threadId", "cursor", "limit"] : ["threadId", "queuedRunId"])
        let thread = try thread(input, view: view, caller: caller)
        func entry(_ queued: QueuedTurn, maximum: Int) -> JSONValue {
            let cut = slice(queued.text, offset: 0, maximum: maximum)
            return .object(["queuedRunId": id(queued.id), "text": .string(cut.text), "truncated": .bool(cut.truncated)])
        }
        if name == "t3_queue_read" {
            let id = try input.uuid("queuedRunId", required: true)!
            guard let queued = thread.queuedTurns.first(where: { $0.id == id }) else { throw AppMCPError(.notFound) }
            return entry(queued, maximum: 16_000)
        }
        let (start, count) = try input.page(), end = min(thread.queuedTurns.count, start + min(count, max(0, thread.queuedTurns.count - start)))
        return .object(["items": .array(start < thread.queuedTurns.count ? thread.queuedTurns[start..<end].map { entry($0, maximum: 1_000) } : []),
            "nextCursor": end < thread.queuedTurns.count ? .number(Double(end)) : .null])
    }
    private static func questions(_ name: String, input: Input, view: AppMCPView, caller: CodingThread) throws -> JSONValue {
        try input.only(name == "t3_pending_request_list" ? ["threadId"] : ["threadId", "requestId"])
        let thread = try thread(input, view: view, caller: caller), questions = thread.runtimeRequests.filter { $0.request.isQuestion && !$0.responding }
        if name == "t3_pending_request_list" { return .object(["requestIds": .array(questions.map(\.id))]) }
        let requested = try input.requestID()
        guard let request = questions.first(where: { $0.id == requested }) else { throw AppMCPError(.notFound) }
        let raw = request.request.questions
        guard !raw.isEmpty, raw.count <= 64 else { throw AppMCPError(.unsupported) }
        let normalized: [JSONValue] = try raw.map { value in
            guard let id = value["id"].string, !id.isEmpty, id.utf16.count <= 256,
                  let question = value["question"].string, question.utf16.count <= 16_000 else { throw AppMCPError(.unsupported) }
            let choices = value["options"].array ?? []
            guard choices.count <= 64 else { throw AppMCPError(.unsupported) }
            let options = try choices.map { option -> JSONValue in
                guard let label = option["label"].string, label.utf16.count <= 4_000 else { throw AppMCPError(.unsupported) }
                var fields: [String: JSONValue] = ["label": .string(label), "description": .string(slice(option["description"].string ?? "", offset: 0, maximum: 4_000).text)]
                if let value = option["value"].string {
                    guard value.utf16.count <= 4_000 else { throw AppMCPError(.unsupported) }
                    fields["value"] = .string(value)
                }
                return .object(fields)
            }
            var fields: [String: JSONValue] = ["id": .string(id),
                "header": .string(slice(value["header"].string ?? "", offset: 0, maximum: 1_000).text),
                "question": .string(question), "options": .array(options)]
            for key in ["multiSelect", "allowCustomAnswer", "required"] { if case .bool = value[key] { fields[key] = value[key] } }
            if let initial = value["initialAnswer"].string { fields["initialAnswer"] = .string(slice(initial, offset: 0, maximum: 16_000).text) }
            return .object(fields)
        }
        guard !normalized.isEmpty else { throw AppMCPError(.unsupported) }
        return .object(["requestId": request.id, "questions": .array(normalized)])
    }
    private static func project(_ value: WorkspaceProject) -> JSONValue {
        .object(["id": id(value.id), "title": .string(value.name), "workspaceRoot": .string(value.path),
            "createdAt": value.createdAt.map(date) ?? .null, "updatedAt": value.updatedAt.map(date) ?? .null])
    }
    private static func detail(_ value: CodingThread) -> JSONValue {
        .object(["threadId": id(value.id), "projectId": id(value.projectID), "title": .string(value.title), "status": .string(value.state.rawValue),
            "provider": .string(value.provider.rawValue), "model": .string(value.model), "permission": .string(value.permission.rawValue),
            "activeRunId": value.activeRun.map { id($0.id) } ?? .null, "latestRunId": value.runHistory?.last.map { id($0.id) } ?? .null,
            "archived": .bool(value.isArchived), "settled": .bool(value.isSettled), "pinned": .bool(value.isPinned),
            "workspacePath": .string(value.workspacePath), "queuedCount": .number(Double(value.queuedTurns.count)),
            "pendingQuestionCount": .number(Double(value.runtimeRequests.filter { $0.request.isQuestion && !$0.responding }.count)),
            "createdAt": date(value.createdAt), "updatedAt": date(value.updatedAt)])
    }
    private static func configuration(_ value: CodingThread) throws -> JSONValue {
        let options = try AppMCPProviderModelOptions.captured(.init(thread: value)).sorted { $0.key < $1.key }.map {
            JSONValue.object(["id": .string($0.key), "value": $0.value])
        }
        return .object(["threadId": id(value.id), "provider": .string(value.provider.rawValue), "model": .string(value.model),
            "permission": .string(value.permission.rawValue), "reasoningEffort": value.reasoningEffort.map(JSONValue.string) ?? .null,
            "options": .array(options)])
    }
    private static func id(_ value: UUID) -> JSONValue { .string(value.uuidString.lowercased()) }
    private static func date(_ value: Date) -> JSONValue { .string(value.ISO8601Format()) }
    private static func slice(_ value: String, offset: Int, maximum: Int) -> (text: String, truncated: Bool, next: Int) {
        let units = Array(value.utf16), start = min(offset, units.count)
        var lower = start, upper = start + min(maximum, units.count - start)
        if lower > 0, lower < units.count, (0xDC00...0xDFFF).contains(units[lower]), (0xD800...0xDBFF).contains(units[lower - 1]) { lower -= 1 }
        if upper > lower, upper < units.count, (0xDC00...0xDFFF).contains(units[upper]), (0xD800...0xDBFF).contains(units[upper - 1]) { upper -= 1 }
        // A one-unit budget must still advance across one valid scalar. Never
        // emit a replacement character or a zero-progress pagination cursor.
        if upper == lower, lower < units.count { upper = min(units.count, lower + ((0xD800...0xDBFF).contains(units[lower]) ? 2 : 1)) }
        return (String(decoding: units[lower..<max(lower, upper)], as: UTF16.self), upper < units.count, max(lower, upper))
    }

    private struct Input {
        let value: JSONValue
        let object: [String: JSONValue]
        init(_ value: JSONValue) throws {
            do { try MCPProtocol.validateJSON(value) } catch { throw AppMCPError(.invalidRequest) }
            guard let object = value.object, (try JSONEncoder().encode(value)).count <= 1_048_576 else { throw AppMCPError(.invalidRequest) }
            self.value = value; self.object = object
        }
        func only(_ keys: [String]) throws { guard Set(object.keys).isSubset(of: Set(keys)) else { throw AppMCPError(.invalidRequest) } }
        func text(_ key: String, maximum: Int, required: Bool = false, empty: Bool = false) throws -> String? {
            guard let raw = object[key] else { if required { throw AppMCPError(.invalidRequest) }; return nil }
            guard let text = raw.string, text.utf16.count <= maximum, !text.contains("\0"), empty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppMCPError(.invalidRequest) }
            return text
        }
        func uuid(_ key: String, required: Bool = false) throws -> UUID? {
            guard let raw = object[key], raw != .null else { if required { throw AppMCPError(.invalidRequest) }; return nil }
            guard let text = raw.string, let id = UUID(uuidString: text), text.lowercased() == id.uuidString.lowercased() else { throw AppMCPError(.invalidRequest) }; return id
        }
        func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let raw = object[key] else { return fallback }
            guard case .number(let value) = raw, value.isFinite, value.rounded(.towardZero) == value, value >= Double(range.lowerBound), value < Double(Int.max),
                  value <= Double(range.upperBound), range.contains(Int(value)) else { throw AppMCPError(.invalidRequest) }; return Int(value)
        }
        func boolean(_ key: String, default fallback: Bool) throws -> Bool {
            guard let raw = object[key] else { return fallback }
            guard case .bool(let value) = raw else { throw AppMCPError(.invalidRequest) }; return value
        }
        func absolutePath(_ key: String, required: Bool = false) throws -> String? {
            guard let text = try text(key, maximum: 4_096, required: required) else { return nil }
            guard text.hasPrefix("/"), !text.contains("://"), !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AppMCPError(.invalidRequest) }; return text
        }
        func page() throws -> (Int, Int) { (try integer("cursor", default: 0, range: 0...Int.max), try integer("limit", default: 20, range: 1...100)) }
        func requestID() throws -> JSONValue {
            guard let value = object["requestId"] else { throw AppMCPError(.invalidRequest) }
            switch value {
            case .string(let text): guard !text.isEmpty, text.utf16.count <= 512, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AppMCPError(.invalidRequest) }
            case .number(let number): guard number.isFinite, number.rounded() == number, abs(number) <= 9_007_199_254_740_991 else { throw AppMCPError(.invalidRequest) }
            default: throw AppMCPError(.invalidRequest)
            }
            return value
        }
    }

    private static func scheduledTaskSchedule(_ value: JSONValue) throws -> ScheduledTaskSchedule {
        guard let object = value.object, let type = object["type"]?.string else { throw AppMCPError(.invalidRequest) }
        let schedule: ScheduledTaskSchedule
        switch type {
        case "interval":
            guard Set(object.keys).isSubset(of: ["type", "everyMs"]), let raw = object["everyMs"], case .number(let number) = raw,
                  number.isFinite, number.rounded() == number, number >= 60_000, number <= 31_536_000_000 else { throw AppMCPError(.invalidRequest) }
            schedule = .interval(everyMilliseconds: Int64(number))
        case "fixed_time":
            guard Set(object.keys).isSubset(of: ["type", "timeOfDay", "weekdays"]), let time = object["timeOfDay"]?.string else { throw AppMCPError(.invalidRequest) }
            let rawDays: [JSONValue]
            if let raw = object["weekdays"] { guard let values = raw.array else { throw AppMCPError(.invalidRequest) }; rawDays = values } else { rawDays = [] }
            let days = try rawDays.map { item -> Int in
                guard case .number(let n) = item, n.rounded() == n, (0...6).contains(n) else { throw AppMCPError(.invalidRequest) }; return Int(n)
            }
            schedule = .fixedTime(timeOfDay: time, weekdays: days)
        default: throw AppMCPError(.unsupported) // Webhook credentials are configured privately in native Settings.
        }
        try schedule.validate(); return schedule
    }

    private static var catalog: [MCPToolDefinition] {
        let uuid = string(format: "uuid"), text = string(maximum: 120_000), title = string(maximum: 512)
        let optionalThread = ["threadId": uuid]
        let request = optionalThread.merging(["requestId": .object(["anyOf": .array([string(maximum: 512), .object(["type": .string("number")])])])]) { _, new in new }
        let queued = optionalThread.merging(["queuedRunId": uuid]) { _, new in new }
        let page = ["cursor": integer(minimum: 0), "limit": integer(minimum: 1, maximum: 100)]
        let options: JSONValue = .object(["description": .string("Only options advertised by orchestrator_capabilities. Claude: effort, fastMode, thinking, contextWindow. Codex: reasoningEffort, serviceTier; legacy fastMode is used only when serviceTier is absent. Omitted options preserve inherited settings; empty options clear explicit overrides. Settings apply to future inputs, never an active turn."), "anyOf": .array([
            .object(["type": .string("object"), "maxProperties": .number(64), "additionalProperties": .object(["type": .array([.string("string"), .string("number"), .string("boolean")])])]),
            .object(["type": .string("array"), "maxItems": .number(64), "items": object(["id": string(maximum: 128), "value": .object(["type": .array([.string("string"), .string("number"), .string("boolean")])])], required: ["id", "value"])])
        ])])
        let selection = object(["instanceId": uuid, "providerInstanceId": uuid, "driverKind": string(maximum: 64), "model": string(maximum: 512), "options": options])
        let modes = ["runtimeMode": string(values: ["inherit", "approval-required", "auto-accept-edits", "full-access"]), "interactionMode": string(values: ["inherit", "default"])]
        let creation = object(["title": title, "prompt": text, "target": selection].merging(modes) { _, new in new })
        let workspace = object(["type": string(values: ["root", "worktree", "existing_worktree"]), "baseRef": string(maximum: 1_024), "branch": string(maximum: 256),
            "startFromOrigin": .object(["type": .string("boolean")]), "worktreePath": string(maximum: 4_096)], required: ["type"])
        func tool(_ name: String, _ description: String, _ properties: [String: JSONValue] = [:], required: [String] = [], readOnly: Bool = true, capability: MCPCapability = .orchestration) -> MCPToolDefinition {
            .init(name: name, description: description, inputSchema: object(properties, required: required), capability: capability, readOnly: readOnly)
        }
        let timer = object(["type": string(values: ["interval", "fixed_time"]), "everyMs": integer(minimum: 60_000, maximum: 31_536_000_000),
            "timeOfDay": string(maximum: 5), "weekdays": .object(["type": .string("array"), "maxItems": .number(7), "items": integer(minimum: 0, maximum: 6)])], required: ["type"])
        return [
            tool("read_scheduled_task", "Read one complete prompt in bounded exact UTF-8 byte chunks under its current task revision. Join chunks and verify digest; this never runs the task or exposes webhook credentials.", ["scheduledTaskId": uuid, "revision": uuid, "offset": integer(minimum: 0, maximum: 524_288), "maxBytes": integer(minimum: 4, maximum: 65_536)], required: ["scheduledTaskId", "revision"]),
            tool("list_scheduled_tasks", "List bounded task metadata in this caller’s project. Destination mode is explicit; previews are not complete prompt exports.", ["projectId": uuid, "cursor": integer(minimum: 0, maximum: 100), "limit": integer(minimum: 1, maximum: 20)]),
            tool("schedule_task", "Save persistent authorized automation using this thread’s captured provider/model/permission and checkout. Full-access caller required. By default, occurrences queue into this captured thread; bindToCurrentThread=false creates a fresh thread. Captured provider/settings changes fail closed. Interval minimum 60000ms; fixed times use host local timezone and skip lateness over ten minutes. Webhook credentials require native Settings; no external hosting is configured.", ["title": title, "prompt": text, "enabled": .object(["type": .string("boolean")]), "schedule": timer, "bindToCurrentThread": .object(["type": .string("boolean")]), "commandId": uuid], required: ["title", "prompt", "schedule", "commandId"], readOnly: false),
            tool("update_scheduled_task", "Edit an exact task revision; omitted fields stay unchanged. Stable original commandId is required. Source/profile changes must be reviewed in native Settings.", ["scheduledTaskId": uuid, "revision": uuid, "title": title, "prompt": text, "enabled": .object(["type": .string("boolean")]), "schedule": timer, "bindToCurrentThread": .object(["type": .string("boolean")]), "commandId": uuid], required: ["scheduledTaskId", "revision", "commandId"], readOnly: false),
            tool("delete_scheduled_task", "Delete an exact definition, retaining original run audit. Already accepted input is not repeated or silently stopped.", ["scheduledTaskId": uuid, "revision": uuid, "commandId": uuid], required: ["scheduledTaskId", "revision", "commandId"], readOnly: false),
            tool("run_scheduled_task_now", "Explicitly admit one input to the saved destination under original commandId, even for a paused task. Inspect uncertain original runs before another dispatch. Provider completion is separate from admission.", ["taskId": uuid, "commandId": uuid], required: ["taskId", "commandId"], readOnly: false),
            tool("acknowledge_scheduled_task_run", "Acknowledge an inspected failed or uncertain occurrence. This never resends its input or enables the task.", ["runId": uuid, "commandId": uuid], required: ["runId", "commandId"], readOnly: false),
            tool("delegate_task", "Delegate a self-contained brief to an app-owned child of this active parent. Only the supplied task is sent; parent history is not copied. Prefer provider-native subagent tools when their model/options support the work. This tool supports registered provider profiles and advertised models/options. Shared isolation uses the parent checkout; worktree isolation pins the parent local HEAD, excludes dirty edits and completes discovered project setup before input. Async completion notifies the parent; wait returns on settled result, question, approval or timeout without cancelling the child. Use a distinct clientRequestId for each review round and keep it stable when retrying that round. The backing child thread is not a new delegated review round.",
                 ["task": text, "title": title, "target": selection, "role": string(values: DelegatedTaskRole.allCases.map(\.rawValue)),
                  "isolation": string(values: ["shared", "worktree"]), "mode": string(values: ["async", "wait"]),
                  "timeoutMs": integer(minimum: 0, maximum: TaskOrchestration.maximumWaitMilliseconds), "clientRequestId": string(maximum: 256)].merging(modes) { _, new in new }, required: ["task"], readOnly: false),
            tool("task_status", "Read a task owned by this parent thread. The original result stays stable; later child runs have separate terminal evidence. Working, waiting for nested children and available results are distinct. Reading a terminal result acknowledges its automatic parent delivery. Pending approval metadata grants no approval authority; open the child's current request before acting.", ["taskId": uuid], required: ["taskId"], readOnly: false),
            tool("task_cancel", "Stop the task's backing child and its delegated descendants, including later active child runs after the original task completed. Hold other queued work, cancel the task's own queued input, and dispose automatic parent delivery. Published results remain available. A repeated original request never stops a newer runtime.", ["taskId": uuid, "reason": string(maximum: 2_000), "clientRequestId": string(maximum: 256)], required: ["taskId"], readOnly: false),
            tool("t3_context_read", "Read immutable context captured for this exact active input. A full orchestration caller may also read a saved result transfer from its own delegated task. Context-only sessions retain exact input ownership; unrelated threads, mutable later source edits, private reasoning and native session internals are excluded. Pages and UTF-8 text slices are bounded, with explicit continuation offsets.", ["transferId": uuid, "itemId": string(maximum: 4_096), "afterPosition": integer(minimum: 0), "textOffset": integer(minimum: 0), "limit": integer(minimum: 1, maximum: 100), "maxBytesPerItem": integer(minimum: 1, maximum: 65_536)], required: ["transferId"], capability: .contextRead),
            tool("orchestrator_capabilities", "Read available native providers and models, current permission ceilings, and explicit app capability gaps. An explicit request may refresh provider metadata; listing tools never launches a provider.", ["search": string(maximum: 200)]),
            tool("t3_environment_read", "Read this native app's platform and supported app tools. This does not reveal process environment, account profiles or credentials."),
            tool("t3_project_list", "List registered projects. Pages use a live offset and may shift between requests.", page),
            tool("t3_project_read", "Read one registered project's name and workspace path. No raw provider configuration, saved credential or process environment is returned.", ["projectId": uuid], required: ["projectId"]),
            tool("t3_project_create", "Register an explicit local workspace or create a managed project by title through the native project lifecycle. Requires a live full-access caller; each call is a new request.", ["title": title, "workspaceRoot": string(maximum: 4_096), "createWorkspaceRootIfMissing": .object(["type": .string("boolean")])], required: ["title"], readOnly: false),
            tool("t3_project_update", "Rename a registered project. Other project settings are preserved. Requires a live full-access caller.", ["projectId": uuid, "title": title], required: ["projectId", "title"], readOnly: false),
            tool("t3_project_delete", "Remove a registered project through its normal cleanup lifecycle. Nonempty projects require force=true. Repository files are not deleted. Requires a live full-access caller.", ["projectId": uuid, "force": .object(["type": .string("boolean")])], required: ["projectId"], readOnly: false),
            tool("create_threads", "Create up to 20 independent threads in the caller's current workspace, preserving parent creation audit and a supplied retry key. This is not delegated-task completion or parent wakeup.", ["threads": .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(20), "items": creation]), "clientRequestId": string(maximum: 256)], required: ["threads"], readOnly: false),
            tool("t3_thread_launch", "Create an ordinary top-level thread with an explicit project/workspace binding before its optional first input. Omitted workspaceStrategy means the project root, not the caller's worktree. It never copies the current draft or sends an implicit continuation. Each call creates a new launch; inspect thread_list after a lost response before retrying.", ["projectId": uuid, "title": title, "modelSelection": selection, "message": text, "workspaceStrategy": workspace].merging(modes) { _, new in new }, required: ["title"], readOnly: false),
            tool("t3_thread_list", "List active registered threads in a project, defaulting to the caller's project. Native app statuses are idle, running, awaitingApproval, failed and interrupted. Pages use live offsets.", ["projectId": uuid, "statuses": .object(["type": .string("array"), "maxItems": .number(10), "items": string(values: ["idle", "running", "awaitingApproval", "failed", "interrupted"])]), "titleContains": string(maximum: 256), "settled": .object(["type": .string("boolean")])].merging(page) { _, new in new }),
            tool("t3_thread_read", "Read bounded visible native-app history, recent run status and safe thread metadata. Removed history remains excluded. Messages view includes user/assistant text; activity includes other timeline rows. itemId plus textOffset reads another text slice without changing the thread.", ["threadId": uuid, "itemId": string(maximum: 512), "textOffset": integer(minimum: 0), "view": string(values: ["messages", "activity"]), "afterPosition": integer(minimum: 0), "limit": integer(minimum: 1, maximum: 100), "runLimit": integer(minimum: 1, maximum: 50), "maxCharsPerItem": integer(minimum: 1, maximum: 50_000)], required: ["threadId"]),
            tool("t3_thread_search", "Search active thread titles and retained message text in one project, defaulting to the caller's project. Results are bounded and do not promise exhaustive coverage or stable pagination.", ["query": string(maximum: 256), "projectId": uuid, "limit": integer(minimum: 1, maximum: 100)], required: ["query"]),
            tool("t3_thread_update", "Rename a thread through the native command lifecycle. This app does not advertise title generation or PR-link mutations through this tool.", ["threadId": uuid, "action": string(values: ["rename"]), "title": title, "clientRequestId": string(maximum: 256)], required: ["action", "title"], readOnly: false),
            tool("t3_thread_configuration", "Read the thread's native provider/model and permission settings. Authentication bindings, runtime launch paths and provider-private metadata are excluded.", optionalThread),
            tool("t3_thread_configure", "Choose an advertised provider/model and options through the native selection lifecycle. This never broadens permissions or changes authentication/runtime paths. Omitted options preserve inherited values; empty options clear them.", optionalThread.merging(["modelSelection": selection]) { _, new in new }, required: ["modelSelection"], readOnly: false),
            tool("t3_thread_send", "Deliver explicit literal input through the app's native start, queue, steer or restart behavior. Delivery acceptance is not provider completion. Captured FIFO inputs and current draft remain separate; retries must reuse clientRequestId.", ["threadId": uuid, "message": text, "mode": string(values: ["auto", "queue", "steer", "restart"]), "clientRequestId": string(maximum: 256)], required: ["threadId", "message"], readOnly: false),
            tool("t3_thread_wait", "Wait at most ten minutes for one exact run or the thread's selected run to reach terminal/waiting state. A timeout returns status and never cancels, resends or starts work.", ["threadId": uuid, "runId": uuid, "timeoutMs": integer(minimum: 0, maximum: 600_000)], required: ["threadId"]),
            tool("t3_thread_interrupt", "Request Stop for the exact current run, optionally fencing runId. It does not send another input or grant approval.", ["threadId": uuid, "runId": uuid, "reason": string(maximum: 2_000)], required: ["threadId"], readOnly: false),
            tool("t3_thread_organize", "Pin, archive, settle or resume a thread through native lifecycle rules. Settling the caller must wait for that exact successful turn and an empty queue; unsupported lifecycle transitions are refused.", ["threadId": uuid, "action": string(values: ["pin", "unpin", "archive", "unarchive", "settle", "unsettle"])], required: ["action"], readOnly: false),
            tool("t3_thread_fork", "Create a reviewed fork from an exact run or ready after-run checkpoint. Latest stable requires a completed run with a ready checkpoint. A verified native fork or bounded portable context is delivered only with the target's next explicit input; the current draft is preserved.", ["threadId": uuid, "sourcePoint": object(["type": string(values: ["latest_stable", "run", "checkpoint"]), "runId": uuid, "checkpointId": uuid], required: ["type"]), "title": title], required: ["sourcePoint"], readOnly: false),
            tool("t3_thread_merge_back", "Queue reviewed child conversation delta for its actual parent in the same project. Existing lineage and already transferred-item coverage apply. No Git/filesystem merge or provider input is performed by this command.", ["sourceThreadId": uuid, "targetThreadId": uuid, "sourcePoint": object(["type": string(values: ["latest_stable", "run", "checkpoint"]), "runId": uuid, "checkpointId": uuid], required: ["type"])], required: ["targetThreadId", "sourcePoint"], readOnly: false),
            tool("t3_thread_transfers", "Read bounded context-transfer status and delivery outcomes for one thread. Pages use live offsets; no native evidence, historical archive or credentials are returned.", optionalThread.merging(page) { _, new in new }),
            tool("t3_queue_list", "List queued inputs in captured delivery order, with up to 1,000 UTF-16 units of each text. This is a live offset page; it never starts or resumes the queue.", optionalThread.merging(page) { _, new in new }),
            tool("t3_queue_read", "Read up to 16,000 UTF-16 units of one exact queued input. Its captured configuration and attachment paths are not returned.", queued, required: ["queuedRunId"]),
            tool("t3_queue_edit", "Replace the text of an exact still-queued input in place. Preserve its attachments, captured provider configuration and queue position; never move it into the current draft.", queued.merging(["text": string(maximum: 100_000, empty: true)]) { _, new in new }, required: ["queuedRunId", "text"], readOnly: false),
            tool("t3_queue_cancel", "Cancel one exact still-queued input through the native queue command. The active run is unaffected.", queued, required: ["queuedRunId"], readOnly: false),
            tool("t3_queue_reorder", "Move a still-queued input before another queued input, or to the end with beforeRunId=null. Captured input configuration and attachments are unchanged.", queued.merging(["beforeRunId": .object(["anyOf": .array([uuid, .object(["type": .string("null")])])])]) { _, new in new }, required: ["queuedRunId", "beforeRunId"], readOnly: false),
            tool("t3_queue_promote_to_steer", "Promote one exact queued input to steering for the specified active run through reviewed native steering admission. Unsupported/stale targets are refused; no fallback ordinary send occurs.", queued.merging(["targetRunId": uuid]) { _, new in new }, required: ["queuedRunId", "targetRunId"], readOnly: false),
            tool("t3_pending_request_list", "List unanswered user questions only. Permission approvals are excluded and cannot be approved through app tools.", optionalThread),
            tool("t3_pending_request_read", "Read the safe question/choice presentation for an exact pending user-input request. Raw provider request payloads and permission approvals are excluded.", request, required: ["requestId"]),
            tool("t3_pending_request_respond", "Answer an exact currently pending user question. This cannot approve a permission request. The native response validator rechecks current generation, offered choices and limits before dispatch.", request.merging(["answers": .object(["type": .string("object"), "minProperties": .number(1), "maxProperties": .number(64), "additionalProperties": string(maximum: 16_000, empty: true)])]) { _, new in new }, required: ["requestId", "answers"], readOnly: false),
            tool("t3_worktree_status", "Read the calling thread's exact registered workspace binding and whether native app preparation proved a separate worktree. Active-thread worktree handoff is not supported by this tool surface.", capability: .worktree)
        ]
    }
    private static func object(_ fields: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(fields), "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }
    private static func string(maximum: Int? = nil, format: String? = nil, values: [String]? = nil, empty: Bool = false) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("string")]
        if !empty { fields["minLength"] = .number(1) }
        if let maximum { fields["maxLength"] = .number(Double(maximum)) }
        if let format { fields["format"] = .string(format) }
        if let values { fields["enum"] = .array(values.map(JSONValue.string)) }
        return .object(fields)
    }
    private static func integer(minimum: Int, maximum: Int? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("integer"), "minimum": .number(Double(minimum))]
        if let maximum { fields["maximum"] = .number(Double(maximum)) }
        return .object(fields)
    }
}
