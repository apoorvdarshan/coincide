import CoincideCore
import SwiftUI

struct QueuedTurnsView: View {
    var store: WorkspaceStore
    let thread: CodingThread
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(thread.queuedTurns.count) queued", systemImage: "text.badge.plus").font(.caption).foregroundStyle(.secondary)
                if thread.queuePaused { Text("Paused").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if thread.queuePaused && !thread.isBusy { Button("Resume Queue") { store.resumeQueue(thread.id) }.font(.caption) }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(thread.queuedTurns) { queued in
                        HStack(alignment: .top, spacing: 10) {
                            if let first = queued.attachments?.first { AttachmentThumbnail(store: store, attachment: first) }
                            VStack(alignment: .leading, spacing: 3) {
                                if !queued.text.isEmpty { Text(queued.text).font(.caption).lineLimit(2) }
                                if let files = queued.attachments, !files.isEmpty { Label("\(files.count) attachment\(files.count == 1 ? "" : "s")", systemImage: "paperclip").font(.caption2).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if thread.activeRun != nil {
                                Button {
                                    _ = store.steerQueued(queued.id, threadID: thread.id)
                                } label: { Image(systemName: "arrow.turn.up.right") }
                                    .help(store.canSteerQueued(queued, threadID: thread.id)
                                        ? "Send this queued message into the running turn"
                                        : "Keep this message queued to use its captured settings, or wait until the running turn can be steered")
                                    .accessibilityLabel("Steer queued message")
                                    .accessibilityIdentifier("steer-queued-\(queued.id.uuidString)")
                                    .disabled(!store.canSteerQueued(queued, threadID: thread.id))
                            }
                            Button { store.editQueued(queued.id, threadID: thread.id) } label: { Image(systemName: "pencil") }
                                .help("Edit queued message").accessibilityLabel("Edit queued message")
                            Button { store.removeQueued(queued.id, threadID: thread.id) } label: { Image(systemName: "xmark") }
                                .help("Remove queued message").accessibilityLabel("Remove queued message")
                        }.buttonStyle(.borderless)
                    }
                }
            }.frame(height: min(200, CGFloat(thread.queuedTurns.count) * (thread.queuedTurns.contains { !($0.attachments ?? []).isEmpty } ? 55 : 37)))
        }.padding(12).coincideSurface()
    }
}
