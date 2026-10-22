import Foundation

/// Read-only account metadata. These values deliberately have no persistence conformance.
public enum CodexAccountKind: Sendable, Equatable {
    case signedOut, apiKey, chatgpt, amazonBedrock
    case unknown(String)
}

public struct CodexAccountIdentity: Sendable, Equatable {
    public let kind: CodexAccountKind
    public let requiresOpenAIAuth: Bool
    public let email: String?
    public let planType: String?
    /// Opaque, memory-only correlation value; not a label or a credential.
    public let accountID: String?

    public init(kind: CodexAccountKind, requiresOpenAIAuth: Bool, email: String? = nil,
                planType: String? = nil, accountID: String? = nil) {
        self.kind = kind; self.requiresOpenAIAuth = requiresOpenAIAuth
        self.email = email; self.planType = planType; self.accountID = accountID
    }
}

public struct CodexUsageWindow: Sendable, Equatable {
    public let usedPercent: Double
    public let windowDurationMinutes: Int?
    public let resetsAt: Date?

    public init(usedPercent: Double, windowDurationMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.usedPercent = usedPercent; self.windowDurationMinutes = windowDurationMinutes; self.resetsAt = resetsAt
    }
}

public struct CodexUsageCredits: Sendable, Equatable {
    public let hasCredits: Bool
    public let unlimited: Bool
    /// Provider text; no currency or precision is inferred.
    public let balance: String?

    public init(hasCredits: Bool, unlimited: Bool, balance: String? = nil) {
        self.hasCredits = hasCredits; self.unlimited = unlimited; self.balance = balance
    }
}

public struct CodexUsageSpendLimit: Sendable, Equatable {
    public let limit: String
    public let used: String
    public let remainingPercent: Double
    public let resetsAt: Date

    public init(limit: String, used: String, remainingPercent: Double, resetsAt: Date) {
        self.limit = limit; self.used = used; self.remainingPercent = remainingPercent; self.resetsAt = resetsAt
    }
}

public struct CodexUsageBucket: Sendable, Equatable, Identifiable {
    /// A metered limit ID, independent of the primary/secondary positions inside it.
    public let id: String
    public let name: String?
    public let normalModelSlug: String?
    public let primary: CodexUsageWindow?
    public let secondary: CodexUsageWindow?
    public let credits: CodexUsageCredits?
    public let individualLimit: CodexUsageSpendLimit?
    public let planType: String?
    public let spendControlReached: Bool?
    public let rateLimitReachedType: String?

    public init(id: String, name: String? = nil, normalModelSlug: String? = nil,
                primary: CodexUsageWindow? = nil, secondary: CodexUsageWindow? = nil,
                credits: CodexUsageCredits? = nil, individualLimit: CodexUsageSpendLimit? = nil,
                planType: String? = nil, spendControlReached: Bool? = nil, rateLimitReachedType: String? = nil) {
        self.id = id; self.name = name; self.normalModelSlug = normalModelSlug
        self.primary = primary; self.secondary = secondary; self.credits = credits
        self.individualLimit = individualLimit; self.planType = planType
        self.spendControlReached = spendControlReached; self.rateLimitReachedType = rateLimitReachedType
    }
}

public struct CodexUsageSnapshot: Sendable, Equatable {
    public let buckets: [CodexUsageBucket]
    /// Only a fresh backend read can establish this permission. A reset timer cannot.
    public let ordinaryUsageAllowed: Bool?
    public let accountID: String?

    public init(buckets: [CodexUsageBucket], ordinaryUsageAllowed: Bool? = nil, accountID: String? = nil) {
        self.buckets = buckets; self.ordinaryUsageAllowed = ordinaryUsageAllowed; self.accountID = accountID
    }

    fileprivate var withoutAuthorization: Self { .init(buckets: buckets, accountID: accountID) }
}

public enum CodexAccountUsage: Sendable, Equatable {
    case available(CodexUsageSnapshot)
    case unsupported
    /// A temporary read failure is not evidence that this account cannot report usage.
    case probeFailed(previous: CodexUsageSnapshot?)

    public var snapshot: CodexUsageSnapshot? {
        switch self {
        case .available(let snapshot): snapshot
        case .probeFailed(let previous): previous
        case .unsupported: nil
        }
    }
    public var isStale: Bool { if case .probeFailed = self { true } else { false } }
    public var buckets: [CodexUsageBucket] { snapshot?.buckets ?? [] }
}

