import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private let providerUsageViewNow = Date(timeIntervalSince1970: 1_700_000_000)
private func providerUsageViewClaude(runID: UUID = UUID()) throws -> ClaudeUsageSnapshot {
    let model = try ClaudeModelUsage(model: "Native alias / " + String(repeating: "工作e\u{301}", count: 25),
        inputTokens: 9_007_199_254_740_000, outputTokens: 120, cacheReadInputTokens: 50, cacheCreationInputTokens: 20,
        webSearchRequests: 0, estimatedCostUSD: 0.000000001, contextWindow: 200_000, maxOutputTokens: 8_000,
        canonicalModel: "native-canonical-model", provider: "firstParty", costBasis: "managed")
    return try .init(runID: runID, revision: 2,
        context: .init(source: .nativeReport, model: "native-context-model", usedTokens: 500, maxTokens: 180_000, observedAt: providerUsageViewNow),
        turn: .init(usageStatus: .partial, inputTokens: 160, cachedInputTokens: 30, cacheCreationTokens: 20, outputTokens: 10, hasSubagents: true),
        session: .init(estimatedCostUSD: 0.12, models: [model], modelUsageAvailable: true, observedAt: providerUsageViewNow),
        rateLimits: [.init(window: .fiveHour, status: .rejected, utilization: 1.2, resetsAt: providerUsageViewNow.addingTimeInterval(600), overageStatus: .allowed)],
        status: .requesting, statusObserved: true,
        compaction: .init(trigger: .auto, beforeTokens: 180_000, afterTokens: 500, outcome: .success, observedAt: providerUsageViewNow),
        observedAt: providerUsageViewNow)
}

@Test @MainActor func providerUsagePresentationDistinguishesMissingFromReportedZeroAndSharesMainAgentCounters() throws {
    let locale = Locale(identifier: "en_US")
    let partial = try ClaudeUsageSnapshot(runID: UUID(), revision: 1,
        turn: .init(usageStatus: .partial, inputTokens: 1_234, outputTokens: 0), observedAt: providerUsageViewNow)
    let shown = ProviderUsagePresentation.mainAgent(.claude(partial), locale: locale)
    #expect(shown.status == "Partial")
    #expect(shown.rows.first(where: { $0.id == "input" })?.value == "1,234")
    #expect(shown.rows.first(where: { $0.id == "output" })?.value == "0")
    #expect(shown.rows.first(where: { $0.id == "reasoning" })?.value == "Not reported")
    #expect(shown.rows.first(where: { $0.id == "cache-read" })?.value == "Not reported")
    let claude = try ClaudeUsageSnapshot(runID: UUID(), revision: 1,
        turn: .init(usageStatus: .complete, inputTokens: 100, cachedInputTokens: 20, cacheCreationTokens: 30,
            outputTokens: 10, reasoningTokens: 2, hasSubagents: true), observedAt: providerUsageViewNow)
    let openCode = try OpenCodeTurnUsage(usageStatus: .complete, inputTokens: 100, cachedInputTokens: 20, cacheCreationTokens: 30,
        outputTokens: 10, reasoningTokens: 2, hasSubagents: true)
    let first = ProviderUsagePresentation.mainAgent(.claude(claude), locale: locale)
    let second = ProviderUsagePresentation.mainAgent(.openCode(openCode), locale: locale)
    #expect(first.rows.map(\.value) == second.rows.map(\.value) && first.status == "Complete" && second.status == "Complete")
    #expect(first.hasSubagents && second.hasSubagents)
    let unavailable = try OpenCodeTurnUsage(usageStatus: .unavailable)
    let missing = ProviderUsagePresentation.mainAgent(.openCode(unavailable), locale: locale)
    #expect(missing.status == "Unavailable" && missing.rows.allSatisfy { $0.value == "Not reported" })
}

