import CoincideCore
import CoincideTerminal
import SwiftUI

struct TerminalPanel: View {
    var terminals: TerminalWorkspaceStore
    let thread: CodingThread
    let report: (String) -> Void
    let hide: () -> Void
    @State private var pendingClose: LocalTerminalSession?
    private var sessions: [LocalTerminalSession] { terminals.sessions[thread.id, default: []] }
    private var selected: LocalTerminalSession? { sessions.first { $0.id == terminals.selection[thread.id] } ?? sessions.first }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(sessions) { session in
                            HStack(spacing: 6) {
                                Button(session.title) { terminals.selection[thread.id] = session.id }
                                    .foregroundStyle(selected?.id == session.id ? .primary : .secondary)
                                    .lineLimit(1).frame(maxWidth: 180)
                                Button {
                                    if session.hasForegroundCommand { pendingClose = session }
                                    else { terminals.close(session, threadID: thread.id) }
                                } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                .help("Close terminal").accessibilityLabel("Close \(session.title)")
                            }.padding(.horizontal, 8).padding(.vertical, 5)
                                .background(selected?.id == session.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }.scrollIndicators(.hidden)
                Button { add() } label: { Image(systemName: "plus") }.help("New terminal").accessibilityLabel("New terminal")
                Button(action: hide) { Image(systemName: "chevron.down") }.help("Hide terminal").accessibilityLabel("Hide terminal")
            }.buttonStyle(.borderless).font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if let selected {
                NativeTerminalView(session: selected).id(selected.id).padding(6)
                if case .exited(let status) = selected.lifecycle {
                    HStack { Text(status.map { "Shell exited (\($0))." } ?? "Shell stopped."); Spacer(); Button("New Terminal") { add() } }
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                } else if case .failed(let message) = selected.lifecycle {
                    Text(message).font(.caption).foregroundStyle(.secondary).padding(8)
                }
            } else {
                ContentUnavailableView { Label("Terminal", systemImage: "terminal") }
                actions: { Button("New Terminal") { add() } }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { if sessions.isEmpty { add() } }
        .confirmationDialog("Close terminal and stop its running command?", isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } })) {
            Button("Close Terminal", role: .destructive) {
                if let pendingClose { terminals.close(pendingClose, threadID: thread.id) }; pendingClose = nil
            }
            Button("Cancel", role: .cancel) { pendingClose = nil }
        }
    }
    private func add() { do { try terminals.add(for: thread) } catch { report(error.localizedDescription) } }
}

private struct NativeTerminalView: NSViewRepresentable {
    let session: LocalTerminalSession
    func makeNSView(context: Context) -> NSView { session.view }
    func updateNSView(_ view: NSView, context: Context) {}
}
