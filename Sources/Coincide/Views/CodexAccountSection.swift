import CoincideCore
import SwiftUI

struct CodexAccountSection: View {
    let account: CodexAccountStore
    var runtimeConfiguration: CodexRuntimeConfiguration? = nil
    let refresh: @MainActor () async -> Void
    @State private var revealEmail = false

    var body: some View {
        Section("Codex Account") {
            if let snapshot = account.snapshot {
                LabeledContent("Sign-in", value: CodexAccountPresentation.accountTitle(snapshot.identity.kind))
                    .accessibilityIdentifier("codex-account-kind")
                if snapshot.identity.kind == .signedOut, !snapshot.identity.requiresOpenAIAuth {
                    Text("This CLI does not require an OpenAI sign-in.").font(.caption).foregroundStyle(.secondary)
                }
                if let plan = snapshot.identity.planType {
                    LabeledContent("Plan", value: plan).textSelection(.enabled)
                }
                if let email = snapshot.identity.email {
                    LabeledContent("Email") {
                        Text(revealEmail ? email : String(localized: "Hidden"))
                            .textSelection(.enabled)
                    }.accessibilityIdentifier("codex-account-email")
                    Toggle("Show account email", isOn: $revealEmail)
                        .accessibilityIdentifier("codex-account-reveal-email")
                }
                if account.isStale {
                    Label("Account or usage information is out of date.", systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("codex-account-stale")
                }
                usage(snapshot.usage)
                LabeledContent("Last checked") {
                    Text(snapshot.checkedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                }.font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Refresh to read the Codex CLI sign-in and available usage information.")
                    .foregroundStyle(.secondary)
            }
            if let error = account.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("codex-account-error")
            }
            HStack {
                Button("Refresh Account") { Task { await refresh() } }
                    .disabled(account.isRefreshing)
                    .accessibilityIdentifier("codex-account-refresh")
                if account.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing Codex account") }
            }
            Text(runtimeConfiguration == nil || runtimeConfiguration == CodexRuntimeConfiguration()
                 ? String(localized: "Coincide uses the Codex CLI sign-in on this Mac. To sign in or change accounts, run codex login in Terminal, then refresh here.")
                 : String(localized: "Account information comes from the runtime and Codex home chosen above. Sign in using that executable and home in Terminal, then refresh here. Installing a runtime does not sign in."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: account.snapshot?.identity) { _, _ in revealEmail = false }
    }

    @ViewBuilder private func usage(_ usage: CodexAccountUsage) -> some View {
        switch usage {
        case .unsupported:
            Text("This Codex CLI sign-in does not report usage limits.")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("codex-account-usage-unsupported")
        case .available(let snapshot):
            allowance(snapshot, fresh: !account.isStale)
        case .probeFailed(let previous):
            if let previous { allowance(previous, fresh: false) }
            else {
                Text("Usage is unavailable. Refresh to check again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("codex-account-usage-unavailable")
            }
        }
    }

    private func allowance(_ snapshot: CodexUsageSnapshot, fresh: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if fresh, let allowed = snapshot.ordinaryUsageAllowed {
                Text(allowed ? "Codex reports usage is available." : "Codex reports the current usage allowance is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("codex-account-ordinary-usage")
            }
            if snapshot.buckets.isEmpty {
                Text("No usage windows were reported.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(snapshot.buckets, id: \.id) { bucket in
                CodexUsageBucketView(bucket: bucket)
            }
        }
    }
}

private struct CodexUsageBucketView: View {
    let bucket: CodexUsageBucket
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bucket.name ?? bucket.normalModelSlug ?? bucket.id).font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let plan = bucket.planType { LabeledContent("Plan", value: plan).font(.caption) }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    if let primary = bucket.primary { CodexUsageWindowView(title: String(localized: "Primary window"), window: primary, now: context.date) }
                    if let secondary = bucket.secondary { CodexUsageWindowView(title: String(localized: "Secondary window"), window: secondary, now: context.date) }
                    if let limit = bucket.individualLimit {
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent("Spending limit", value: limit.limit)
                            LabeledContent("Used", value: limit.used)
                            if let remaining = CodexAccountPresentation.boundedPercent(limit.remainingPercent) {
                                allowanceProgress(remaining)
                            }
                            CodexUsageResetView(date: limit.resetsAt, now: context.date)
                        }.font(.caption)
                    }
                }
            }
            if let credits = bucket.credits {
                if credits.unlimited { LabeledContent("Credits", value: String(localized: "Unlimited")) }
                else if let balance = credits.balance { LabeledContent("Credit balance", value: balance) }
                else { LabeledContent("Credits", value: credits.hasCredits ? String(localized: "Available") : String(localized: "None reported")) }
            }
            if bucket.spendControlReached == true || bucket.rateLimitReachedType != nil {
                Label("Codex reports a usage or spending limit for this allowance.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
    }
}

private struct CodexUsageWindowView: View {
    let title: String
    let window: CodexUsageWindow
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                if let minutes = window.windowDurationMinutes, minutes > 0 {
                    Text(Duration.seconds(Double(minutes) * 60).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide)))
                        .foregroundStyle(.secondary)
                }
            }.font(.caption)
            if let remaining = CodexAccountPresentation.remainingPercent(used: window.usedPercent) {
                allowanceProgress(remaining)
            } else { Text("Usage is unavailable.").font(.caption).foregroundStyle(.secondary) }
            if let reset = window.resetsAt { CodexUsageResetView(date: reset, now: now) }
        }
    }
}

private struct CodexUsageResetView: View {
    let date: Date
    let now: Date
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(date > now ? "Resets" : "Reported reset")
            Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
            if date <= now { Text("Refresh to check.") }
        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor private func allowanceProgress(_ remaining: Double) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text("\((remaining / 100).formatted(.percent.precision(.fractionLength(0)))) remaining").font(.caption)
        ProgressView(value: remaining, total: 100)
            .accessibilityLabel("Remaining allowance")
            .accessibilityValue((remaining / 100).formatted(.percent.precision(.fractionLength(0))))
    }
}

enum CodexAccountPresentation {
    static func accountTitle(_ kind: CodexAccountKind) -> String {
        switch kind {
        case .signedOut: String(localized: "Signed out")
        case .apiKey: String(localized: "API key")
        case .chatgpt: String(localized: "ChatGPT")
        case .amazonBedrock: String(localized: "Amazon Bedrock")
        case .unknown: String(localized: "Unrecognized CLI sign-in")
        }
    }
    static func remainingPercent(used: Double) -> Double? {
        boundedPercent(used).map { 100 - $0 }
    }
    static func boundedPercent(_ percent: Double) -> Double? {
        percent.isFinite ? min(100, max(0, percent)) : nil
    }
}
