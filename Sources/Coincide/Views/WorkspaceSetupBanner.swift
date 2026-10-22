import CoincideCore
import SwiftUI

/// Presentation subscribes to the app-owned job; closing a window never owns its lifetime.
struct WorkspaceSetupBanner: View {
    let store: WorkspaceStore
    let threadID: UUID
    let run: ThreadProjectScriptRun
    var role: ProjectScriptRole = .setup
    @State private var output: ProjectScriptOutputSnapshot?
    @State private var outputExpanded = false
    @State private var reviewing: ProjectScriptExecutionPlan?
    @State private var actionPending = false
    @State private var actionError: String?

    var body: some View {
        Group {
            if run.phase != .skipped {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        if [.discovering, .starting, .running, .stopping].contains(run.phase) {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: run.phase == .succeeded ? "checkmark.circle" : "terminal")
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(WorkspaceSetupPresentation.title(run, role: role)).font(.callout.weight(.medium))
                                .accessibilityIdentifier(identifier("status"))
                            Text(WorkspaceSetupPresentation.detail(run, role: role)).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    if let message = actionError ?? run.error {
                        Text(WorkspaceSetupPresentation.error(message, role: role)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(identifier("error"))
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { actionButtons }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 8) { actionButtons }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .controlSize(.small).disabled(actionPending || run.phase == .stopping)
                    if let output, !output.text.isEmpty {
                        DisclosureGroup(role == .setup ? "Setup Output" : "Settle Script Output", isExpanded: $outputExpanded) {
                            ScrollView {
                                Text(output.text).font(.caption.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .accessibilityIdentifier(identifier("output"))
                            }.frame(maxHeight: 130)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            if output.truncated {
                                Text("Showing recent output.").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.font(.caption).accessibilityIdentifier(identifier("output-disclosure"))
                    }
                }
                .padding(12).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain).accessibilityIdentifier(identifier())
            }
        }
        .sheet(item: $reviewing) { plan in
            WorkspaceSetupReviewSheet(store: store, threadID: threadID, plan: plan, close: { reviewing = nil }, role: role)
        }
        .onChange(of: run.id) { output = nil; actionError = nil; reviewing = nil; outputExpanded = false }
        .onChange(of: run.phase) { if !run.canApprove { reviewing = nil } }
        .task(id: run.id) {
            do {
                let stream = try await store.projectScriptOutput(threadID: threadID, runID: run.id)
                for await value in stream {
                    guard !Task.isCancelled, value.runID == run.id,
                          store.projectScriptRun(threadID: threadID, runID: value.runID) != nil else { return }
                    output = value
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { actionError = error.localizedDescription } }
        }
    }
    @ViewBuilder private var actionButtons: some View {
        if run.canApprove, let plan = run.plan {
            Button(role == .setup ? "Review Setup…" : "Review Settle Script…") { reviewing = plan }
                .accessibilityIdentifier(identifier("review"))
        }
        if canStop {
            Button(run.commandExit == nil ? (role == .setup ? "Stop Setup" : "Stop Settle Script") : "Stop Background Jobs") {
                perform { try await store.stopProjectScript(threadID: threadID, runID: run.id) }
            }.accessibilityIdentifier(identifier("stop"))
        }
        if run.canRetry {
            Button("Review Again") { perform { try await store.retryProjectScript(threadID: threadID, runID: run.id) } }
                .accessibilityIdentifier(identifier("retry"))
        }
        if run.canSkip {
            Button(role == .setup ? "Continue Without Setup" : "Skip Settle Script") { perform { try await store.skipProjectScript(threadID: threadID, runID: run.id) } }
                .accessibilityIdentifier(identifier("skip"))
        }
    }
    private var canStop: Bool {
        [.starting, .running, .succeeded, .failed].contains(run.phase) && run.plan != nil && output?.isClosed != true
    }
    private func identifier(_ suffix: String? = nil) -> String {
        let prefix = role == .setup ? "workspace-setup" : "workspace-settle-script"
        return suffix.map { prefix + "-" + $0 } ?? prefix
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !actionPending else { return }; actionPending = true; actionError = nil
        Task {
            defer { actionPending = false }
            do { try await operation() }
            catch is CancellationError { }
            catch { actionError = error.localizedDescription }
        }
    }
}

struct WorkspaceSetupReviewSheet: View {
    let store: WorkspaceStore
    let threadID: UUID
    let plan: ProjectScriptExecutionPlan
    let close: () -> Void
    var role: ProjectScriptRole = .setup
    @State private var submitting = false
    @State private var reviewError: String?
    private var canApprove: Bool {
        let current = store.projectScriptRun(threadID: threadID, runID: plan.id)
        return current?.id == plan.id && current?.canApprove == true && current?.plan == plan
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(role == .setup ? "Run Checkout Setup?" : "Run Settle Script?").font(.title2)
            Text(plan.script.name).font(.headline).lineLimit(2)
            Text("Review this command from the checkout’s t3.json. It runs with your account’s access to files and network.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(plan.workspacePath).font(.caption.monospaced()).textSelection(.enabled)
                .lineLimit(3).truncationMode(.middle).accessibilityIdentifier(identifier("review-cwd"))
            ScrollView {
                Text(plan.script.command).font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }.frame(minHeight: 70, maxHeight: 160)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier(identifier("review-command"))
            Text(role == .settle
                 ? "The conversation stays settled after this command finishes. Resuming stops its background jobs before messages continue."
                 : plan.script.runsAsynchronously
                 ? "Messages can start once this command starts. Background jobs remain available until stopped or the app quits."
                 : "Messages wait for this command to exit successfully. Background jobs may keep running afterward.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !canApprove {
                Text("This script review is no longer current. Close it and review the latest command.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let reviewError { Text(reviewError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).disabled(submitting)
                Spacer()
                Button(submitting ? "Starting…" : (role == .setup ? "Run Setup" : "Run Settle Script")) {
                    guard !submitting, canApprove else { return }; submitting = true; reviewError = nil
                    Task {
                        defer { submitting = false }
                        do { try await store.approveProjectScript(threadID: threadID, runID: plan.id, expectedPlan: plan); close() }
                        catch is CancellationError { }
                        catch { reviewError = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction).disabled(submitting || !canApprove)
                    .accessibilityIdentifier(identifier("run"))
            }
        }.padding(24).frame(width: 500).interactiveDismissDisabled(submitting)
    }
    private func identifier(_ suffix: String) -> String { (role == .setup ? "workspace-setup-" : "workspace-settle-script-") + suffix }
}

enum WorkspaceSetupPresentation {
    static func title(_ run: ThreadProjectScriptRun, role: ProjectScriptRole = .setup) -> String {
        if role == .settle {
            return switch run.phase {
            case .waitingForCheckout: String(localized: "Waiting for checkout…")
            case .discovering: String(localized: "Checking settle script…")
            case .awaitingApproval: String(localized: "Review settle script")
            case .starting: String(localized: "Starting settle script…")
            case .running: run.plan?.script.name ?? String(localized: "Running settle script…")
            case .succeeded: String(localized: "Settle script finished")
            case .failed: String(localized: "Settle script needs attention")
            case .interrupted: String(localized: "Settle script interrupted")
            case .stopping: String(localized: "Closing settle script…")
            case .cancelled: String(localized: "Settle script stopped")
            case .skipped: String(localized: "Settle script skipped")
            }
        }
        return switch run.phase {
        case .waitingForCheckout: String(localized: "Waiting for checkout…")
        case .discovering: String(localized: "Checking checkout setup…")
        case .awaitingApproval: String(localized: "Review checkout setup")
        case .starting: String(localized: "Starting checkout setup…")
        case .running: run.plan?.script.name ?? String(localized: "Running checkout setup…")
        case .succeeded: String(localized: "Checkout setup finished")
        case .failed: String(localized: "Checkout setup needs attention")
        case .interrupted: String(localized: "Checkout setup interrupted")
        case .stopping: String(localized: "Closing checkout setup…")
        case .cancelled: String(localized: "Checkout setup stopped")
        case .skipped: String(localized: "Checkout setup skipped")
        }
    }
    static func detail(_ run: ThreadProjectScriptRun, role: ProjectScriptRole = .setup) -> String {
        if let exit = run.commandExit {
            switch exit {
            case .exited(let code): return String(localized: "Command exited with status \(code).")
            case .signaled(let signal): return String(localized: "Command ended from signal \(signal).")
            }
        }
        if role == .settle { return String(localized: "The conversation stays settled. Resuming stops this script and its background jobs.") }
        if run.providerReleased { return String(localized: "Messages can continue while setup runs.") }
        if run.phase == .stopping { return String(localized: "Messages wait until its background jobs have stopped.") }
        return String(localized: "Messages wait for setup. Files and Terminal remain available.")
    }
    static func error(_ message: String, role: ProjectScriptRole) -> String {
        guard role == .settle else { return message }
        switch message {
        case ThreadProjectScriptRun.discoveryError: return String(localized: "The settle script configuration could not be read. Review t3.json or skip the settle script.")
        case ThreadProjectScriptRun.executionError: return String(localized: "The approved settle script could not be started or completed. Review its output before trying again.")
        case ThreadProjectScriptRun.interruptedError: return String(localized: "The app closed during the settle script. Review it before running again; it may already have made changes.")
        default: return message
        }
    }
}
