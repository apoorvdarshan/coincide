import Foundation
import Testing
import CoincideCore
@testable import Coincide

@Test @MainActor func localCompactionFailureReturnsSafeStatusInspectionWithoutProviderErrorDetails() async throws {
    let result = try await LocalAppControl.localActionResult("compact") {
        throw CoincideError("SYNTHETIC_PRIVATE_ERROR_CANARY")
    }
    #expect(result.isError)
    #expect(result.structuredContent?["error"]["code"] == .string("context_compaction_not_confirmed"))
    #expect(result.content.first?.contains("Run compaction for the same conversation") == true)
    #expect(!result.content.joined().contains("SYNTHETIC_PRIVATE_ERROR_CANARY"))
}

@Test @MainActor func localConfigurationExpiredReviewReturnsActionableToolError() async throws {
    let result = try await LocalAppControl.localActionResult("configuration-set") {
        throw CoincideError("Read configuration first and use its unexpired review ID for one change.")
    }
    #expect(result.isError)
    #expect(result.structuredContent?["error"]["code"] == .string("configuration_review_required"))
    #expect(result.content.first?.contains("Read configuration again for the same provider and scope") == true)
    #expect(result.content.first?.contains("single-use") == true)
}

@Test @MainActor func localConfigurationStaleAndInvalidSavesPreserveSourceAndReturnSafeRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-control-errors-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("settings.json"), editor = ProviderConfigurationEditor()
    try Data("{\"autoCompactWindow\":200000}".utf8).write(to: source)
    let document = try await editor.load(provider: .claude, scope: .user, sourceURL: source)
    let external = Data("{\"autoCompactWindow\":300000}".utf8)
    try external.write(to: source)
    let stale = try await LocalAppControl.localActionResult("configuration-set") {
        _ = try await editor.save(document, changes: ["autoCompactWindow": "400000"])
        return .init(content: [])
    }
    #expect(stale.isError && stale.structuredContent?["error"]["code"] == .string("configuration_changed"))
    #expect(try Data(contentsOf: source) == external)
    let current = try await editor.load(provider: .claude, scope: .user, sourceURL: source)
    let invalid = try await LocalAppControl.localActionResult("configuration-set") {
        _ = try await editor.save(current, changes: ["autoCompactWindow": "99"])
        return .init(content: [])
    }
    #expect(invalid.isError && invalid.structuredContent?["error"]["code"] == .string("configuration_invalid"))
    #expect(invalid.content.first?.contains("100000 to 1000000") == true)
    #expect(try Data(contentsOf: source) == external)
}

@Test @MainActor func localConfigurationUnknownErrorsAreNeverConvertedToPublicDescriptions() async {
    let secret = "SYNTHETIC_PRIVATE_ERROR_CANARY"
    let errors: [any Error] = [CoincideError("Choose a supported setting value. " + secret), NSError(domain: secret, code: 7)]
    for error in errors {
        do {
            _ = try await LocalAppControl.localActionResult("configuration-set") { throw error }
            Issue.record("An unknown configuration error escaped the safe error boundary as a tool result.")
        } catch { /* The HTTP transport maps unknown errors to its generic internal failure. */ }
    }
    do {
        _ = try await LocalAppControl.localActionResult("status") {
            throw CoincideError("Choose a supported setting value.")
        }
        Issue.record("An unrelated tool used the configuration error contract.")
    } catch { }
}

@Test @MainActor func localIntegrationFailuresGiveRecoveryWithoutRawErrorsAndPreserveCancellation() async throws {
    for action in ["integrations", "integration-import", "integration-remove", "integration-use"] {
        let result = try await LocalAppControl.localActionResult(action) {
            throw NSError(domain: "SYNTHETIC_PRIVATE_ERROR_CANARY", code: 7)
        }
        #expect(result.isError && result.structuredContent?["error"]["code"] == .string("integration_refresh_required"))
        #expect(result.content.first?.contains("Refresh integrations") == true)
        #expect(!result.content.joined().contains("SYNTHETIC_PRIVATE_ERROR_CANARY"))
    }
    do {
        _ = try await LocalAppControl.localActionResult("configuration-set") { throw CancellationError() }
        Issue.record("Cancellation became a configuration error.")
    } catch let error as MCPError { #expect(error.kind == .cancelled) }
    do {
        _ = try await LocalAppControl.localActionResult("integration-import") { throw MCPError(.invalidParams) }
        Issue.record("Malformed parameters became a retryable integration error.")
    } catch let error as MCPError { #expect(error.kind == .invalidParams) }
    let success = MCPToolResult(content: [], structuredContent: .object(["saved": .bool(true)]))
    let unchanged = try await LocalAppControl.localActionResult("configuration-set") { success }
    #expect(unchanged == success)
}
