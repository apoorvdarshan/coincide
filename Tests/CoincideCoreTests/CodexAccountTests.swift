import Foundation
import Testing
@testable import CoincideCore

private func accountPayload(_ account: JSONValue, requires: Bool = true, accountID: String? = nil) -> JSONValue {
    var result: [String: JSONValue] = ["account": account, "requiresOpenaiAuth": .bool(requires)]
    if let accountID {
        result["workspaceRouting"] = .object(["chatgptAccountId": .string(accountID),
            "backendOrigin": .string("https://synthetic.invalid"), "futureCredential": .string("synthetic-private-token")])
    }
    return .object(result)
}

private func accountWindow(_ used: Double = 25, duration: Int = 300, reset: Double = 2_000_000_000) -> JSONValue {
    .object(["usedPercent": .number(used), "windowDurationMins": .number(Double(duration)), "resetsAt": .number(reset)])
}

private func accountUsage(_ buckets: [String: JSONValue], ordinaryAllowed: Bool? = true) -> JSONValue {
    .object(["rateLimitsByLimitId": .object(buckets), "ordinaryUsageAllowed": ordinaryAllowed.map(JSONValue.bool) ?? .null,
             "accountId": .string("synthetic-account")])
}

private func accountUpdate(_ fields: [String: JSONValue]) throws -> CodexUsageBucketUpdate {
    let result = try CodexAccountParser.notification(method: "account/rateLimits/updated", params: .object(["rateLimits": .object(fields)]))
    guard let result, case .rateLimitsUpdated(let update) = result else { throw CoincideError("The synthetic usage update was not decoded.") }
    return update
}

private func accountParserRejects(_ body: () throws -> Void) {
    do { try body(); Issue.record("An invalid synthetic account response was accepted.") }
    catch {
        #expect(error.localizedDescription == CodexAccountParser.failureMessage)
        #expect(!error.localizedDescription.contains("synthetic-private-token"))
    }
}

@Test(arguments: ["signed-out", "no-auth-required", "api-key", "chatgpt", "bedrock", "bedrock-new", "future"])
func codexAccountIdentityKeepsAuthModesDistinctWithoutRetainingRoutingOrCredentials(_ mode: String) throws {
    let raw: JSONValue
    let expected: CodexAccountIdentity
    switch mode {
    case "signed-out", "no-auth-required":
        raw = .null; expected = .init(kind: .signedOut, requiresOpenAIAuth: mode == "signed-out")
    case "api-key":
        raw = .object(["type": .string("apiKey"), "apiKey": .string("synthetic-private-token")])
        expected = .init(kind: .apiKey, requiresOpenAIAuth: true)
    case "chatgpt":
        raw = .object(["type": .string("chatgpt"), "email": .string("synthetic@example.invalid"), "planType": .string("future-plan")])
        expected = .init(kind: .chatgpt, requiresOpenAIAuth: true, email: "synthetic@example.invalid", planType: "future-plan", accountID: "synthetic-account")
    case "bedrock", "bedrock-new":
        raw = .object(["type": .string("amazonBedrock"), mode == "bedrock" ? "usesCodexManagedCredentials" : "credentialSource":
            mode == "bedrock" ? .bool(true) : .string("environment"), "secretAccessKey": .string("synthetic-private-token")])
        expected = .init(kind: .amazonBedrock, requiresOpenAIAuth: true)
    default:
        raw = .object(["type": .string("future-auth"), "accessToken": .string("synthetic-private-token")])
        expected = .init(kind: .unknown("future-auth"), requiresOpenAIAuth: true)
    }
    let decoded = try CodexAccountParser.account(accountPayload(raw, requires: mode != "no-auth-required", accountID: "synthetic-account"))
    #expect(decoded == expected)
}

@Test func codexAccountAcceptsLegacyOptionalIdentityAndDoesNotInferMissingEmailOrPlan() throws {
    let result = try CodexAccountParser.account(accountPayload(.object(["type": .string("chatgpt"), "email": .null, "planType": .null])))
    #expect(result == .init(kind: .chatgpt, requiresOpenAIAuth: true))
    #expect(try CodexAccountParser.account(accountPayload(.object(["type": .string("chatgpt")]))) == result)
}

