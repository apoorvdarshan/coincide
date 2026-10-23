import CoincideCore
import SwiftUI

struct WorkspaceLifecycleSettingsSection: View {
    @Bindable var store: WorkspaceStore
    private var policy: WorkspaceLifecyclePolicy { store.workspaceLifecyclePolicy }
    var body: some View {
        Section("Automatic Settlement") {
            Toggle("Settle Inactive Conversations", isOn: Binding(get: { policy.afterDays != nil },
                set: { store.setAutoSettlementAfterDays($0 ? (policy.afterDays ?? 3) : nil) }))
                .accessibilityIdentifier("settings-auto-settle-inactive")
            if let days = policy.afterDays {
                Stepper(value: Binding(get: { days }, set: { store.setAutoSettlementAfterDays($0) }), in: 1...90, step: 1) {
                    Text("After \(days, format: .number.precision(.fractionLength(0...2))) days without activity")
                }.accessibilityIdentifier("settings-auto-settle-days")
            }
            Toggle("Settle Merged Pull Request Conversations", isOn: Binding(get: { policy.onMerge }, set: { store.setAutoSettlementOnMerge($0) }))
                .accessibilityIdentifier("settings-auto-settle-merged")
            Toggle("Keep Pull Request Conversations During Inactivity Settlement", isOn: Binding(get: { policy.keepPullRequests }, set: { store.setAutoSettlementKeepsPullRequests($0) }))
                .accessibilityIdentifier("settings-auto-settle-keep-pr")
            Text("Pinned, snoozed and working conversations stay active. Closed pull requests can also settle when automatic settlement is enabled. Settled conversations retain their history and can be resumed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ThreadSnoozePresentation: Identifiable {
    let id: UUID
    let title: String
    let snoozedUntil: Date?
    init(_ thread: CodingThread) { id = thread.id; title = thread.title; snoozedUntil = thread.workspaceLifecycle?.snoozedUntil }
}

struct ThreadSnoozeSheet: View {
    let presentation: ThreadSnoozePresentation
    let snooze: (Date) async throws -> Void
    let dismiss: () -> Void
    @State private var until: Date
    @State private var saving = false
    @State private var error: String?
    init(presentation: ThreadSnoozePresentation, snooze: @escaping (Date) async throws -> Void, dismiss: @escaping () -> Void) {
        self.presentation = presentation; self.snooze = snooze; self.dismiss = dismiss
        // The sheet owns one reviewed snooze intent. Parent updates do not reset
        // the user's selected time; admission rechecks the current conversation.
        _until = State(initialValue: presentation.snoozedUntil ?? Date().addingTimeInterval(3_600))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Snooze Conversation").font(.title2)
            Text(presentation.title).font(.headline).lineLimit(2)
            Text("Keep this conversation quiet until the selected time. New failures or requests for your input wake it earlier.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("1 Hour") { until = Date().addingTimeInterval(3_600) }
                Button("Tomorrow Morning") {
                    let calendar = Calendar.current
                    let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86_400)
                    until = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
                }
            }.disabled(saving)
            DatePicker("Wake at", selection: $until, displayedComponents: [.date, .hourAndMinute]).disabled(saving)
                .accessibilityIdentifier("thread-snooze-until")
            if let error { Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "Snoozing…" : "Snooze") {
                    saving = true; error = nil
                    Task {
                        defer { saving = false }
                        do { try await snooze(until); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction).disabled(saving || until <= Date())
                    .accessibilityIdentifier("thread-snooze-apply")
            }
        }.padding(24).frame(width: 440)
    }
}
