import CoincideCore
import SwiftUI

struct RemoteLifecycleControls: View {
    @Bindable var store: RemoteLifecycleStore
    @State private var snoozing: RemoteLifecycleCapture?
    @State private var settling: RemoteLifecycleCapture?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let value = store.state {
                if let phase = value.settlementPhase {
                    HStack {
                        Label(phase == .resuming ? "Resuming conversation…" : "Conversation settled", systemImage: "checkmark.circle")
                        Spacer()
                        Button("Resume") { let capture = value.capture; Task { _ = await store.resume(capture: capture) } }
                            .disabled(!store.canAct || !value.resume.allowed)
                            .help(value.resume.reason ?? "Resume this remote conversation")
                            .accessibilityIdentifier("remote-lifecycle-resume")
                    }
                    Text("Resume releases this conversation's settlement hold after its managed jobs stop. Authored queued messages can then run.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let until = value.lifecycle?.snoozedUntil, until > Date() {
                    HStack {
                        Label("Snoozed until \(until, format: .dateTime.month(.abbreviated).day().hour().minute())", systemImage: "moon.zzz")
                        Spacer()
                        Button("Wake") { let capture = value.capture; Task { _ = await store.wake(capture: capture) } }
                            .disabled(!store.canAct || !value.wake.allowed)
                            .accessibilityIdentifier("remote-lifecycle-wake")
                    }
                    Text("Waking changes attention only. It does not send a message or run a cleanup script.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Snooze…") { snoozing = value.capture }.disabled(!store.canAct || !value.snooze.allowed)
                        .accessibilityIdentifier("remote-lifecycle-snooze")
                    if value.settlementID == nil {
                        Button("Settle without Cleanup Script…") { settling = value.capture }
                            .disabled(!store.canAct || !value.settle.allowed)
                            .help(value.settle.reason ?? "Explicitly skip cleanup-script review and settle this conversation")
                            .accessibilityIdentifier("remote-lifecycle-settle-without-script")
                    }
                    Spacer()
                    Menu {
                        Button(value.lifecycle?.autoSettleDisabledAt == nil ? "Disable Automatic Settlement" : "Enable Automatic Settlement") {
                            let capture = value.capture, enabled = value.lifecycle?.autoSettleDisabledAt != nil
                            Task { _ = await store.setAutoSettle(enabled: enabled, capture: capture) }
                        }.disabled(!store.canAct)
                        Button("Refresh Controls") { Task { await store.refresh() } }.disabled(!store.canRead || store.isLoading)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Conversation lifecycle actions")
                }.controlSize(.small)
                if value.lifecycle?.autoSettleDisabledAt != nil {
                    Text("Automatic settlement is disabled for this conversation.").font(.caption).foregroundStyle(.secondary)
                }
            } else if store.supported && store.connected {
                Button("Refresh Conversation Controls") { Task { await store.refresh() } }.disabled(store.isLoading)
            }
            if let message = store.unavailableMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).coincideSurface()
        .accessibilityElement(children: .contain).accessibilityIdentifier("remote-lifecycle-controls")
        .sheet(item: $snoozing) { capture in
            RemoteLifecycleSnoozeSheet(store: store, capture: capture, close: { snoozing = nil })
        }
        .confirmationDialog("Settle without a Cleanup Script?", isPresented: Binding(get: { settling != nil }, set: { if !$0 { settling = nil } })) {
            if let capture = settling {
                Button("Settle without Cleanup Script") { settling = nil; Task { _ = await store.settleWithoutScript(capture: capture) } }
            }
            Button("Cancel", role: .cancel) { settling = nil }
        } message: {
            Text("Keep this remote conversation for later and leave its files and terminal tabs in place. This explicit choice skips cleanup-script review and execution. Choose Resume to continue later.")
        }
    }
}

