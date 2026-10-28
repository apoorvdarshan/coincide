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
}