@Test func codexAccountUsagePrefersNamedBucketsOverLegacyAndKeepsModelSpecificQuotaSeparate() throws {
    let raw: JSONValue = .object([
        "rateLimits": .object(["limitId": .string("codex"), "primary": accountWindow(99)]),
        "rateLimitsByLimitId": .object([
            "spark": .object(["limitId": .string("spark"), "limitName": .string("Spark quota"), "primary": accountWindow(80)]),
            "codex": .object(["limitId": .string("codex"), "primary": accountWindow(15), "secondary": accountWindow(45, duration: 10_080)])]),
        "ordinaryUsageAllowed": .bool(false), "accountId": .string("synthetic-account"),
        "rateLimitUpsell": .object(["unsafeURL": .string("https://synthetic.invalid/?credential=synthetic-private-token")]),
        "rateLimitResetCredits": .object(["availableCount": .number(3), "privateDetails": .string("synthetic-private-token")])])
    let result = try CodexAccountParser.usage(raw)
    #expect(result.buckets.map(\.id) == ["codex", "spark"])
    #expect(result.buckets[0].primary?.usedPercent == 15)
    #expect(result.buckets[1].primary?.usedPercent == 80)
    #expect(result.buckets[0].secondary?.windowDurationMinutes == 10_080)
    #expect(result.ordinaryUsageAllowed == false)
    #expect(result.accountID == "synthetic-account")
}

@Test func codexAccountLegacyQuotaKeepsUnknownDurationAndPermissionUnspecified() throws {
    let result = try CodexAccountParser.usage(.object(["rateLimits": .object([
        "primary": .object(["usedPercent": .number(20)]), "planType": .string("future-plan")])]))
    #expect(result.buckets.count == 1)
    #expect(result.buckets[0].id == "codex")
    #expect(result.buckets[0].primary == .init(usedPercent: 20))
    #expect(result.buckets[0].secondary == nil)
    #expect(result.ordinaryUsageAllowed == nil)
}

@Test func codexAccountQuotaPreservesOpaqueCreditsAndSpendControlWithoutCurrencyOrRecoveryGuess() throws {
    let result = try CodexAccountParser.usage(accountUsage(["codex": .object([
        "primary": accountWindow(125), "secondary": accountWindow(-5),
        "credits": .object(["hasCredits": .bool(true), "unlimited": .bool(false), "balance": .string("0.000125")]),
        "individualLimit": .object(["limit": .string("25.00"), "used": .string("12.50"), "remainingPercent": .number(50), "resetsAt": .number(2_000_000_000)]),
        "spendControlReached": .bool(true), "rateLimitReachedType": .string("future-limit-type")])], ordinaryAllowed: false))
    let bucket = try #require(result.buckets.first)
    #expect(bucket.primary?.usedPercent == 100)
    #expect(bucket.secondary?.usedPercent == 0)
    #expect(bucket.credits == .init(hasCredits: true, unlimited: false, balance: "0.000125"))
    #expect(bucket.individualLimit == .init(limit: "25.00", used: "12.50", remainingPercent: 50, resetsAt: Date(timeIntervalSince1970: 2_000_000_000)))
    #expect(bucket.spendControlReached == true)
    #expect(bucket.rateLimitReachedType == "future-limit-type")
    #expect(result.ordinaryUsageAllowed == false)
}

@Test func codexAccountSparseUpdatePreservesMissingWindowMetadataAndOtherQuotaBuckets() throws {
    let previous = try CodexAccountParser.usage(accountUsage([
        "codex": .object(["primary": accountWindow(25), "secondary": accountWindow(40, duration: 10_080), "planType": .string("pro")]),
        "spark": .object(["primary": accountWindow(70)])]))
    let update = try accountUpdate(["primary": .object(["usedPercent": .number(30)])])
    let merged = try CodexAccountParser.merging(update, into: previous)
    #expect(merged.buckets[0].primary == .init(usedPercent: 30, windowDurationMinutes: 300, resetsAt: Date(timeIntervalSince1970: 2_000_000_000)))
    #expect(merged.buckets[0].secondary == previous.buckets[0].secondary)
    #expect(merged.buckets[1] == previous.buckets[1])
    #expect(merged.buckets[0].planType == "pro")
    #expect(merged.ordinaryUsageAllowed == nil)
    #expect(merged.accountID == previous.accountID)
    let differentInterval = try CodexAccountParser.merging(accountUpdate(["primary": .object([
        "usedPercent": .number(1), "windowDurationMins": .number(60)])]), into: previous)
    #expect(differentInterval.buckets[0].primary == .init(usedPercent: 1, windowDurationMinutes: 60))
    let spark = try CodexAccountParser.merging(accountUpdate(["limitId": .string("spark"), "primary": accountWindow(75)]), into: merged)
    #expect(spark.buckets[0] == merged.buckets[0])
    #expect(spark.buckets[1].primary?.usedPercent == 75)
}

