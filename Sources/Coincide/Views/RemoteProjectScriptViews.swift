import CoincideCore
import SwiftUI

struct RemoteProjectScriptPanel: View {
    @Bindable var store: RemoteProjectScriptStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let state = store.state {
                Label(RemoteProjectScriptPresentation.title(state.phase), systemImage: state.phase == .succeeded ? "checkmark.circle" : "terminal")
                    .font(.callout.weight(.medium)).accessibilityIdentifier("remote-settle-script-status")
                Text("The conversation stays settled. Resume stops this script's background jobs before queued messages continue.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let exit = state.commandExit { Text(RemoteProjectScriptPresentation.exit(exit)).font(.caption).foregroundStyle(.secondary) }
                if let error = state.error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions(state) }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) { actions(state) }
                }.controlSize(.small)
                DisclosureGroup("Settle Script Output", isExpanded: Binding(get: { store.outputVisible }, set: { store.setOutputVisible($0) })) {
                    if let output = store.output {
                        if !store.connected {
                            Text("Saved display from the previous connection. Reconnect to inspect current state.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        switch output.retention {
                        case .notStarted: Text("This attempt has not started producing output.").font(.caption).foregroundStyle(.secondary)
                        case .notRetained: Text("Output from the earlier helper was not retained. The script was not run again.").font(.caption).foregroundStyle(.secondary)
                        case .retained:
                            if output.text.isEmpty { Text(output.isClosed ? "This attempt produced no captured output." : "Waiting for output…").font(.caption).foregroundStyle(.secondary) }
                            else {
                                ScrollView {
                                    Text(output.text).font(.caption.monospaced()).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                        .accessibilityIdentifier("remote-settle-script-output")
                                }.frame(maxHeight: 170).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        if output.truncated { Text("Showing recent output. Earlier output is omitted.").font(.caption2).foregroundStyle(.secondary) }
                    } else { Text("Load this attempt's bounded output.").font(.caption).foregroundStyle(.secondary) }
                    if let error = store.outputError { Text(error).font(.caption).foregroundStyle(.red) }
                    Button("Refresh Output") { Task { await store.refreshOutput() } }.controlSize(.small).disabled(!store.canRead)
                }.font(.caption).accessibilityIdentifier("remote-settle-script-output-disclosure")
            } else if store.isLoading { ProgressView("Checking settle script…").controlSize(.small) }
            else if store.canRead { Text("No settle script is attached to this generation.").font(.caption).foregroundStyle(.secondary) }
            if let message = store.unavailableMessage { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Button("Refresh Script") { Task { await store.refreshPresentation() } }
                .controlSize(.small).disabled(!store.canRead || store.isLoading)
                .accessibilityIdentifier("remote-settle-script-refresh")
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).coincideSurface()
        .accessibilityElement(children: .contain).accessibilityIdentifier("remote-settle-script-panel")
        .onAppear { store.startPresentation() }
        .onDisappear { store.endPresentation() }
        .onChange(of: store.presentationID) { store.startPresentation() }
        .sheet(item: Binding(get: { store.review }, set: { if $0 == nil { store.closeReview() } })) { value in
            RemoteProjectScriptReviewSheet(store: store, value: value)
        }
    }
    @ViewBuilder private func actions(_ state: RemoteProjectScriptState) -> some View {
        if state.canApprove {
            Button(store.isReviewing ? "Loading Full Command…" : "Review Settle Script…") { Task { await store.beginReview() } }
                .disabled(!store.canAct || store.isReviewing).accessibilityIdentifier("remote-settle-script-review")
        }
        if state.canStop {
            Button(state.commandExit == nil ? "Stop Settle Script" : "Stop Background Jobs") { Task { _ = await store.stop(state) } }
                .disabled(!store.canAct).accessibilityIdentifier("remote-settle-script-stop")
        }
        if state.canRetry {
            Button("Review Again") { Task { _ = await store.retry(state) } }
                .disabled(!store.canAct).accessibilityIdentifier("remote-settle-script-retry")
        }
        if state.canSkip {
            Button("Skip Settle Script") { Task { _ = await store.skip(state) } }
                .disabled(!store.canAct).accessibilityIdentifier("remote-settle-script-skip")
        }
    }
}

struct RemoteProjectScriptReviewSheet: View {
    @Bindable var store: RemoteProjectScriptStore
    let value: RemoteProjectScriptLoadedReview
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Run Remote Settle Script?").font(.title2)
            Text(value.name).font(.headline).lineLimit(3)
            Text("Review the complete command from this remote checkout's t3.json. It runs on the remote machine with that account's file and network access.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledContent("Shell") { Text(value.review.shellPath).font(.caption.monospaced()).textSelection(.enabled) }
            LabeledContent("Working directory") { Text(value.review.workspacePath).font(.caption.monospaced()).textSelection(.enabled) }
            LabeledContent("Project root") { Text(value.review.projectRoot).font(.caption.monospaced()).textSelection(.enabled) }
            ScrollView {
                Text(value.command).font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .accessibilityIdentifier("remote-settle-script-review-command")
            }.frame(minHeight: 90, maxHeight: 220).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text("The conversation remains settled when this command exits. Background jobs remain owned until stopped or the conversation resumes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !store.canApprove { Text("This exact review is no longer current. Close it and review the latest attempt.").font(.caption).foregroundStyle(.secondary) }
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel") { store.closeReview() }.keyboardShortcut(.cancelAction).disabled(store.isActing)
                Spacer()
                Button(store.isActing ? "Starting…" : "Run Settle Script") {
                    Task { if await store.approve(value) { store.closeReview() } }
                }.keyboardShortcut(.defaultAction).disabled(!store.canApprove)
                    .accessibilityIdentifier("remote-settle-script-approve")
            }
        }.padding(24).frame(width: 520).interactiveDismissDisabled(store.isActing)
    }
}

enum RemoteProjectScriptPresentation {
    static func title(_ phase: ThreadProjectScriptRunPhase) -> String {
        switch phase {
        case .waitingForCheckout: String(localized: "Waiting for checkout…")
        case .discovering: String(localized: "Checking settle script…")
        case .awaitingApproval: String(localized: "Review settle script")
        case .starting: String(localized: "Starting settle script…")
        case .running: String(localized: "Settle script running")
        case .succeeded: String(localized: "Settle script finished")
        case .failed: String(localized: "Settle script needs attention")
        case .interrupted: String(localized: "Settle script interrupted")
        case .stopping: String(localized: "Stopping settle script…")
        case .cancelled: String(localized: "Settle script stopped")
        case .skipped: String(localized: "Settle script skipped")
        }
    }
    static func exit(_ value: ProjectScriptCommandExit) -> String {
        switch value { case .exited(let code): String(localized: "Command exited with status \(code).")
        case .signaled(let signal): String(localized: "Command ended from signal \(signal).") }
    }
}
