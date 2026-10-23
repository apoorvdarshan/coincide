import CoincideCore
import SwiftUI

/// Observed accounting only. Rendering never queries a provider or changes a
/// conversation. Query-session totals must not be added across recorded runs.
struct ProviderUsageView: View {
    let usage: ProviderUsageUpdate
    var showMainAgent = true
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showMainAgent { ProviderMainAgentUsageView(value: ProviderUsagePresentation.mainAgent(usage, locale: locale)) }
            if case .claude(let snapshot) = usage { claude(snapshot) }
        }
        .font(.caption).textSelection(.enabled)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain).accessibilityIdentifier("provider-usage")
    }

    @ViewBuilder private func claude(_ snapshot: ClaudeUsageSnapshot) -> some View {
        if let context = snapshot.context {
            VStack(alignment: .leading, spacing: 6) {
                Text("Context measurement").font(.caption.weight(.semibold))
                Text(ProviderUsagePresentation.contextExplanation(context.source)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProviderUsageValueRow(label: String(localized: "Tokens in context"), value: ProviderUsageFormatting.count(context.usedTokens, locale: locale))
                ProviderUsageValueRow(label: String(localized: "Reported window"), value: ProviderUsageFormatting.count(context.maxTokens, locale: locale))
                if let model = context.model { ProviderUsageValueRow(label: String(localized: "Observed model"), value: model) }
                if context.source == .message {
                    ProviderUsageValueRow(label: String(localized: "Request input"), value: ProviderUsageFormatting.count(context.inputTokens, locale: locale))
                    ProviderUsageValueRow(label: String(localized: "Request output"), value: ProviderUsageFormatting.count(context.outputTokens, locale: locale))
                }
                if let ttl = context.promptCacheTtlMs {
                    ProviderUsageValueRow(label: String(localized: "Reported prompt-cache lifetime"),
                        value: ttl == 300_000 ? String(localized: "5 minutes") : String(localized: "1 hour"))
                }
                if let expires = context.promptCacheExpiresAt {
                    ProviderUsageValueRow(label: String(localized: "Estimated cache expiry"), value: ProviderUsageFormatting.date(expires, locale: locale))
                }
                ProviderUsageValueRow(label: String(localized: "Observed"), value: ProviderUsageFormatting.date(context.observedAt, locale: locale))
            }.accessibilityIdentifier("provider-usage-context")
        }
        if let session = snapshot.session { ClaudeUsageSessionView(value: session) }
        if snapshot.statusObserved {
            ProviderUsageValueRow(label: String(localized: "Native status"), value: ProviderUsagePresentation.status(snapshot.status))
                .accessibilityIdentifier("provider-usage-status")
        }
        if let compaction = snapshot.compaction {
            VStack(alignment: .leading, spacing: 6) {
                Text("Native compaction").font(.caption.weight(.semibold))
                if let outcome = compaction.outcome {
                    ProviderUsageValueRow(label: String(localized: "Outcome"), value: outcome == .success ? String(localized: "Completed") : String(localized: "Failed"))
                }
                if let trigger = compaction.trigger {
                    ProviderUsageValueRow(label: String(localized: "Trigger"), value: trigger == .auto ? String(localized: "Automatic") : String(localized: "Manual"))
                }
                ProviderUsageValueRow(label: String(localized: "Before"), value: ProviderUsageFormatting.count(compaction.beforeTokens, locale: locale))
                ProviderUsageValueRow(label: String(localized: "After"), value: ProviderUsageFormatting.count(compaction.afterTokens, locale: locale))
            }.accessibilityIdentifier("provider-usage-compaction")
        }
        if !snapshot.rateLimits.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Observed usage limits").font(.caption.weight(.semibold))
                Text("These are native window observations, not a guarantee that an account can send another request.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(snapshot.rateLimits.enumerated()), id: \.offset) { _, window in
                    ClaudeUsageLimitView(value: window)
                }
            }.accessibilityIdentifier("provider-usage-limits")
        }
    }
}

