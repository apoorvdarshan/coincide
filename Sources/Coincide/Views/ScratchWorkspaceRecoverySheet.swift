import CoincideCore
import SwiftUI

struct ScratchWorkspaceRecoverySheet: View {
    let store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ScratchWorkspaceRecovery] = []
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var offset = 0
    private let limit = 64
    @State private var pendingDiscard: ScratchWorkspaceRecovery?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Saved Scratch Allocations").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() } }
            Text("Scratch conversations use private folders without Git or setup scripts. Their files stay on this Mac when you settle, archive, or close the app.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Check Result inspects the original saved command. It never resends an input. Discard only removes a verified empty allocation after its original command is known not to have created a conversation.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let notice { Text(notice).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if rows.isEmpty, !loading { Text("No saved scratch allocations.").foregroundStyle(.secondary) }
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.allocation?.receipt.folderName ?? String(localized: "Interrupted allocation")).font(.headline).textSelection(.enabled)
                            Text(phase(row.phase)).font(.caption).foregroundStyle(.secondary)
                            if let path = row.allocation?.workspacePath { Text(path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3) }
                            HStack {
                                if row.phase == .accepted { Button("Open Conversation") { store.openRecoveredScratchConversation(row); dismiss() } }
                                Button("Check Result") { Task { await refresh() } }.disabled(loading)
                                if [.prepared, .uncertain, .rejected].contains(row.phase), row.allocation != nil {
                                    Button("Discard Empty Allocation…") { pendingDiscard = row }.disabled(loading)
                                }
                            }.controlSize(.small)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.frame(minHeight: 180)
            HStack {
                if loading { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await refresh() } }.disabled(loading)
                if offset > 0 { Button("Previous Allocations") { offset = max(0, offset - limit); Task { await refresh() } }.disabled(loading) }
                if rows.count == limit { Button("Next Allocations") { offset += limit; Task { await refresh() } }.disabled(loading) }
                Spacer()
            }
        }.padding(24).frame(minWidth: 420, idealWidth: 600, minHeight: 420, idealHeight: 560)
        .task { await refresh() }
        .confirmationDialog("Resolve the saved request and discard this empty allocation?", isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }), titleVisibility: .visible) {
            Button("Check and Discard", role: .destructive) {
                guard let row = pendingDiscard else { return }; pendingDiscard = nil
                Task {
                    loading = true; defer { loading = false }
                    do {
                        let removed = try await store.discardEmptyScratchAllocation(row.id)
                        notice = removed ? String(localized: "The unused allocation was discarded. No input was resent.") : String(localized: "The folder contains files or no longer matches its ownership proof. It was preserved.")
                    } catch { self.error = error.localizedDescription }
                    await refresh()
                }
            }
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
        } message: { Text("An accepted conversation keeps its folder. An uncertain original command is checked and atomically refused only if it never committed. Folders containing user files are always preserved.") }
    }
    @MainActor private func refresh() async {
        guard !Task.isCancelled else { return }
        loading = true; defer { loading = false }
        do { let values = try await store.scratchWorkspaceRecoveries(limit: limit, offset: offset); guard !Task.isCancelled else { return }; rows = values; error = nil }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func phase(_ value: ScratchWorkspaceRecoveryPhase) -> String {
        switch value {
        case .prepared: String(localized: "Folder allocated; no creation command was sent.")
        case .uncertain: String(localized: "The original creation result is not confirmed. Check Result before taking another action.")
        case .accepted: String(localized: "Conversation created. Its folder is retained.")
        case .acceptedHistoryPending: String(localized: "The history request was accepted, but its conversation has not been registered. Inspect the source conversation’s history action; no provider work is replayed.")
        case .rejected: String(localized: "Original creation was refused. Its folder is retained until explicit empty cleanup.")
        case .cancelled: String(localized: "Allocation discarded. Any files that prevented removal were preserved.")
        case .incomplete: String(localized: "Allocation interrupted before folder ownership was sealed. No automatic cleanup is permitted.")
        }
    }
}
