import Foundation

/// Cursor notifications describe provider activity. They never authorize a
/// client tool, image generation, filesystem read or a new provider invocation.
struct CursorACPNotifications {
    private var todos: [CursorACPTodo] = []
    static func handles(_ method: String) -> Bool {
        ["_cursor/update_todos", "cursor/update_todos", "_cursor/task", "cursor/task",
         "_cursor/generate_image", "cursor/generate_image"].contains(method)
    }
    mutating func consume(method: String, params: JSONValue, sessionID: String, runID: UUID) throws -> ProviderEntityUpdate? {
        guard Self.handles(method) else { return nil }
        try ACPIntegrationValidation.bound(params)
        guard params.object != nil, let toolID = try ACPIntegrationValidation.string(params["toolCallId"], maximum: 4_096) else {
            throw ACPIntegrationValidation.failure()
        }
        if method.hasSuffix("/update_todos") {
            let incoming = try CursorACPPlanRequest.decodeTodos(params["todos"])
            guard case .bool(let merge) = params["merge"] else { throw ACPIntegrationValidation.failure() }
            var next = merge ? todos : []
            for todo in incoming {
                if let index = next.firstIndex(where: { $0.id == todo.id }) { next[index] = todo }
                else { next.append(todo) }
            }
            guard next.count <= 256 else { throw ACPIntegrationValidation.failure() }
            todos = next
            let entries: [JSONValue] = next.map { .object(["id": .string($0.id), "content": .string($0.content), "status": .string($0.status.rawValue)]) }
            return .patch(.init(sessionID: sessionID, type: "plan", id: "cursor-todos-\(runID)"),
                .object(["title": .string("Cursor todos"), "entries": .array(entries)]))
        }
        guard let description = try ACPIntegrationValidation.string(params["description"], maximum: 32_768, multiline: true) else {
            throw ACPIntegrationValidation.failure()
        }
        var input: [String: JSONValue] = ["description": .string(description)]
        let title: String
        if method.hasSuffix("/task") {
            guard let prompt = try ACPIntegrationValidation.string(params["prompt"], maximum: 262_144, multiline: true) else {
                throw ACPIntegrationValidation.failure()
            }
            let type = params["subagentType"]
            if let name = type.string, ["unspecified", "computer_use", "explore", "video_review", "browser_use", "shell", "vm_setup_helper"].contains(name) {
                input["subagentType"] = .string(name)
            } else if type.object != nil, let custom = try ACPIntegrationValidation.string(type["custom"], maximum: 1_024) {
                input["subagentType"] = .object(["custom": .string(custom)])
            } else { throw ACPIntegrationValidation.failure() }
            input["prompt"] = .string(prompt)
            for name in ["model", "agentId"] {
                if let text = try ACPIntegrationValidation.string(params[name], maximum: 4_096) { input[name] = .string(text) }
            }
            if params["durationMs"] != .null {
                guard case .number(let duration) = params["durationMs"], duration.isFinite, duration >= 0 else { throw ACPIntegrationValidation.failure() }
                input["durationMs"] = .number(duration)
            }
            title = "Cursor task · \(description)"
        } else {
            if let path = try ACPIntegrationValidation.string(params["filePath"], maximum: 4_096) { input["filePath"] = .string(path) }
            if params["referenceImagePaths"] != .null {
                guard let paths = params["referenceImagePaths"].array, paths.count <= 64 else { throw ACPIntegrationValidation.failure() }
                input["referenceImagePaths"] = .array(try paths.map {
                    guard let path = try ACPIntegrationValidation.string($0, maximum: 4_096) else { throw ACPIntegrationValidation.failure() }
                    return .string(path)
                })
            }
            title = "Cursor image · \(description)"
        }
        // Standard tool_call updates use this same key and retain actual status.
        return .patch(.init(sessionID: sessionID, type: "tool_call", id: toolID),
            .object(["title": .string(title), "rawInput": .object(input),
                "_meta": .object(["cursor": .object(["notification": .string(method)])])]))
    }
}
