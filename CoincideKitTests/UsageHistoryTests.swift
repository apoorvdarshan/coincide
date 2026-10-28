import Foundation
import Testing
@testable import CoincideKit

@MainActor
struct UsageHistoryTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-tests-\(UUID())")

    private func record(provider: ProviderKind = .claude, project: UUID = UUID(), at: Date = Date()) -> UsageRecord {
        UsageRecord(id: UUID(), threadID: UUID(), projectID: project, provider: provider, modelID: "model",
            startedAt: at.addingTimeInterval(-10), finishedAt: at, outcome: .completed,
            usage: TokenUsage(inputTokens: 123, costUSD: 0.2))
    }

    @Test func persistenceDeduplicatesTurnsAndFiltersWithoutAddingSnapshots() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = UsageHistory(directory: directory)
        let now = Date()
        let first = record(at: now.addingTimeInterval(-60))
        let second = record(provider: .codex, project: first.projectID, at: now)
        history.record(first)
        history.record(first)
        history.record(second)
        history.flush()
        let reopened = UsageHistory(directory: directory)
        #expect(reopened.records.map(\.id) == [first.id, second.id])
        #expect(reopened.filtered(since: now.addingTimeInterval(-30)).map(\.id) == [second.id])
        #expect(reopened.filtered(since: .distantPast, provider: .claude).map(\.id) == [first.id])
        #expect(reopened.filtered(since: .distantPast, projectID: UUID()).isEmpty)
        #expect(reopened.records.allSatisfy { $0.usage.costUSD == 0.2 })
    }

    @Test func invalidMetricsAreMissingAndBackwardClockDoesNotProduceNegativeDuration() {
        let now = Date()
        let value = UsageRecord(id: UUID(), threadID: UUID(), projectID: UUID(), provider: .claude, modelID: nil,
            startedAt: now, finishedAt: now.addingTimeInterval(-30), outcome: .failed,
            usage: TokenUsage(inputTokens: -1, outputTokens: 0, costUSD: .infinity))
        #expect(value.duration == 0)
        #expect(value.usage.inputTokens == nil && value.usage.costUSD == nil)
        #expect(value.usage.outputTokens == 0)
    }

    @Test func corruptHistoryIsPreservedBeforeRecordingAgain() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("{not readable".utf8)
        try original.write(to: directory.appendingPathComponent("usage-history.json"))
        let history = UsageHistory(directory: directory)
        history.record(record())
        history.flush()
        #expect(UsageHistory(directory: directory).records.count == 1)
        let backup = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains("unreadable-") })
        #expect(try Data(contentsOf: backup) == original)
    }

    @Test func transientWriteFailureRetainsLaterRecordsAndClearsAfterRetry() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = UsageHistory(directory: directory)
        let file = directory.appendingPathComponent("usage-history.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let first = record(), second = record()
        history.record(first)
        history.flush()
        try await waitForError(history, present: true)
        #expect(history.records.map(\.id) == [first.id])

        try FileManager.default.removeItem(at: file)
        history.record(second)
        history.flush()
        try await waitForError(history, present: false)
        #expect(history.records.map(\.id) == [first.id, second.id])
        #expect(UsageHistory(directory: directory).records.map(\.id) == [first.id, second.id])
    }

    @Test func failedPreservationStillBlocksReplacingAnUnreadableOriginal() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("usage-history.json")
        let original = Data("{not readable".utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let history = UsageHistory(directory: directory)
        try #require(history.error != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        history.record(record())
        history.flush()
        #expect(history.records.isEmpty)
        #expect(history.error != nil)
        #expect(try Data(contentsOf: file) == original)
    }

    private func waitForError(_ history: UsageHistory, present: Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while (history.error != nil) != present && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require((history.error != nil) == present)
    }
}
