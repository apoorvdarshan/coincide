import CryptoKit
import Darwin
import Foundation

/// Transient advertised metadata. A skill path is a display value, never an
/// authorization to read a file or execute its contents.
public struct ProviderSkill: Sendable, Equatable, Identifiable {
    public let name: String
    public let path: String
    public let displayName: String?
    public let description: String
    public let shortDescription: String?
    public let scope: String
    public let enabled: Bool
    public let userInvocable: Bool
    /// Opaque provider identity, distinct from the skill's advertised name.
    /// It never authorizes opening the display path.
    public let nativeID: String?
    public init(name: String, path: String, displayName: String? = nil, description: String = "",
                shortDescription: String? = nil, scope: String = "", enabled: Bool = true, userInvocable: Bool = true,
                nativeID: String? = nil) {
        self.name = name; self.path = path; self.displayName = displayName; self.description = description
        self.shortDescription = shortDescription; self.scope = scope; self.enabled = enabled; self.userInvocable = userInvocable
        self.nativeID = nativeID
    }
    public var id: String {
        var bytes = Data()
        for value in [name, path, scope] {
            bytes.append(contentsOf: String(value.utf8.count).utf8); bytes.append(0)
            bytes.append(contentsOf: value.utf8); bytes.append(0)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    public func validate() throws {
        try SkillValidation.text(name, maximum: 256, empty: false)
        try SkillValidation.text(path, maximum: 4_096, empty: false)
        try SkillValidation.text(scope, maximum: 128)
        try SkillValidation.text(description, maximum: 16_384, multiline: true)
        if let displayName { try SkillValidation.text(displayName, maximum: 256) }
        if let shortDescription { try SkillValidation.text(shortDescription, maximum: 4_096, multiline: true) }
        if let nativeID { try SkillValidation.text(nativeID, maximum: 4_096, empty: false) }
    }
    /// Pinned T3's skill-token grammar, including its currency/number exclusion.
    public var canInvokeFromComposer: Bool {
        guard enabled, userInvocable, (try? validate()) != nil,
              name.range(of: "^[A-Za-z0-9][A-Za-z0-9:_-]*$", options: .regularExpression) != nil,
              name.range(of: "[A-Za-z]", options: .regularExpression) != nil else { return false }
        return name.range(of: "^[0-9][0-9_]*(?:[kKmMbBtT]|[eE][0-9]+)?$", options: .regularExpression) == nil
    }
    public var promptToken: String? { canInvokeFromComposer ? "$" + name : nil }
}

public struct ProviderSkillProblem: Sendable, Equatable {
    public let path: String?
    public let message: String
    public init(path: String? = nil, message: String) { self.path = path; self.message = message }
}

public struct ProviderSkillInventory: Sendable, Equatable {
    public let cwd: String
    public let skills: [ProviderSkill]
    public let problems: [ProviderSkillProblem]
    public let checkedAt: Date
    public init(cwd: String, skills: [ProviderSkill], problems: [ProviderSkillProblem] = [], checkedAt: Date = .now) {
        self.cwd = cwd; self.skills = skills; self.problems = problems; self.checkedAt = checkedAt
    }
    public var workspacePath: String { cwd }
    public var isPartial: Bool { !problems.isEmpty }
    public func validate() throws {
        try SkillValidation.text(cwd, maximum: 4_096, empty: false)
        guard cwd.hasPrefix("/"), skills.count <= 2_000, problems.count <= 256,
              checkedAt.timeIntervalSince1970.isFinite, Set(skills.map(\.id)).count == skills.count else { throw ProviderSkillError(.invalidResponse) }
        for skill in skills { try skill.validate() }
        for problem in problems {
            if let path = problem.path { try SkillValidation.text(path, maximum: 4_096, empty: false) }
            try SkillValidation.text(problem.message, maximum: 4_096, empty: false, multiline: true)
        }
    }
}

public struct ProviderSkillError: LocalizedError, Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case unsupported, invalidResponse, unavailable }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .unsupported: "This provider connection does not support native skill discovery."
        case .invalidResponse: "The provider's skills could not be read safely. Refresh skills and try again."
        case .unavailable: "Skills could not be refreshed. Check the provider connection and try again."
        }
    }
}

