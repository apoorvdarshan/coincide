import Foundation

/// A local agent invocation. Arguments are passed literally, never through a shell.
/// Agent credentials remain in the agent's own sign-in and configuration stores.
public struct ACPAgentConfiguration: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var executable: String
    public var arguments: [String]
    public var experimentalV2: Bool?
    public var integration: ACPIntegration?
    public init(id: UUID = UUID(), name: String, executable: String, arguments: [String] = []) {
        self.id = id; self.name = name; self.executable = executable; self.arguments = arguments
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
              !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, executable.utf8.count <= 4_096,
              !executable.utf8.contains(0), arguments.count <= 100,
              arguments.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 16_384 }) else {
            throw CoincideError("Enter an agent name, executable, and valid arguments.")
        }
        if let integration {
            guard URL(fileURLWithPath: executable).lastPathComponent == integration.executable,
                  arguments == integration.arguments else {
                throw CoincideError("Use this integration's stdio command, or choose Custom ACP for a different invocation.")
            }
        }
    }
}