public struct CodexAccountSnapshot: Sendable, Equatable {
    public let identity: CodexAccountIdentity
    public let usage: CodexAccountUsage
    public let checkedAt: Date

    public init(identity: CodexAccountIdentity, usage: CodexAccountUsage, checkedAt: Date = Date()) {
        self.identity = identity; self.usage = usage; self.checkedAt = checkedAt
    }

    /// Never carry one account's bars into another account or claim stale authorization.
    public func preservingLastGoodUsage(from previous: Self?) -> Self {
        guard case .probeFailed = usage else { return self }
        let retained: CodexUsageSnapshot?
        if identity.kind == .chatgpt, let previous, previous.identity == identity,
           let snapshot = previous.usage.snapshot,
           identity.accountID == nil || snapshot.accountID == nil || identity.accountID == snapshot.accountID {
            retained = snapshot.withoutAuthorization
        } else { retained = nil }
        return .init(identity: identity, usage: .probeFailed(previous: retained), checkedAt: checkedAt)
    }
}

/// An invalidation hint, not a complete identity or proof that sign-in changed successfully.
public struct CodexAccountChange: Sendable, Equatable {
    public let authMode: String?
    public let planType: String?
    public init(authMode: String? = nil, planType: String? = nil) {
        self.authMode = authMode; self.planType = planType
    }
}

public struct CodexUsageBucketUpdate: Sendable, Equatable {
    public let bucket: CodexUsageBucket
    fileprivate let fields: Set<String>
    fileprivate let windowFields: [String: Set<String>]
}

public enum CodexAccountNotification: Sendable, Equatable {
    case accountChanged(CodexAccountChange)
    case rateLimitsUpdated(CodexUsageBucketUpdate)
}

/// Parses only display/correlation fields from the installed app-server account contracts.
/// Unknown fields are bounded and discarded, including workspace origins, upsell payloads,
/// reset-credit details and any future credential-bearing values.
public enum CodexAccountParser {
    public static let failureMessage = "The Codex account response could not be read safely. Refresh and try again."
    public static let maximumBuckets = 64
    public static let maximumPayloadBytes = 1_048_576

    public static func account(_ value: JSONValue) throws -> CodexAccountIdentity {
        try bound(value)
        let object = try requiredObject(value)
        guard let rawAccount = object["account"], let rawRequires = object["requiresOpenaiAuth"],
              case .bool(let requires) = rawRequires else { throw failure() }
        var accountID: String?
        if let routing = object["workspaceRouting"], routing != .null {
            accountID = try optionalString(requiredObject(routing)["chatgptAccountId"], maximum: 4_096)
        }
        if rawAccount == .null { return .init(kind: .signedOut, requiresOpenAIAuth: requires) }
        let fields = try requiredObject(rawAccount)
        guard let type = try optionalString(fields["type"], maximum: 256) else { throw failure() }
        switch type {
        case "apiKey": return .init(kind: .apiKey, requiresOpenAIAuth: requires)
        case "chatgpt":
            return .init(kind: .chatgpt, requiresOpenAIAuth: requires,
                email: try optionalString(fields["email"], maximum: 1_024),
                planType: try optionalString(fields["planType"], maximum: 256), accountID: accountID)
        case "amazonBedrock":
            // Older/newer peers differ in credential-source metadata; retain neither form.
            if let managed = fields["usesCodexManagedCredentials"], managed != .null { _ = try requiredBool(managed) }
            return .init(kind: .amazonBedrock, requiresOpenAIAuth: requires)
        default: return .init(kind: .unknown(type), requiresOpenAIAuth: requires)
        }
    }

    public static func usage(_ value: JSONValue) throws -> CodexUsageSnapshot {
        try bound(value)
        let object = try requiredObject(value)
        var buckets: [String: CodexUsageBucket] = [:]
        if let legacy = object["rateLimits"], legacy != .null {
            let decoded = try bucket(legacy, fallbackID: "codex"); buckets[decoded.id] = decoded
        }
        if let mapped = object["rateLimitsByLimitId"], mapped != .null {
            let rows = try requiredObject(mapped)
            guard rows.count <= maximumBuckets else { throw failure() }
            for (id, raw) in rows {
                _ = try requiredString(.string(id), maximum: 256)
                let decoded = try bucket(raw, fallbackID: id)
                guard decoded.id == id else { throw failure() }
                buckets[id] = decoded
            }
        }
        guard !buckets.isEmpty, buckets.count <= maximumBuckets else { throw failure() }
        return .init(buckets: buckets.values.sorted { $0.id < $1.id },
            ordinaryUsageAllowed: try optionalBool(object["ordinaryUsageAllowed"]),
            accountID: try optionalString(object["accountId"], maximum: 4_096))
    }