@Test func codexAccountExplicitWindowNullClearsWhileUnavailableAccountMetadataDoesNotEraseKnownValues() throws {
    let previous = try CodexAccountParser.usage(accountUsage(["codex": .object([
        "primary": accountWindow(), "secondary": accountWindow(10), "planType": .string("pro"), "limitName": .string("Codex quota"),
        "credits": .object(["hasCredits": .bool(true), "unlimited": .bool(true)]), "spendControlReached": .bool(true),
        "individualLimit": .object(["limit": .string("100"), "used": .string("20"), "remainingPercent": .number(80), "resetsAt": .number(2_000_000_000)])])]))
    let update = try accountUpdate(["primary": .null, "individualLimit": .null, "planType": .null,
                                   "limitName": .null, "credits": .null, "spendControlReached": .null])
    let result = try CodexAccountParser.merging(update, into: previous)
    #expect(result.buckets[0].primary == nil)
    #expect(result.buckets[0].individualLimit == nil)
    #expect(result.buckets[0].secondary == previous.buckets[0].secondary)
    #expect(result.buckets[0].name == "Codex quota")
    #expect(result.buckets[0].planType == "pro")
    #expect(result.buckets[0].credits == previous.buckets[0].credits)
    #expect(result.buckets[0].spendControlReached == true)
    let nested = try CodexAccountParser.merging(accountUpdate(["secondary": .object([
        "usedPercent": .number(11), "resetsAt": .null, "windowDurationMins": .null])]), into: result)
    #expect(nested.buckets[0].secondary == .init(usedPercent: 11))
}

@Test func codexAccountRepeatedSparseNotificationsMergeByStableBucketIDWithoutDuplicatingRows() throws {
    var result = try CodexAccountParser.usage(.object(["rateLimits": .object([:])]))
    for percentage in 1...5 {
        result = try CodexAccountParser.merging(accountUpdate(["limitId": .string("spark"), "primary": accountWindow(Double(percentage))]), into: result)
    }
    #expect(result.buckets.map(\.id) == ["codex", "spark"])
    #expect(result.buckets[0].primary == nil)
    #expect(result.buckets[1].primary?.usedPercent == 5)
}

@Test func codexAccountFailureRetainsOnlySameAccountBarsAndNeverStalePermission() throws {
    let identity = CodexAccountIdentity(kind: .chatgpt, requiresOpenAIAuth: true, email: "synthetic@example.invalid", planType: "pro", accountID: "synthetic-account")
    let usage = try CodexAccountParser.usage(accountUsage(["codex": .object(["primary": accountWindow()])]))
    let previous = CodexAccountSnapshot(identity: identity, usage: .available(usage), checkedAt: Date(timeIntervalSince1970: 10))
    let failure = CodexAccountSnapshot(identity: identity, usage: .probeFailed(previous: nil), checkedAt: Date(timeIntervalSince1970: 20))
    let retained = failure.preservingLastGoodUsage(from: previous)
    #expect(retained.usage.isStale)
    #expect(retained.usage.buckets == previous.usage.buckets)
    #expect(retained.usage.snapshot?.ordinaryUsageAllowed == nil)
    #expect(retained.checkedAt == failure.checkedAt)
    #expect(failure.preservingLastGoodUsage(from: retained).usage.buckets == usage.buckets)
    let foreignUsage = CodexUsageSnapshot(buckets: usage.buckets, accountID: "foreign-account")
    let inconsistent = CodexAccountSnapshot(identity: identity, usage: .available(foreignUsage))
    #expect(failure.preservingLastGoodUsage(from: inconsistent).usage.snapshot == nil)
    let variants: [CodexAccountIdentity] = [
        .init(kind: .chatgpt, requiresOpenAIAuth: true, email: "different@example.invalid", planType: "pro", accountID: "synthetic-account"),
        .init(kind: .chatgpt, requiresOpenAIAuth: true, email: identity.email, planType: "pro", accountID: "different-account"),
        .init(kind: .chatgpt, requiresOpenAIAuth: true, email: identity.email, planType: "future-plan", accountID: "synthetic-account"),
        .init(kind: .apiKey, requiresOpenAIAuth: true), .init(kind: .signedOut, requiresOpenAIAuth: false)]
    for changed in variants {
        let switched = CodexAccountSnapshot(identity: changed, usage: .probeFailed(previous: usage)).preservingLastGoodUsage(from: previous)
        #expect(switched.usage.snapshot == nil)
    }
    let unsupported = CodexAccountSnapshot(identity: identity, usage: .unsupported)
    #expect(unsupported.preservingLastGoodUsage(from: previous).usage == .unsupported)
    #expect(unsupported.usage.buckets.isEmpty)
    #expect(!unsupported.usage.isStale)
}

@Test func codexAccountChangeNotificationsAreHintsAndUnknownMethodsDoNotBecomeAccountChanges() throws {
    let change = try CodexAccountParser.notification(method: "account/updated", params: .object(["authMode": .string("future-auth"), "planType": .string("future-plan")]))
    #expect(change == .accountChanged(.init(authMode: "future-auth", planType: "future-plan")))
    #expect(try CodexAccountParser.notification(method: "account/updated", params: .object(["authMode": .null, "planType": .null])) == .accountChanged(.init()))
    #expect(try CodexAccountParser.notification(method: "turn/completed", params: .null) == nil)
}

