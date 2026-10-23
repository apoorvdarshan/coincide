import CoincideCore
import SwiftUI

struct QueuedInputEditorView: View {
    let store: WorkspaceStore
    let editor: QueuedInputEditor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Queued Message").font(.headline)
            Text("Changes replace this queued input in place. Your unsent draft and the queued provider settings stay intact.").font(.caption).foregroundStyle(.secondary)
            if !editor.attachments.isEmpty { AttachmentShelf(store: store, attachments: editor.attachments, remove: { id in editor.attachments.removeAll { $0.id == id } }) }
            TextEditor(text: Binding(get: { editor.text }, set: { editor.text = $0 })).font(.body).frame(minHeight: 150, maxHeight: 320)
                .accessibilityLabel("Edit queued message text").disabled(editor.isSaving)
            if let error = editor.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Attach Files…") { store.chooseQueuedInputAttachments(editor) }.disabled(editor.isSaving || !editor.imports.isEmpty)
                Spacer()
                Button("Cancel") { store.closeQueuedInputEditor(editor) }.disabled(editor.isSaving).keyboardShortcut(.cancelAction)
                Button("Save Queued Message") { store.saveQueuedInputEditor(editor) }.disabled(!editor.canSave).keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 640)
        .onDisappear { store.closeQueuedInputEditor(editor) }
    }
}