    public static func notification(method: String, params: JSONValue) throws -> CodexAccountNotification? {
        guard method == "account/updated" || method == "account/rateLimits/updated" else { return nil }
        try bound(params)
        let object = try requiredObject(params)
        if method == "account/updated" {
            return .accountChanged(.init(authMode: try optionalString(object["authMode"], maximum: 256),
                                        planType: try optionalString(object["planType"], maximum: 256)))
        }
        guard let raw = object["rateLimits"] else { throw failure() }
        let fields = try requiredObject(raw)
        var windowFields: [String: Set<String>] = [:]
        for key in ["primary", "secondary"] {
            if let nested = fields[key]?.object { windowFields[key] = Set(nested.keys) }
        }
        return .rateLimitsUpdated(.init(bucket: try bucket(raw, fallbackID: "codex"), fields: Set(fields.keys), windowFields: windowFields))
    }

    public static func merging(_ update: CodexUsageBucketUpdate, into previous: CodexUsageSnapshot) throws -> CodexUsageSnapshot {
        let changed = update.bucket
        var buckets = previous.buckets
        guard buckets.count <= maximumBuckets, Set(buckets.map(\.id)).count == buckets.count else { throw failure() }
        if let index = buckets.firstIndex(where: { $0.id == changed.id }) {
            let old = buckets[index]
            buckets[index] = .init(id: old.id, name: changed.name ?? old.name,
                normalModelSlug: changed.normalModelSlug ?? old.normalModelSlug,
                primary: mergedWindow("primary", update: update, old: old.primary, changed: changed.primary),
                secondary: mergedWindow("secondary", update: update, old: old.secondary, changed: changed.secondary),
                credits: changed.credits ?? old.credits,
                individualLimit: update.fields.contains("individualLimit") ? changed.individualLimit : old.individualLimit,
                planType: changed.planType ?? old.planType,
                spendControlReached: changed.spendControlReached ?? old.spendControlReached,
                rateLimitReachedType: changed.rateLimitReachedType ?? old.rateLimitReachedType)
        } else { buckets.append(changed) }
        guard buckets.count <= maximumBuckets else { throw failure() }
        // Notifications are sparse observations, not fresh ordinaryUsageAllowed evidence.
        return .init(buckets: buckets.sorted { $0.id < $1.id }, accountID: previous.accountID)
    }

    private static func mergedWindow(_ key: String, update: CodexUsageBucketUpdate,
                                     old: CodexUsageWindow?, changed: CodexUsageWindow?) -> CodexUsageWindow? {
        guard update.fields.contains(key) else { return old }
        guard let changed else { return nil }
        guard let old else { return changed }
        let fields = update.windowFields[key] ?? []
        let changedDuration = fields.contains("windowDurationMins") && changed.windowDurationMinutes != old.windowDurationMinutes
        return .init(usedPercent: changed.usedPercent,
                     windowDurationMinutes: fields.contains("windowDurationMins") ? changed.windowDurationMinutes : old.windowDurationMinutes,
                     resetsAt: fields.contains("resetsAt") ? changed.resetsAt : (changedDuration ? nil : old.resetsAt))
    }

    private static func bucket(_ value: JSONValue, fallbackID: String) throws -> CodexUsageBucket {
        let object = try requiredObject(value)
        return .init(id: try optionalString(object["limitId"], maximum: 256) ?? fallbackID,
            name: try optionalString(object["limitName"], maximum: 1_024),
            normalModelSlug: try optionalString(object["normalModelSlug"], maximum: 4_096),
            primary: try window(object["primary"]), secondary: try window(object["secondary"]),
            credits: try credits(object["credits"]), individualLimit: try spendLimit(object["individualLimit"]),
            planType: try optionalString(object["planType"], maximum: 256),
            spendControlReached: try optionalBool(object["spendControlReached"]),
            rateLimitReachedType: try optionalString(object["rateLimitReachedType"], maximum: 256))
    }

