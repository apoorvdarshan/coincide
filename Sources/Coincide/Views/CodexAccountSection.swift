import CoincideCore
import SwiftUI

struct CodexAccountSection: View {
    let account: CodexAccountStore
    var runtimeConfiguration: CodexRuntimeConfiguration? = nil
    let refresh: @MainActor () async -> Void
    @State private var revealEmail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Codex account") {
                if let snapshot = account.snapshot {
                    SettingsRow(title: "Sign-in") {
                        Text(CodexAccountPresentation.accountTitle(snapshot.identity.kind)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("codex-account-kind")
                    }
                    if snapshot.identity.kind == .signedOut, !snapshot.identity.requiresOpenAIAuth {
                        Text("This CLI does not require an OpenAI sign-in.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 14)
                    }
                    if let plan = snapshot.identity.planType {
                        SettingsDivider()
                        SettingsRow(title: "Plan") { Text(plan).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    if let email = snapshot.identity.email {
                        SettingsDivider()
                        SettingsRow(title: "Email") {
                            HStack(spacing: 12) {
                                Text(revealEmail ? email : String(localized: "Hidden"))
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 240, alignment: .trailing)
                                    .accessibilityIdentifier("codex-account-email")
                                Toggle("Show account email", isOn: $revealEmail).labelsHidden()
                                    .toggleStyle(.switch).controlSize(.small)
                                    .accessibilityIdentifier("codex-account-reveal-email")
                            }
                        }
                    }
                    if account.isStale {
                        SettingsDivider()
                        SettingsRow(title: "Status") {
                            Label("Out of date", systemImage: "clock.badge.exclamationmark")
                                .foregroundStyle(.secondary).accessibilityIdentifier("codex-account-stale")
                        }
                    }
                    SettingsDivider()
                    SettingsRow(title: "Last checked") {
                        Text(snapshot.checkedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    SettingsRow(title: "Account", subtitle: "Read the CLI’s current sign-in and usage limits.") {
                        Text("Not checked").foregroundStyle(.secondary)
                    }
                }
                if let error = account.errorMessage {
                    SettingsDivider()
                    Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, 14)
                        .accessibilityIdentifier("codex-account-error")
                }
                SettingsDivider()
                SettingsRow(title: "Account status") {
                    HStack(spacing: 8) {
                        if account.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing Codex account") }
                        Button("Refresh Account") { Task { await refresh() } }
                            .buttonStyle(SettingsActionButtonStyle())
                            .disabled(account.isRefreshing).accessibilityIdentifier("codex-account-refresh")
                    }
                }
                Text(runtimeConfiguration == nil || runtimeConfiguration == CodexRuntimeConfiguration()
                     ? String(localized: "To sign in or change accounts, run codex login in Terminal, then refresh.")
                     : String(localized: "Sign in with the selected Codex executable and home, then refresh."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 14)
            }
            if let snapshot = account.snapshot { usage(snapshot.usage) }
        }
        .onChange(of: account.snapshot?.identity) { _, _ in revealEmail = false }
    }

    @ViewBuilder private func usage(_ usage: CodexAccountUsage) -> some View {
        switch usage {
        case .unsupported:
            SettingsCard(title: "Usage limits") {
                SettingsRow(title: "Allowance", subtitle: "This CLI sign-in does not report usage limits.") {
                    Text("Not reported").foregroundStyle(.secondary)
                        .accessibilityIdentifier("codex-account-usage-unsupported")
                }
            }
        case .available(let snapshot): allowance(snapshot, fresh: !account.isStale)
        case .probeFailed(let previous):
            if let previous { allowance(previous, fresh: false) }
            else {
                SettingsCard(title: "Usage limits") {
                    SettingsRow(title: "Allowance", subtitle: "Refresh the account to check again.") {
                        Text("Unavailable").foregroundStyle(.secondary)
                            .accessibilityIdentifier("codex-account-usage-unavailable")
                    }
                }
            }
        }
    }

    private func allowance(_ snapshot: CodexUsageSnapshot, fresh: Bool) -> some View {
        SettingsCard(title: "Usage limits") {
            if fresh, let allowed = snapshot.ordinaryUsageAllowed {
                SettingsRow(title: "Current allowance") {
                    Text(allowed ? "Available" : "Unavailable").foregroundStyle(.secondary)
                        .accessibilityIdentifier("codex-account-ordinary-usage")
                }
                if !snapshot.buckets.isEmpty { SettingsDivider() }
            }
            if snapshot.buckets.isEmpty {
                SettingsRow(title: "Usage windows") { Text("Not reported").foregroundStyle(.secondary) }
            }
            ForEach(snapshot.buckets, id: \.id) { bucket in
                if bucket.id != snapshot.buckets.first?.id { SettingsDivider() }
                CodexUsageBucketView(bucket: bucket)
            }
            if !fresh {
                SettingsDivider()
                Text("Showing the last reported limits. Refresh to check the current allowance.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.vertical, 14)
            }
        }
    }
}

private struct CodexUsageBucketView: View {
    let bucket: CodexUsageBucket
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(bucket.name ?? bucket.normalModelSlug ?? bucket.id)
                    .font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if let plan = bucket.planType { Text(plan).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 12) {
                    if let primary = bucket.primary { CodexUsageWindowView(title: String(localized: "Primary window"), window: primary, now: context.date) }
                    if let secondary = bucket.secondary { CodexUsageWindowView(title: String(localized: "Secondary window"), window: secondary, now: context.date) }
                    if let limit = bucket.individualLimit {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text("Spending limit"); Spacer(); Text(limit.limit).foregroundStyle(.secondary) }
                            HStack { Text("Used"); Spacer(); Text(limit.used).foregroundStyle(.secondary) }
                            if let remaining = CodexAccountPresentation.boundedPercent(limit.remainingPercent) { allowanceProgress(remaining) }
                            CodexUsageResetView(date: limit.resetsAt, now: context.date)
                        }
                    }
                }
            }
            if let credits = bucket.credits {
                HStack {
                    Text("Credits")
                    Spacer()
                    if credits.unlimited { Text("Unlimited").foregroundStyle(.secondary) }
                    else if let balance = credits.balance { Text(balance).foregroundStyle(.secondary) }
                    else { Text(credits.hasCredits ? "Available" : "None reported").foregroundStyle(.secondary) }
                }
            }
            if bucket.spendControlReached == true || bucket.rateLimitReachedType != nil {
                Label("Usage or spending limit reached", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12)).padding(.vertical, 14)
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
            }.font(.system(size: 12))
            if let remaining = CodexAccountPresentation.remainingPercent(used: window.usedPercent) {
                allowanceProgress(remaining)
            } else { Text("Usage is unavailable.").font(.system(size: 12)).foregroundStyle(.secondary) }
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
        }.font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor private func allowanceProgress(_ remaining: Double) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text("\((remaining / 100).formatted(.percent.precision(.fractionLength(0)))) remaining").font(.system(size: 12))
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