enum SkillValidation {
    static func text(_ value: String, maximum: Int, empty: Bool = true, multiline: Bool = false) throws {
        guard value.utf8.count <= maximum, empty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { ($0.value < 32 && !(multiline && [9, 10, 13].contains($0.value))) || $0.value == 127 }) else {
            throw ProviderSkillError(.invalidResponse)
        }
    }
    static func optional(_ value: JSONValue, maximum: Int, multiline: Bool = false) throws -> String? {
        if value == .null { return nil }
        guard let string = value.string else { throw ProviderSkillError(.invalidResponse) }
        try text(string, maximum: maximum, multiline: multiline); return string
    }
}

enum CodexSkillInventory {
    static func decode(_ value: JSONValue, cwd: String) throws -> ProviderSkillInventory {
        guard value.object != nil, try JSONEncoder().encode(value).count <= 4 * 1_024 * 1_024,
              let entries = value["data"].array, entries.count <= 64 else { throw ProviderSkillError(.invalidResponse) }
        let matching = try entries.filter { entry in
            guard entry.object != nil, let path = entry["cwd"].string else { throw ProviderSkillError(.invalidResponse) }
            try SkillValidation.text(path, maximum: 4_096, empty: false)
            return sameWorkspace(path, cwd)
        }
        guard matching.count == 1, let entry = matching.first,
              let rows = entry["skills"].array, rows.count <= 2_000,
              let errors = entry["errors"].array, errors.count <= 256 else { throw ProviderSkillError(.invalidResponse) }
        var skills: [ProviderSkill] = [], problems: [ProviderSkillProblem] = []
        var seen: [String: ProviderSkill] = [:], ambiguous: Set<String> = []
        for error in errors {
            guard error.object != nil, let path = error["path"].string, error["message"].string != nil else { throw ProviderSkillError(.invalidResponse) }
            try SkillValidation.text(path, maximum: 4_096, empty: false)
            problems.append(.init(path: path, message: "A skill could not be loaded. Review its source with the provider CLI."))
        }
        for row in rows {
            do {
                let skill = try decodeSkill(row)
                guard !ambiguous.contains(skill.id) else { continue }
                if let previous = seen[skill.id] {
                    if previous != skill {
                        skills.removeAll { $0.id == skill.id }; ambiguous.insert(skill.id)
                        problems.append(.init(path: skill.path, message: "Conflicting skill metadata was omitted. Refresh skills before using it."))
                    }
                } else { skills.append(skill); seen[skill.id] = skill }
            } catch {
                let path = problemPath(row["path"])
                problems.append(.init(path: path, message: "Invalid skill metadata was omitted. Refresh skills before using it."))
            }
            guard problems.count <= 256 else { throw ProviderSkillError(.invalidResponse) }
        }
        let result = ProviderSkillInventory(cwd: cwd, skills: skills, problems: problems)
        try result.validate(); return result
    }
    private static func problemPath(_ value: JSONValue) -> String? {
        guard let path = value.string, (try? SkillValidation.text(path, maximum: 4_096, empty: false)) != nil else { return nil }
        return path
    }
    private static func decodeSkill(_ value: JSONValue) throws -> ProviderSkill {
        guard value.object != nil, let name = value["name"].string, let path = value["path"].string,
              let description = value["description"].string, let scope = value["scope"].string,
              case .bool(let enabled) = value["enabled"], value["interface"] == .null || value["interface"].object != nil else {
            throw ProviderSkillError(.invalidResponse)
        }
        let skill = ProviderSkill(name: name, path: path,
            displayName: try SkillValidation.optional(value["interface"]["displayName"], maximum: 256), description: description,
            shortDescription: try SkillValidation.optional(value["shortDescription"], maximum: 4_096, multiline: true)
                ?? SkillValidation.optional(value["interface"]["shortDescription"], maximum: 4_096, multiline: true),
            scope: scope, enabled: enabled)
        // The reviewed Codex schema has no userInvocable/agent-only policy;
        // dependencies and unknown fields do not invent such a restriction.
        try skill.validate(); return skill
    }
    static func sameWorkspace(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.hasPrefix("/"), rhs.hasPrefix("/") else { return false }
        var left = stat(), right = stat()
        guard stat(lhs, &left) == 0, stat(rhs, &right) == 0,
              left.st_mode & S_IFMT == S_IFDIR, right.st_mode & S_IFMT == S_IFDIR else { return false }
        return left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }
}
