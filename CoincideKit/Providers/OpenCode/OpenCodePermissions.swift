import Foundation

/// One OpenCode permission rule. In a ruleset the last matching rule wins.
struct OpenCodeRule: Hashable, Sendable {
    var action: String
    var resource: String
    /// "allow", "ask" or "deny".
    var effect: String

    nonisolated init(_ action: String, _ effect: String, resource: String = "*") {
        self.action = action
        self.resource = resource
        self.effect = effect
    }

    nonisolated init?(json: JSONValue) {
        guard let action = json["action"]?.string, let resource = json["resource"]?.string,
            let effect = json["effect"]?.string
        else { return nil }
        self.init(action, effect, resource: resource)
    }

    nonisolated var json: JSONValue {
        ["action": .string(action), "resource": .string(resource), "effect": .string(effect)]
    }
}

/// Session permission rules for Coincide's access and interaction modes, mirroring T3 Code.
enum OpenCodePermissions {
    /// The ruleset written to a session. Session rules apply after the agent's own rules.
    /// - Parameters:
    ///   - grants: actions the user allowed for the rest of the session.
    ///   - agentPaths: path-scoped allows of the session's agent (such as the plan agent's plan folder),
    ///     re-applied so the broader rules here do not hide them.
    nonisolated static func rules(
        accessMode: AccessMode, plan: Bool, grants: [OpenCodeRule], agentPaths: [OpenCodeRule]
    ) -> [OpenCodeRule] {
        var rules: [OpenCodeRule]
        switch accessMode {
        case .fullAccess:
            rules = [OpenCodeRule("*", "allow")]
        case .approval:
            rules = [OpenCodeRule("shell", "ask"), OpenCodeRule("edit", "ask"), OpenCodeRule("external_directory", "ask")]
            rules += grants
        }
        if plan { rules.append(OpenCodeRule("edit", "deny")) }
        if accessMode == .approval || plan { rules += agentPaths }
        return rules
    }

    /// Path-scoped allows for edits and outside directories from an agent's ruleset.
    nonisolated static func agentPaths(_ rules: [OpenCodeRule]) -> [OpenCodeRule] {
        var seen = Set<OpenCodeRule>()
        return rules.filter { rule in
            rule.effect == "allow" && rule.resource != "*"
                && (rule.action == "edit" || rule.action == "external_directory") && seen.insert(rule).inserted
        }
    }

    /// The agent's path allows, keyed by agent id, from `GET /api/agent`.
    nonisolated static func agentPaths(fromAgents agents: [JSONValue]) -> [String: [OpenCodeRule]] {
        var result: [String: [OpenCodeRule]] = [:]
        for agent in agents {
            guard let id = agent["id"]?.string else { continue }
            result[id] = agentPaths((agent["permissions"]?.array ?? []).compactMap(OpenCodeRule.init(json:)))
        }
        return result
    }

    /// The agent OpenCode runs for an interaction mode.
    nonisolated static func agent(for mode: InteractionMode) -> String {
        mode == .plan ? "plan" : "build"
    }

    // MARK: Approvals

    nonisolated static let allowOptionID = "once"
    nonisolated static let allowForSessionOptionID = "session"
    nonisolated static let denyOptionID = "reject"
    nonisolated static let stopOptionID = "stop"

    /// The choices for a permission request. "Allow for the session" is offered when OpenCode suggests
    /// patterns to remember; Coincide keeps those as session rules instead of saving them for the project.
    nonisolated static func options(action: String, save: [String]) -> [ApprovalOption] {
        var options = [ApprovalOption(id: allowOptionID, label: String(localized: "Allow"), kind: .allowOnce)]
        if !save.isEmpty {
            let label =
                save.allSatisfy { $0 == "*" }
                ? String(localized: "Allow every \(actionName(action)) this session")
                : String(localized: "Allow \(save.joined(separator: ", ")) this session")
            options.append(ApprovalOption(id: allowForSessionOptionID, label: label, kind: .allowAlways))
        }
        options.append(ApprovalOption(id: denyOptionID, label: String(localized: "Deny"), kind: .deny))
        options.append(ApprovalOption(id: stopOptionID, label: String(localized: "Deny and stop"), kind: .cancel))
        return options
    }

    /// What the agent is told when the user denies a request, so it does not simply retry.
    nonisolated static func declinedNote(action: String, resources: [String]) -> String {
        let target = resources.isEmpty ? "" : " (\(resources.joined(separator: ", ")))"
        return "The user declined the \(action) request\(target). "
            + "Do not retry it; continue without it or ask the user how to proceed."
    }

    nonisolated static let declinedMessage = "The user declined this request."

    private nonisolated static func actionName(_ action: String) -> String {
        switch action {
        case "shell": String(localized: "command")
        case "edit": String(localized: "file edit")
        case "external_directory": String(localized: "access outside the project")
        case "webfetch", "websearch": String(localized: "web request")
        default: action
        }
    }
}