private struct ProviderMainAgentUsageView: View {
    let value: ProviderMainAgentUsagePresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProviderUsageValueRow(label: String(localized: "Main-agent tokens"), value: value.status)
                .fontWeight(.semibold)
            ForEach(value.rows) { row in ProviderUsageValueRow(label: row.label, value: row.value) }
            Text("Input includes reported cache reads and writes. Output includes reported reasoning tokens.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Main-agent accounting only. Subagent tokens are excluded.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if value.hasSubagents {
                Text("Subagent activity was observed; its tokens are not added to these main-agent counts.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("provider-usage-main-agent")
    }
}

struct ClaudeUsageSessionView: View {
    let value: ClaudeSessionUsage
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Query session totals").font(.caption.weight(.semibold))
            Text("Cumulative across turns in this native query session, including subagents and internal calls. These snapshots overlap and must not be summed across runs.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ProviderUsageValueRow(label: String(localized: "Estimated session cost (USD)"), value: ProviderUsageFormatting.currency(value.estimatedCostUSD, locale: locale))
            Text("The CLI reports an estimate, not an invoice.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ProviderUsageValueRow(label: String(localized: "Observed"), value: ProviderUsageFormatting.date(value.observedAt, locale: locale))
            if value.modelUsageAvailable {
                if value.models.isEmpty { Text("The native session reported no model entries.").foregroundStyle(.secondary) }
                else {
                    DisclosureGroup("Session models") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(value.models.enumerated()), id: \.offset) { _, model in
                                ClaudeUsageModelView(value: model)
                            }
                        }.padding(.top, 6)
                    }
                }
            } else { Text("Per-model session totals were not reported.").foregroundStyle(.secondary) }
        }.accessibilityIdentifier("provider-usage-session")
    }
}

struct ClaudeUsageModelView: View {
    let value: ClaudeModelUsage
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value.model).font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            if let canonical = value.canonicalModel, !canonical.utf8.elementsEqual(value.model.utf8) {
                ProviderUsageValueRow(label: String(localized: "Canonical model"), value: canonical)
            }
            ProviderUsageValueRow(label: String(localized: "Input (SDK)"), value: ProviderUsageFormatting.count(value.inputTokens, locale: locale))
            ProviderUsageValueRow(label: String(localized: "Cache read"), value: ProviderUsageFormatting.count(value.cacheReadInputTokens, locale: locale))
            ProviderUsageValueRow(label: String(localized: "Cache creation"), value: ProviderUsageFormatting.count(value.cacheCreationInputTokens, locale: locale))
            ProviderUsageValueRow(label: String(localized: "Output"), value: ProviderUsageFormatting.count(value.outputTokens, locale: locale))
            ProviderUsageValueRow(label: String(localized: "Thinking (within output)"), value: ProviderUsageFormatting.count(value.thinkingTokens, locale: locale))
            ProviderUsageValueRow(label: String(localized: "Web search requests"), value: ProviderUsageFormatting.count(value.webSearchRequests, locale: locale))
            ProviderUsageValueRow(label: String(localized: "Reported context window"), value: ProviderUsageFormatting.count(value.contextWindow, locale: locale))
            ProviderUsageValueRow(label: String(localized: "Reported maximum output"), value: ProviderUsageFormatting.count(value.maxOutputTokens, locale: locale))
            ProviderUsageValueRow(label: String(localized: "Estimated session model cost (USD)"), value: ProviderUsageFormatting.currency(value.estimatedCostUSD, locale: locale))
            if let costBasis = value.costBasis {
                ProviderUsageValueRow(label: String(localized: "Native cost basis"), value: ProviderUsagePresentation.costBasis(costBasis))
            }
        }.accessibilityIdentifier("provider-usage-model")
    }
}

struct ClaudeUsageLimitView: View {
    let value: ClaudeRateLimitUsage
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(ProviderUsagePresentation.window(value.window)).font(.caption.weight(.medium))
            ProviderUsageValueRow(label: String(localized: "Native window status"), value: ProviderUsagePresentation.limitStatus(value.status))
            ProviderUsageValueRow(label: String(localized: "Utilization"), value: ProviderUsageFormatting.percent(value.utilization, locale: locale))
            if let resetsAt = value.resetsAt { ProviderUsageValueRow(label: String(localized: "Resets"), value: ProviderUsageFormatting.date(resetsAt, locale: locale)) }
            if let overage = value.overageStatus {
                ProviderUsageValueRow(label: String(localized: "Native overage status"), value: ProviderUsagePresentation.limitStatus(overage))
            }
            if let reset = value.overageResetsAt { ProviderUsageValueRow(label: String(localized: "Overage resets"), value: ProviderUsageFormatting.date(reset, locale: locale)) }
            if value.isUsingOverage == true || value.overageInUse == true {
                Text("The CLI reports that overage is in use.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if value.status == .rejected && !value.blocked {
                Text("This window is rejected; the CLI reports overage as allowed or in use.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ProviderUsageValueRow: View {
    let label: String
    let value: String
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 4)
                Text(value).fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(.secondary)
                Text(value).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .combine)
    }
}