    private static func window(_ value: JSONValue?) throws -> CodexUsageWindow? {
        guard let value, value != .null else { return nil }
        let object = try requiredObject(value)
        let duration: Int?
        if let raw = object["windowDurationMins"], raw != .null {
            let number = try finiteNumber(raw)
            guard number >= 0, number <= Double(Int32.max), number.rounded(.towardZero) == number else { throw failure() }
            duration = Int(number)
        } else { duration = nil }
        return .init(usedPercent: try percent(object["usedPercent"]), windowDurationMinutes: duration,
                     resetsAt: try date(object["resetsAt"]))
    }

    private static func credits(_ value: JSONValue?) throws -> CodexUsageCredits? {
        guard let value, value != .null else { return nil }
        let object = try requiredObject(value)
        return .init(hasCredits: try requiredBool(object["hasCredits"]), unlimited: try requiredBool(object["unlimited"]),
                     balance: try optionalString(object["balance"], maximum: 256, allowsEmpty: true))
    }

    private static func spendLimit(_ value: JSONValue?) throws -> CodexUsageSpendLimit? {
        guard let value, value != .null else { return nil }
        let object = try requiredObject(value)
        guard let reset = try date(object["resetsAt"]) else { throw failure() }
        return .init(limit: try requiredString(object["limit"], maximum: 256, allowsEmpty: true),
                     used: try requiredString(object["used"], maximum: 256, allowsEmpty: true),
                     remainingPercent: try percent(object["remainingPercent"]), resetsAt: reset)
    }

    private static func failure() -> CoincideError { CoincideError(failureMessage) }
    private static func requiredObject(_ value: JSONValue) throws -> [String: JSONValue] {
        guard let result = value.object else { throw failure() }; return result
    }
    private static func optionalString(_ value: JSONValue?, maximum: Int, allowsEmpty: Bool = false) throws -> String? {
        guard let value, value != .null else { return nil }
        return try requiredString(value, maximum: maximum, allowsEmpty: allowsEmpty)
    }
    private static func requiredString(_ value: JSONValue?, maximum: Int, allowsEmpty: Bool = false) throws -> String {
        guard let value, case .string(let result) = value, result.utf8.count <= maximum,
              (allowsEmpty || !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              !result.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw failure() }
        return result
    }
    private static func optionalBool(_ value: JSONValue?) throws -> Bool? {
        guard let value, value != .null else { return nil }; return try requiredBool(value)
    }
    private static func requiredBool(_ value: JSONValue?) throws -> Bool {
        guard let value, case .bool(let result) = value else { throw failure() }; return result
    }
    private static func finiteNumber(_ value: JSONValue?) throws -> Double {
        guard let value, case .number(let number) = value, number.isFinite else { throw failure() }; return number
    }
    private static func percent(_ value: JSONValue?) throws -> Double { min(100, max(0, try finiteNumber(value))) }
    private static func date(_ value: JSONValue?) throws -> Date? {
        guard let value, value != .null else { return nil }
        let seconds = try finiteNumber(value)
        guard seconds >= 0, seconds <= 253_402_300_799 else { throw failure() }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func bound(_ value: JSONValue) throws {
        // Iterative bounds avoid re-encoding unknown credential/upsell fields or recursively
        // walking an unbounded response. Wire frame bounds remain the transport's job.
        var stack: [(JSONValue, Int)] = [(value, 0)], bytes = 0, nodes = 0
        while let (next, depth) = stack.popLast() {
            nodes += 1
            guard nodes <= 16_384, depth <= 32 else { throw failure() }
            switch next {
            case .string(let text): bytes += text.utf8.count
            case .object(let fields):
                guard fields.count <= 4_096 else { throw failure() }
                guard stack.count + fields.count <= 16_384 - nodes else { throw failure() }
                for (key, child) in fields { bytes += key.utf8.count; stack.append((child, depth + 1)) }
            case .array(let children):
                guard children.count <= 4_096 else { throw failure() }
                guard stack.count + children.count <= 16_384 - nodes else { throw failure() }
                for child in children { stack.append((child, depth + 1)) }
            case .number(let number): guard number.isFinite else { throw failure() }
            case .bool, .null: break
            }
            guard bytes <= maximumPayloadBytes else { throw failure() }
        }
    }
}
