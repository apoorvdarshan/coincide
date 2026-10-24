import AppKit
import CoincideCore
import SwiftUI

/// Mounted inside Settings, alongside the existing integration/configuration pages.
struct ProviderSessionsView: View {
    let scope: ProviderSessionsScope
    let onImport: () -> Void
    @State private var store: ProviderSessionsStore
    @State private var pendingStop: ProviderSessionSummary?
    @State private var pendingStopScope: ProviderSessionsScope?

    init(scope: ProviderSessionsScope, onImport: @escaping () -> Void) {
        self.scope = scope; self.onImport = onImport
        _store = State(initialValue: ProviderSessionsStore(scope: scope))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                SettingsRow(title: "Provider sessions", subtitle: "These conversations belong to the selected CLI. Import a copy to continue in Coincide with either provider.") {
                    Button("Import a copy", action: onImport)
                        .buttonStyle(SettingsActionButtonStyle())
                        .accessibilityIdentifier("provider-session-import")
                }
                SettingsDivider()
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search sessions", text: $store.search)
                        .textFieldStyle(.plain).accessibilityIdentifier("provider-session-search")
                    Button { store.refresh() } label: {
                        if store.isRefreshing { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
                        else { Image(systemName: "arrow.clockwise").frame(width: 16, height: 16) }
                    }
                    .buttonStyle(SettingsActionButtonStyle()).disabled(store.isBusy)
                    .help("Refresh provider sessions").accessibilityLabel("Refresh provider sessions")
                    .accessibilityIdentifier("provider-session-refresh")
                }.padding(.vertical, 14)
                SettingsDivider()
                SettingsRow(title: "Running and waiting only") {
                    Toggle("Running and waiting only", isOn: $store.activeOnly).labelsHidden().toggleStyle(.switch)
                        .accessibilityIdentifier("provider-session-active-filter")
                }
            }

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("provider-session-error")
            }

            if !store.sessions.isEmpty {
                SettingsCard(title: "Local sessions") {
                    ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { SettingsDivider() }
                        ProviderSessionRow(session: session, busy: store.isBusy,
                            inspecting: store.inspectingID == session.id, stopping: store.stoppingID == session.id,
                            inspect: { if store.scope == scope { store.inspect(session) } },
                            stop: { pendingStopScope = scope; pendingStop = session })
                    }
                }
            } else if !store.isRefreshing, store.errorMessage == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.snapshot == nil ? "Loading sessions…" : "No matching sessions")
                        .font(.system(size: 13, weight: .medium))
                    Text("Sessions appear when the selected provider reports them. Saved Coincide chats remain in your sidebar.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.vertical, 10).accessibilityIdentifier("provider-session-empty")
            }

            VStack(alignment: .leading, spacing: 6) {
                if let snapshot = store.snapshot {
                    Text("Updated \(snapshot.checkedAt.formatted(date: .omitted, time: .shortened))")
                    if snapshot.hasMore {
                        Text(scope.provider == .codex
                             ? "Showing the 200 most recently updated sessions. Choose a project to narrow the list."
                             : "The provider returned more sessions than can be displayed at once.")
                    }
                }
                Text(scope.provider == .codex
                     ? "Codex connects to its existing local daemon. Saved sessions can appear without a live status; separate standalone CLI processes may not appear as running. This page does not start or resume conversations."
                     : "Claude reports interactive and background sessions. Recent output and Stop are available for background sessions; interactive sessions remain controlled in their terminal.")
                Text("Cloud and remote sessions are not connected here.")
            }.font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .disabled(store.scope != scope)
        .task(id: scope) { pendingStop = nil; pendingStopScope = nil; store.configure(scope); store.refresh() }
        .onDisappear { store.close() }
        .sheet(item: $store.details) { ProviderSessionDetailsView(details: $0) }
        .confirmationDialog("Stop this provider session?", isPresented: Binding(
            get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }
        ), titleVisibility: .visible, presenting: pendingStop) { session in
            Button(scope.provider == .codex ? "Interrupt current turn" : "Stop background session", role: .destructive) {
                let captured = pendingStopScope
                pendingStop = nil; pendingStopScope = nil
                guard captured == scope, store.scope == scope else { return }
                store.stop(session)
            }
            Button("Cancel", role: .cancel) { pendingStop = nil }
        } message: { session in
            Text("\(session.title) belongs to \(session.provider.name). Its conversation is kept. This action affects the original provider session.")
        }
    }
}

private struct ProviderSessionRow: View {
    let session: ProviderSessionSummary
    let busy: Bool
    let inspecting: Bool
    let stopping: Bool
    let inspect: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                ProviderLogo(provider: session.provider, size: 17).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    Text(session.directory.isEmpty ? "Working directory unavailable" : session.directory)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(session.directory)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(status).font(.system(size: 11)).foregroundStyle(session.state.isActive ? Color.primary : .secondary)
                    .fixedSize().padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.055), in: Capsule())
            }
            HStack(spacing: 8) {
                Text(session.kind == "subagent" ? "Subagent" : session.kind == "background" ? "Background" : "Provider session")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: inspect) {
                    if inspecting { ProgressView().controlSize(.small) }
                    Text(session.canReadOutput ? "View details" : "Resume command")
                }.buttonStyle(SettingsActionButtonStyle()).disabled(busy)
                    .accessibilityIdentifier("provider-session-details-" + session.id)
                if session.canStop {
                    Button(action: stop) {
                        if stopping { ProgressView().controlSize(.small) }
                        Text(session.provider == .codex ? "Interrupt" : "Stop")
                    }.buttonStyle(SettingsActionButtonStyle()).disabled(busy)
                        .accessibilityIdentifier("provider-session-stop-" + session.id)
                }
            }
        }.padding(.vertical, 14)
    }
    private var status: String {
        session.provider == .codex && !session.isLoaded ? "Saved · not loaded" : session.state.label
    }
}

private struct ProviderSessionDetailsView: View {
    let details: ProviderSessionDetails
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(details.session.title).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(SettingsActionButtonStyle())
            }
            Text(details.note).font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                Text(details.output).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            .frame(minHeight: 200, maxHeight: .infinity)
            .background(ChatChrome.settingsCard, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("provider-session-output")
            SettingsCard {
                SettingsRow(title: "Continue in the provider CLI", subtitle: "This command resumes the original conversation. Use Import a copy to create a separate Coincide conversation instead.") {
                    Button(copied ? "Copied" : "Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(details.resumeCommand, forType: .string)
                        copied = true
                    }.buttonStyle(SettingsActionButtonStyle()).accessibilityIdentifier("provider-session-copy-resume")
                }
            }
        }.padding(24).frame(minWidth: 520, idealWidth: 660, maxWidth: 800, minHeight: 420, idealHeight: 570)
    }
}
