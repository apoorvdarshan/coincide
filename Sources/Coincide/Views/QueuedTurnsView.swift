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
                            Text(queued.text).font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            Button { store.editQueued(queued.id, threadID: thread.id) } label: { Image(systemName: "pencil") }
                                .help("Edit queued message").accessibilityLabel("Edit queued message")
                            Button { store.removeQueued(queued.id, threadID: thread.id) } label: { Image(systemName: "xmark") }
                                .help("Remove queued message").accessibilityLabel("Remove queued message")
                        }.buttonStyle(.borderless)
                    }
                }
            }.frame(height: min(150, CGFloat(thread.queuedTurns.count) * 37))
        }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}
