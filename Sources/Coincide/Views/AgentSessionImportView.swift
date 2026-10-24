import CoincideCore
import SwiftUI

struct AgentSessionImportView: View {
    let store: AgentSessionImportStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Import Agent Projects").font(.title2.bold())
                Spacer()
                Button("Done") { store.requestPause(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Copy saved Codex and Claude conversations into Coincide. Replies use a separate session, leaving the original CLI conversation unchanged. You can switch agents in the copied chat.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(store.scanResult == nil ? "Scan Local Projects" : "Scan Again") { store.scan() }
                    .disabled(!store.isLoaded || store.isBusy || store.pending != nil)
                if store.isScanning { ProgressView().controlSize(.small) }
                Spacer()
                if let scan = store.scanResult { Text("\(scan.candidates.count) projects found").font(.caption).foregroundStyle(.secondary) }
            }
            if let scan = store.scanResult, !scan.candidates.isEmpty {
                List(selection: Binding(get: { store.selectedCandidateID }, set: { store.selectedCandidateID = $0 })) {
                    ForEach(scan.candidates) { candidate in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(candidate.title).fontWeight(.medium)
                                if candidate.alreadyImported { Text("Project already added").font(.caption2).foregroundStyle(.secondary) }
                                Spacer()
                                Text("\(candidate.threadCount) saved conversations").font(.caption)
                            }
                            Text(candidate.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            HStack {
                                Text(candidate.sources.map { $0 == .codex ? "Codex" : "Claude" }.joined(separator: " · "))
                                if let date = candidate.lastActiveAt { Text(date, style: .relative) }
                            }.font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 4).tag(candidate.id)
                    }
                }.frame(minHeight: 150, idealHeight: 260, maxHeight: 350).disabled(store.isBusy || store.pending != nil)
                if scan.truncated { Text("The scan reached its bounded discovery limit. Only the projects listed above were inspected.").font(.caption).foregroundStyle(.secondary) }
            } else if store.isLoaded && !store.isScanning {
                ContentUnavailableView("Choose Local Projects", systemImage: "square.and.arrow.down", description: Text("Scanning is explicit. No conversations or provider sessions are started."))
                    .frame(height: 150)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(store.status).font(.callout)
                if let title = store.projectTitle { Text(title).font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 15) {
                    Text("\(store.progress.imported) imported")
                    Text("\(store.progress.alreadyImported) already imported")
                    Text("\(store.progress.duplicates) duplicates")
                    Text("\(store.progress.skipped) skipped")
                    if store.progress.failed > 0 { Text("\(store.progress.failed) refused") }
                }.font(.caption).foregroundStyle(.secondary)
                if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            HStack {
                Text("Imports up to 100 recent conversations per project, with bounded retained history. Original files are never rewritten.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if store.pending != nil {
                    Button("Check Result") { store.checkResult() }.disabled(store.isBusy).accessibilityIdentifier("agent-session-import-check-result")
                } else if store.isImporting {
                    Button("Pause Import") { store.requestPause() }
                } else {
                    Button("Import Selected Project") { store.importSelected() }
                        .buttonStyle(.borderedProminent).disabled(!store.scanAvailable || store.selectedCandidate == nil || store.isBusy)
                        .accessibilityIdentifier("agent-session-import-selected")
                }
            }
        }.padding(24).frame(minWidth: 640, idealWidth: 760, maxWidth: 900)
        .task { await store.open() }
        .onDisappear { store.requestPause() }
    }
}