private struct RemoteLifecycleSnoozeSheet: View {
    @Bindable var store: RemoteLifecycleStore
    let capture: RemoteLifecycleCapture
    let close: () -> Void
    @State private var until = Date().addingTimeInterval(3_600)
    @State private var applying = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Snooze Remote Conversation").font(.title2)
            Text("Keep this conversation quiet until the selected time. Failures or questions can wake it earlier. Snoozing and waking never send input.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("1 Hour") { until = Date().addingTimeInterval(3_600) }
                Button("Tomorrow Morning") {
                    let calendar = Calendar.current, now = Date()
                    let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
                    until = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
                }
            }.disabled(applying)
            DatePicker("Wake at", selection: $until, displayedComponents: [.date, .hourAndMinute]).disabled(applying)
                .accessibilityIdentifier("remote-lifecycle-snooze-until")
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).disabled(applying)
                Spacer()
                Button(applying ? "Snoozing…" : "Snooze") {
                    applying = true
                    Task {
                        let accepted = await store.snooze(until: until, capture: capture)
                        applying = false; if accepted { close() }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(applying || !store.canAct || until <= Date() || store.state.map { RemoteLifecycleProtocol.same($0.capture, capture) } != true)
                    .accessibilityIdentifier("remote-lifecycle-snooze-apply")
            }
        }.padding(24).frame(width: 460).interactiveDismissDisabled(applying)
    }
}

struct RemoteLifecycleSettingsSheet: View {
    @Bindable var store: RemoteLifecycleStore
    let close: () -> Void
    @State private var environmentID: UUID
    @State private var expected: WorkspaceLifecyclePolicy
    @State private var inactivity: Bool
    @State private var days: Double
    @State private var onMerge: Bool
    @State private var keepPullRequests: Bool
    @State private var applying = false
    init(store: RemoteLifecycleStore, environmentID: UUID, policy: WorkspaceLifecyclePolicy, close: @escaping () -> Void) {
        self.store = store; self.close = close
        _environmentID = State(initialValue: environmentID); _expected = State(initialValue: policy)
        _inactivity = State(initialValue: policy.afterDays != nil); _days = State(initialValue: policy.afterDays ?? 3)
        _onMerge = State(initialValue: policy.onMerge); _keepPullRequests = State(initialValue: policy.keepPullRequests)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remote Automatic Settlement").font(.title2)
            Text("These settings apply to this remote Coincide environment. Pinned, snoozed and working conversations stay active. Automatic settlement never runs a cleanup script.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Settle Inactive Conversations", isOn: $inactivity)
                .accessibilityIdentifier("remote-lifecycle-policy-inactivity")
            if inactivity {
                Stepper(value: $days, in: 1...90, step: 1) {
                    Text("After \(days, format: .number.precision(.fractionLength(0...2))) days without activity")
                }.accessibilityIdentifier("remote-lifecycle-policy-days")
            }
            Toggle("Settle Merged Pull Request Conversations", isOn: $onMerge)
                .accessibilityIdentifier("remote-lifecycle-policy-merge")
            Toggle("Keep Pull Request Conversations During Inactivity Settlement", isOn: $keepPullRequests)
                .accessibilityIdentifier("remote-lifecycle-policy-keep-pr")
            Text("Closed pull requests can also settle when automatic settlement is enabled. If another window changes these settings, this update is refused so you can review the new policy.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).disabled(applying)
                Spacer()
                Button(applying ? "Applying…" : "Apply") {
                    let next = WorkspaceLifecyclePolicy(afterDays: inactivity ? days : nil, onMerge: onMerge, keepPullRequests: keepPullRequests)
                    applying = true
                    Task {
                        let accepted = await store.applyPolicy(next, expected: expected, environmentID: environmentID)
                        applying = false; if accepted { close() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(applying || !store.canAct || store.environmentID != environmentID)
                    .accessibilityIdentifier("remote-lifecycle-policy-apply")
            }
        }.padding(24).frame(width: 500).disabled(applying).interactiveDismissDisabled(applying)
    }
}
