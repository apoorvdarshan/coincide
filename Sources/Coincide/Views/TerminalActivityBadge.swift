import CoincideCore
import SwiftUI

/// A sidebar row status for conversations whose terminals are running a process
/// (T3's "Terminal process running" indicator). Opens that conversation's terminal.
struct TerminalActivityBadge: View {
    var store: WorkspaceStore
    let threadID: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let count = store.runningTerminalCount(threadID: threadID)
        if count > 0 {
            Button { store.showTerminals(threadID: threadID) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal").symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                    Text(count == 1 ? String(localized: "Terminal running") : String(localized: "\(count) terminals running"))
                }
                .font(.caption).foregroundStyle(.teal)
            }
            .buttonStyle(.plain)
            .help(Self.label(count))
            .accessibilityLabel(Self.label(count))
            .accessibilityIdentifier("thread-terminal-activity-\(threadID.uuidString)")
        }
    }

    static func label(_ count: Int) -> String {
        count == 1 ? String(localized: "1 terminal process running. Open terminal")
                   : String(localized: "\(count) terminal processes running. Open terminal")
    }
}
