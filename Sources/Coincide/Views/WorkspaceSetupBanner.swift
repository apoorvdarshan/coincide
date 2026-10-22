import CoincideCore
import SwiftUI

/// Presentation subscribes to the app-owned job; closing a window never owns its lifetime.
struct WorkspaceSetupBanner: View {
    let store: WorkspaceStore
    let threadID: UUID
    let run: ThreadProjectScriptRun
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
                            Text(WorkspaceSetupPresentation.title(run)).font(.callout.weight(.medium))
                                .accessibilityIdentifier("workspace-setup-status")
                            Text(WorkspaceSetupPresentation.detail(run)).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    if let message = actionError ?? run.error {
                        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("workspace-setup-error")
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { actionButtons }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 8) { actionButtons }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .controlSize(.small).disabled(actionPending || run.phase == .stopping)
                    if let output, !output.text.isEmpty {
                        DisclosureGroup("Setup Output", isExpanded: $outputExpanded) {
                            ScrollView {
                                Text(output.text).font(.caption.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .accessibilityIdentifier("workspace-setup-output")
                            }.frame(maxHeight: 130)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            if output.truncated {
                                Text("Showing recent output.").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.font(.caption).accessibilityIdentifier("workspace-setup-output-disclosure")
                    }
                }
                .padding(12).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain).accessibilityIdentifier("workspace-setup")
            }
        }
        .sheet(item: $reviewing) { plan in
            WorkspaceSetupReviewSheet(store: store, threadID: threadID, plan: plan, close: { reviewing = nil })
        }
        .onChange(of: run.id) { output = nil; actionError = nil; reviewing = nil; outputExpanded = false }
        .onChange(of: run.phase) { if !run.canApprove { reviewing = nil } }
        .task(id: run.id) {
            do {
                let stream = try await store.projectScriptOutput(threadID: threadID, runID: run.id)
                for await value in stream {
                    guard !Task.isCancelled, value.runID == run.id,
                          store.thread(threadID)?.workspacePreparation?.setup?.id == value.runID else { return }
                    output = value
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { actionError = error.localizedDescription } }
        }
    }
    @ViewBuilder private var actionButtons: some View {
        if run.canApprove, let plan = run.plan {
            Button("Review Setup…") { reviewing = plan }
                .accessibilityIdentifier("workspace-setup-review")
        }
        if canStop {
            Button(run.commandExit == nil ? "Stop Setup" : "Stop Background Jobs") {
                perform { try await store.stopProjectScript(threadID: threadID, runID: run.id) }
            }.accessibilityIdentifier("workspace-setup-stop")
        }
        if run.canRetry {
            Button("Review Again") { perform { try await store.retryProjectScript(threadID: threadID, runID: run.id) } }
                .accessibilityIdentifier("workspace-setup-retry")
        }
        if run.canSkip {
            Button("Continue Without Setup") { perform { try await store.skipProjectScript(threadID: threadID, runID: run.id) } }
                .accessibilityIdentifier("workspace-setup-skip")
        }
    }
    private var canStop: Bool {
        [.starting, .running, .succeeded, .failed].contains(run.phase) && run.plan != nil && output?.isClosed != true
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
    @State private var submitting = false
    @State private var reviewError: String?
    private var canApprove: Bool {
        let current = store.thread(threadID)?.workspacePreparation?.setup
        return current?.id == plan.id && current?.canApprove == true && current?.plan == plan
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run Checkout Setup?").font(.title2)
            Text(plan.script.name).font(.headline).lineLimit(2)
            Text("Review this command from the checkout’s t3.json. It runs with your account’s access to files and network.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(plan.workspacePath).font(.caption.monospaced()).textSelection(.enabled)
                .lineLimit(3).truncationMode(.middle).accessibilityIdentifier("workspace-setup-review-cwd")
            ScrollView {
                Text(plan.script.command).font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }.frame(minHeight: 70, maxHeight: 160)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("workspace-setup-review-command")
            Text(plan.script.runsAsynchronously
                 ? "Messages can start once this command starts. Background jobs remain available until stopped or the app quits."
                 : "Messages wait for this command to exit successfully. Background jobs may keep running afterward.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !canApprove {
                Text("This setup review is no longer current. Close it and review the latest setup.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let reviewError { Text(reviewError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).disabled(submitting)
                Spacer()
                Button(submitting ? "Starting…" : "Run Setup") {
                    guard !submitting, canApprove else { return }; submitting = true; reviewError = nil
                    Task {
                        defer { submitting = false }
                        do { try await store.approveProjectScript(threadID: threadID, runID: plan.id, expectedPlan: plan); close() }
                        catch is CancellationError { }
                        catch { reviewError = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction).disabled(submitting || !canApprove)
                    .accessibilityIdentifier("workspace-setup-run")
            }
        }.padding(24).frame(width: 500).interactiveDismissDisabled(submitting)
    }
}

enum WorkspaceSetupPresentation {
    static func title(_ run: ThreadProjectScriptRun) -> String {
        switch run.phase {
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
    static func detail(_ run: ThreadProjectScriptRun) -> String {
        if let exit = run.commandExit {
            switch exit {
            case .exited(let code): return String(localized: "Command exited with status \(code).")
            case .signaled(let signal): return String(localized: "Command ended from signal \(signal).")
            }
        }
        if run.providerReleased { return String(localized: "Messages can continue while setup runs.") }
        if run.phase == .stopping { return String(localized: "Messages wait until its background jobs have stopped.") }
        return String(localized: "Messages wait for setup. Files and Terminal remain available.")
    }
}
