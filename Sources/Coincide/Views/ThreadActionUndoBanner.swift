import CoincideCore
import SwiftUI

struct ThreadActionUndoBanner: View {
    let controller: MainWindowController
    var body: some View {
        let claims = controller.store.threadActionUndo.group(ownerID: controller.undoOwnerID)
        if let first = claims.first {
            HStack(spacing: 12) {
                Text("\(first.kind.title) \(first.kind == .discard ? (claims.count == 1 ? "draft" : "\(claims.count) drafts") : (claims.count == 1 ? "conversation" : "\(claims.count) conversations"))")
                    .font(.callout)
                Button("Undo") { controller.undoLatestThreadAction(expectedIDs: claims.map(\.id)) }
                    .disabled(!controller.canHandleInteraction)
                    .accessibilityIdentifier("thread-action-undo")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .coincideSurface(cornerRadius: 12)
            .help(first.kind == .settle ? "Resume the conversation. File changes and script output are kept." : "Restore the previous conversation action.")
            .accessibilityIdentifier("thread-action-undo-notice")
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