struct ProviderMainAgentUsagePresentation {
    struct Row: Identifiable {
        let id: String
        let label: String
        let value: String
    }
    let status: String
    let rows: [Row]
    let hasSubagents: Bool
}

enum ProviderUsagePresentation {
    static func mainAgent(_ usage: ProviderUsageUpdate, locale: Locale) -> ProviderMainAgentUsagePresentation {
        let status: String
        let input: Int?, cached: Int?, created: Int?, output: Int?, reasoning: Int?
        let hasSubagents: Bool
        switch usage {
        case .claude(let snapshot):
            status = snapshot.turn?.usageStatus.rawValue ?? "unavailable"
            input = snapshot.turn?.inputTokens; cached = snapshot.turn?.cachedInputTokens
            created = snapshot.turn?.cacheCreationTokens; output = snapshot.turn?.outputTokens; reasoning = snapshot.turn?.reasoningTokens
            hasSubagents = snapshot.turn?.hasSubagents == true
        case .openCode(let value):
            status = value.usageStatus.rawValue; input = value.inputTokens; cached = value.cachedInputTokens
            created = value.cacheCreationTokens; output = value.outputTokens; reasoning = value.reasoningTokens; hasSubagents = value.hasSubagents
        }
        let label: String
        switch status { case "complete": label = String(localized: "Complete"); case "partial": label = String(localized: "Partial"); default: label = String(localized: "Unavailable") }
        return .init(status: label, rows: [
            .init(id: "input", label: String(localized: "Input"), value: ProviderUsageFormatting.count(input, locale: locale)),
            .init(id: "cache-read", label: String(localized: "Cache read (within input)"), value: ProviderUsageFormatting.count(cached, locale: locale)),
            .init(id: "cache-creation", label: String(localized: "Cache creation (within input)"), value: ProviderUsageFormatting.count(created, locale: locale)),
            .init(id: "output", label: String(localized: "Output"), value: ProviderUsageFormatting.count(output, locale: locale)),
            .init(id: "reasoning", label: String(localized: "Reasoning (within output)"), value: ProviderUsageFormatting.count(reasoning, locale: locale))], hasSubagents: hasSubagents)
    }
    static func contextExplanation(_ source: ClaudeContextUsage.Source) -> String {
        switch source {
        case .message: String(localized: "Latest root request measurement. This is separate from whole-run token accounting.")
        case .compaction: String(localized: "Context size reported after native compaction. Per-category counts and capacity may not be available.")
        case .nativeReport: String(localized: "Native context report. The reported window may reflect compaction policy rather than a model hard limit.")
        }
    }
    static func status(_ value: ClaudeNativeUsageStatus?) -> String {
        switch value {
        case .compacting: String(localized: "Compacting")
        case .requesting: String(localized: "Requesting")
        case nil: String(localized: "No active status reported")
        }
    }
    static func costBasis(_ value: String) -> String {
        switch value {
        case "list": String(localized: "List prices")
        case "managed": String(localized: "Managed pricing")
        default: String(localized: "Unknown")
        }
    }
    static func window(_ value: ClaudeRateLimitUsage.Window) -> String {
        switch value {
        case .fiveHour: String(localized: "Five-hour window")
        case .sevenDay: String(localized: "Weekly window")
        case .sevenDayOpus: String(localized: "Weekly Opus window")
        case .sevenDaySonnet: String(localized: "Weekly Sonnet window")
        case .sevenDayOverageIncluded: String(localized: "Weekly overage-included window")
        case .overage: String(localized: "Overage window")
        case .unknown: String(localized: "Unspecified window")
        }
    }
    static func limitStatus(_ value: ClaudeRateLimitUsage.Status) -> String {
        switch value {
        case .allowed: String(localized: "Allowed")
        case .allowedWarning: String(localized: "Allowed with warning")
        case .rejected: String(localized: "Rejected")
        }
    }
}

enum ProviderUsageFormatting {
    static func count(_ value: Int?, locale: Locale) -> String {
        value.map { $0.formatted(.number.locale(locale)) } ?? String(localized: "Not reported")
    }
    static func currency(_ value: Double?, locale: Locale) -> String {
        value.map { $0.formatted(.currency(code: "USD").precision(.significantDigits(1...8)).locale(locale)) } ?? String(localized: "Not reported")
    }
    static func percent(_ value: Double?, locale: Locale) -> String {
        value.map { $0.formatted(.percent.precision(.fractionLength(0...1)).locale(locale)) } ?? String(localized: "Not reported")
    }
    static func date(_ value: Date, locale: Locale) -> String {
        value.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(locale))
    }
}
