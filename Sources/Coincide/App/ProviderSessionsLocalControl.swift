import CoincideCore
import Foundation

/// Same ownership boundary as the native Sessions page, through the private
/// local-owner channel. An explicit stop confirmation is never inferred.
@MainActor
enum ProviderSessionsLocalControl {
    static func invoke(action: String, arguments: JSONValue, scope: ProviderSessionsScope) async throws -> JSONValue {
        guard ["session-details", "session-stop"].contains(action),
              let id = arguments["session_id"].string, !id.isEmpty, id.utf8.count <= 320,
              !id.contains("\0") else { throw MCPError(.invalidParams) }
        if action == "session-stop", arguments["confirm"] != .bool(true) {
            throw CoincideError("Stopping affects the original provider session. Use session-stop with its exact ID and --confirm.")
        }
        let snapshot = try await ProviderSessionsService.list(scope: scope)
        guard let session = snapshot.sessions.first(where: { $0.id == id }) else {
            throw CoincideError("Session not found in the current configuration. Run sessions again and use its exact ID.")
        }
        if action == "session-stop" {
            try await ProviderSessionsService.stop(scope: scope, session: session)
            return .object(["sessionId": .string(id), "provider": .string(session.provider.rawValue),
                "stopRequested": .bool(true), "conversationPreserved": .bool(true),
                "note": .string("The provider accepted the stop request. Refresh sessions to check its current state.")])
        }
        let details = try await ProviderSessionsService.details(scope: scope, session: session)
        return .object(["sessionId": .string(id), "provider": .string(session.provider.rawValue),
            "state": .string(details.session.state.rawValue), "canStop": .bool(details.session.canStop),
            "output": .string(details.output), "resumeCommand": .string(details.resumeCommand),
            "note": .string(details.note), "providerOwned": .bool(true)])
    }
}