@Test(arguments: ["missing-account", "missing-requires", "wrong-requires", "empty-type", "wrong-email", "wrong-bedrock", "wrong-routing", "control-type"])
func codexAccountMalformedIdentityFailsWithoutEchoingSensitiveFields(_ mode: String) {
    var payload = accountPayload(.object(["type": .string("chatgpt")])).object!
    switch mode {
    case "missing-account": payload.removeValue(forKey: "account")
    case "missing-requires": payload.removeValue(forKey: "requiresOpenaiAuth")
    case "wrong-requires": payload["requiresOpenaiAuth"] = .string("synthetic-private-token")
    case "empty-type": payload["account"] = .object(["type": .string("")])
    case "wrong-email": payload["account"] = .object(["type": .string("chatgpt"), "email": .number(1)])
    case "wrong-bedrock": payload["account"] = .object(["type": .string("amazonBedrock"), "usesCodexManagedCredentials": .string("synthetic-private-token")])
    case "wrong-routing": payload["workspaceRouting"] = .array([])
    default: payload["account"] = .object(["type": .string("future\nauth")])
    }
    accountParserRejects { _ = try CodexAccountParser.account(.object(payload)) }
}

@Test(arguments: ["no-buckets", "wrong-window", "missing-percent", "nan", "infinite", "fractional-duration", "negative-duration", "invalid-date", "wrong-credits", "wrong-allowed", "map-conflict", "empty-bucket"])
func codexAccountMalformedUsageFailsWithoutInventingQuotaOrAuthorization(_ mode: String) {
    var payload = accountUsage(["codex": .object(["primary": accountWindow()])]).object!
    switch mode {
    case "no-buckets": payload = [:]
    case "wrong-window": payload["rateLimitsByLimitId"] = .object(["codex": .object(["primary": .string("synthetic-private-token")])])
    case "missing-percent": payload["rateLimitsByLimitId"] = .object(["codex": .object(["primary": .object([:])])])
    case "nan", "infinite": payload["rateLimitsByLimitId"] = .object(["codex": .object(["primary": accountWindow(mode == "nan" ? .nan : .infinity)])])
    case "fractional-duration", "negative-duration": payload["rateLimitsByLimitId"] = .object(["codex": .object(["primary": .object(["usedPercent": .number(1), "windowDurationMins": .number(mode == "fractional-duration" ? 0.5 : -1)])])])
    case "invalid-date": payload["rateLimitsByLimitId"] = .object(["codex": .object(["primary": accountWindow(reset: -1)])])
    case "wrong-credits": payload["rateLimitsByLimitId"] = .object(["codex": .object(["credits": .object(["hasCredits": .bool(true), "unlimited": .string("synthetic-private-token")])])])
    case "wrong-allowed": payload["ordinaryUsageAllowed"] = .number(1)
    case "map-conflict": payload["rateLimitsByLimitId"] = .object(["codex": .object(["limitId": .string("spark")])])
    default: payload["rateLimitsByLimitId"] = .object(["": .object([:])])
    }
    accountParserRejects { _ = try CodexAccountParser.usage(.object(payload)) }
}

@Test(arguments: ["bytes", "depth", "nodes", "buckets", "merge-buckets"])
func codexAccountParserBoundsPayloadAndSparseBucketGrowth(_ mode: String) throws {
    if mode == "buckets" || mode == "merge-buckets" {
        var raw: [String: JSONValue] = [:]
        for index in 0..<CodexAccountParser.maximumBuckets { raw["limit-\(index)"] = .object([:]) }
        if mode == "buckets" {
            raw["one-too-many"] = .object([:])
            accountParserRejects { _ = try CodexAccountParser.usage(accountUsage(raw)) }
        } else {
            let old = try CodexAccountParser.usage(accountUsage(raw))
            accountParserRejects { _ = try CodexAccountParser.merging(accountUpdate(["limitId": .string("one-too-many")]), into: old) }
        }
    } else {
        var raw: JSONValue
        if mode == "bytes" { raw = .string(String(repeating: "x", count: CodexAccountParser.maximumPayloadBytes + 1)) }
        else if mode == "nodes" { raw = .array(Array(repeating: .array(Array(repeating: .null, count: 4_096)), count: 5)) }
        else { raw = .null; for _ in 0..<33 { raw = .object(["nested": raw]) } }
        accountParserRejects { _ = try CodexAccountParser.account(.object(["account": .null, "requiresOpenaiAuth": .bool(false), "future": raw])) }
    }
}
