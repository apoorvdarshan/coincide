import CoincideRemoteKit
import SwiftUI

/// A whole settings document, such as an instruction file, edited as text and saved back to the Mac. A save the Mac
/// refuses because the file changed there since it was opened never overwrites that change: the editor offers to copy
/// the edits and load the Mac's version.
struct SettingsDocumentEditor: View {
    let key: String
    let title: String
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var document: RemoteSettingsDocument?
    @State private var text = ""
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var conflict: String?
    @State private var confirmsDiscard = false
    @FocusState private var focused: Bool

    private var isDirty: Bool { document.map { $0.text != text } ?? false }

    var body: some View {
        Group {
            if document != nil {
                TextEditor(text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.ink)
                    .tint(theme.accent)
                    .scrollContentBackground(.hidden)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .accessibilityLabel(Text(title))
            } else if let loadError {
                ContentUnavailableView {
                    Label("Couldn’t Open the File", systemImage: "doc.questionmark")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.glass)
                }
                .foregroundStyle(theme.secondaryInk)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.content)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isDirty)
        .toolbar {
            if isDirty {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { confirmsDiscard = true }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save() } }
                        .disabled(!isDirty || !client.isConnected || text.count > RemoteSettingsDocument.maxLength)
                        .keyboardShortcut("s")
                }
            }
        }
        .task { if document == nil { await load() } }
        .confirmationDialog("Discard your changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) {
                text = document?.text ?? text
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        }
        .alert(
            "Changed on Your Mac", isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } })
        ) {
            Button("Copy My Edits and Reload") {
                UIPasteboard.general.string = text
                Task { await load() }
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text(conflict ?? "")
        }
    }

    private func load() async {
        loadError = nil
        do {
            let loaded = try await client.settingsDocument(key)
            document = loaded
            text = loaded.text
        } catch {
            loadError = (error as? RemoteError)?.message ?? error.localizedDescription
        }
    }

    private func save() async {
        guard var edited = document else { return }
        edited.text = text
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await client.saveSettingsDocument(edited)
            document = saved
            text = saved.text
            client.notice = String(localized: "Saved on your Mac.")
        } catch let error as RemoteError where error.code == .conflict {
            conflict = error.message
        } catch let error as RemoteError where error.code == .unsupported {
            client.notice = String(localized: "Update Coincide on your Mac to do this from here.")
        } catch {
            client.notice = (error as? RemoteError)?.message ?? error.localizedDescription
        }
    }
}