@Test @MainActor func providerUsageFormattingPreservesReportedFractionsSmallUSDAndUnknownCapacity() {
    let english = Locale(identifier: "en_US"), german = Locale(identifier: "de_DE")
    #expect(ProviderUsageFormatting.count(1_234, locale: german) == "1.234")
    #expect(ProviderUsageFormatting.count(nil, locale: english) == "Not reported")
    #expect(ProviderUsageFormatting.currency(nil, locale: english) == "Not reported")
    #expect(ProviderUsageFormatting.currency(0.000000001, locale: english) != ProviderUsageFormatting.currency(0, locale: english))
    #expect(ProviderUsageFormatting.currency(0.12, locale: english).contains("0.12"))
    #expect(ProviderUsageFormatting.percent(1.2, locale: english) == "120%")
    #expect(ProviderUsageFormatting.percent(nil, locale: english) == "Not reported")
    #expect(ProviderUsagePresentation.status(nil) == "No active status reported")
    #expect(ProviderUsagePresentation.contextExplanation(.nativeReport).contains("compaction policy"))
    #expect(ProviderUsagePresentation.window(.sevenDayOverageIncluded) == "Weekly overage-included window")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func providerUsageViewsFitSmallOffscreenLightDarkWidthsAndRunHistoryKeepsOriginalRecords() throws {
    _ = NSApplication.shared
    let claudeRunID = UUID(), claude = try providerUsageViewClaude(runID: claudeRunID)
    let openCode = try OpenCodeTurnUsage(usageStatus: .complete, inputTokens: 100, cachedInputTokens: 20, cacheCreationTokens: 30,
        outputTokens: 10, reasoningTokens: 2, hasSubagents: true)
    let unavailable = try ClaudeUsageSnapshot(runID: UUID(), revision: 1, turn: .init(usageStatus: .unavailable), observedAt: providerUsageViewNow)
    var thread = CodingThread(project: .init(path: "/private/provider-usage-offscreen")); thread.provider = .claude
    thread.title = "Observed provider accounting"; thread.draft = "Unsent draft stays unchanged e\u{301}"
    var claudeRecord = ThreadRunRecord(run: .init(id: claudeRunID, configuration: .init(thread: thread), startedAt: providerUsageViewNow), origin: .legacy)
    claudeRecord.status = .completed; claudeRecord.endedAt = providerUsageViewNow; claudeRecord.endReason = .providerCompleted
    claudeRecord.providerUsage = .claude(claude)
    var secondConfiguration = ProviderConfiguration(thread: thread); secondConfiguration.provider = .opencode
    var openCodeRecord = ThreadRunRecord(run: .init(id: UUID(), configuration: secondConfiguration, startedAt: providerUsageViewNow), origin: .legacy)
    openCodeRecord.status = .completed; openCodeRecord.endedAt = providerUsageViewNow; openCodeRecord.endReason = .providerCompleted
    openCodeRecord.providerUsage = .openCode(openCode); thread.runHistory = [claudeRecord, openCodeRecord]
    let before = thread
    let model = try #require(claude.session?.models.first), session = try #require(claude.session), limit = try #require(claude.rateLimits.first)
    let contents: [AnyView] = [AnyView(ProviderUsageView(usage: .claude(claude))), AnyView(ProviderUsageView(usage: .openCode(openCode))),
        AnyView(ProviderUsageView(usage: .claude(unavailable))), AnyView(ClaudeUsageModelView(value: model)),
        AnyView(ClaudeUsageSessionView(value: session)), AnyView(ClaudeUsageLimitView(value: limit))]
    for scheme in [ColorScheme.light, .dark] {
        for width in [CGFloat(280), 320, 560] {
            for content in contents {
                let view = content.font(.caption).environment(\.locale, Locale(identifier: "en_US")).environment(\.colorScheme, scheme)
                let host = NSHostingController(rootView: view)
                let size = host.sizeThatFits(in: .init(width: width, height: 8_000))
                #expect(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 && size.width <= width + 1 && size.height < 8_000)
                host.view.frame = .init(origin: .zero, size: size); host.view.layoutSubtreeIfNeeded()
                #expect(host.view.window == nil)
                let viewport = NSHostingController(rootView: ScrollView { view }.frame(width: width, height: 560))
                let viewportSize = viewport.sizeThatFits(in: .init(width: width, height: 560))
                #expect(viewportSize.width <= width + 1 && viewportSize.height <= 561)
                #expect(viewport.view.window == nil)
            }
            if width >= 320 {
                let history = NSHostingController(rootView: RunHistoryContent(thread: thread).environment(\.colorScheme, scheme))
                let size = history.sizeThatFits(in: .init(width: width, height: 560))
                #expect(size.width <= width + 1 && size.height <= 600 && size.height > 0 && history.view.window == nil)
            }
        }
    }
    #expect(thread == before)
    #expect(RunHistoryPresentation.records(in: thread).compactMap(\.providerUsage).count == 2)
}
