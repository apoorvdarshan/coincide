import CryptoKit
import Foundation

/// A transient advertised slash command. It is never a shell command or a
/// persisted authority to execute a provider resource.
public struct ProviderCommand: Sendable, Equatable, Identifiable {
    public let name: String
    public let description: String
    public let source: String?
    public let hints: [String]
    public let enabled: Bool
    public let userInvocable: Bool
    public init(name: String, description: String = "", source: String? = nil, hints: [String] = [],
                enabled: Bool = true, userInvocable: Bool = true) {
        self.name = name; self.description = description; self.source = source; self.hints = hints
        self.enabled = enabled; self.userInvocable = userInvocable
    }
    public var id: String { SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined() }
    public var canInvokeFromComposer: Bool {
        enabled && userInvocable && (try? validate()) != nil &&
            !name.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" })
    }
    public var promptToken: String? { canInvokeFromComposer ? "/" + name : nil }
    public func validate() throws {
        do {
            try SkillValidation.text(name, maximum: 256, empty: false)
            try SkillValidation.text(description, maximum: 16_384, multiline: true)
            if let source { try SkillValidation.text(source, maximum: 128, empty: false) }
            guard hints.count <= 32 else { throw ProviderCommandError(.invalidResponse) }
            for hint in hints { try SkillValidation.text(hint, maximum: 4_096, multiline: true) }
        } catch { throw ProviderCommandError(.invalidResponse) }
    }
}

/// Parsing never claims that a command exists. The live adapter must match the
/// exact advertised name before it selects a native command endpoint.
public struct ProviderCommandSelection: Sendable, Equatable {
    public let name: String
    public let arguments: String
    public init(name: String, arguments: String = "") throws {
        let row = ProviderCommand(name: name)
        guard row.canInvokeFromComposer else { throw ProviderCommandError(.invalidResponse) }
        do { try SkillValidation.text(arguments, maximum: 4_194_304, multiline: true) }
        catch { throw ProviderCommandError(.invalidResponse) }
        self.name = name; self.arguments = arguments
    }
    public static func parse(_ text: String) throws -> Self? {
        guard text.utf8.count <= 4_194_304 else { throw ProviderCommandError(.invalidResponse) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "/" else { return nil }
        let remainder = trimmed.dropFirst()
        let end = remainder.firstIndex(where: \.isWhitespace) ?? remainder.endIndex
        let name = String(remainder[..<end])
        guard ProviderCommand(name: name).canInvokeFromComposer else { return nil }
        let arguments = end == remainder.endIndex ? "" : String(remainder[end...].drop(while: \.isWhitespace))
        return try .init(name: name, arguments: arguments)
    }
}

public struct ProviderCommandProblem: Sendable, Equatable {
    public enum Component: String, Sendable { case commands, skills }
    public let component: Component
    public let name: String?
    public let message: String
    public init(component: Component, name: String? = nil, message: String) {
        self.component = component; self.name = name; self.message = message
    }
}

public struct ProviderCommandInventory: Sendable, Equatable {
    public let cwd: String
    public let commands: [ProviderCommand]
    public let skills: [ProviderSkill]
    public let problems: [ProviderCommandProblem]
    public let checkedAt: Date
    public init(cwd: String, commands: [ProviderCommand], skills: [ProviderSkill],
                problems: [ProviderCommandProblem] = [], checkedAt: Date = .now) {
        self.cwd = cwd; self.commands = commands; self.skills = skills; self.problems = problems; self.checkedAt = checkedAt
    }
    public var workspacePath: String { cwd }
    public var isPartial: Bool { !problems.isEmpty }
    public func validate() throws {
        do {
            try ProviderHistoryValidation.path(cwd)
            guard commands.count <= 2_000, skills.count <= 2_000, problems.count <= 256,
                  checkedAt.timeIntervalSince1970.isFinite,
                  Set(commands.map(\.name)).count == commands.count,
                  Set(skills.map(\.name)).count == skills.count else { throw ProviderCommandError(.invalidResponse) }
            for command in commands { try command.validate() }
            for skill in skills { try skill.validate() }
            for problem in problems {
                if let name = problem.name { try SkillValidation.text(name, maximum: 256, empty: false) }
                try SkillValidation.text(problem.message, maximum: 4_096, empty: false, multiline: true)
            }
        } catch { throw ProviderCommandError(.invalidResponse) }
    }
}

public struct ProviderCommandError: LocalizedError, Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case unsupported, invalidResponse, unavailable }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .unsupported: "This provider connection does not support native command discovery."
        case .invalidResponse: "The provider's commands or skills could not be read safely. Refresh and try again."
        case .unavailable: "Commands and skills could not be refreshed. Check the provider connection and try again."
        }
    }
}
