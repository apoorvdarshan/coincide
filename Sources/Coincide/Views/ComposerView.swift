import CoincideCore
import SwiftUI

struct ComposerView: View {
    @Binding var text: String
    let models: [ProviderModel]
    let model: String
    let permission: PermissionMode
    let busy: Bool
    let setModel: (String) -> Void
    let setPermission: (PermissionMode) -> Void
    let refreshModels: () -> Void
    let send: () -> Void
    let stop: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            TextEditor(text: $text).font(.body).frame(minHeight: 65, maxHeight: 150)
                .scrollContentBackground(.hidden).accessibilityLabel("Message to Codex")
            HStack {
                Menu {
                    Button("Provider default") { setModel("") }
                    ForEach(models) { entry in Button(entry.name) { setModel(entry.id) } }
                    Divider(); Button("Refresh Models", action: refreshModels)
                } label: { Label(model.isEmpty ? "Codex · Default model" : model, systemImage: "cpu") }
                .disabled(busy)
                Picker("Permissions", selection: Binding(get: { permission }, set: { setPermission($0) })) {
                    ForEach(PermissionMode.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(maxWidth: 180).disabled(busy)
                Spacer()
                if busy {
                    Button(action: stop) { Label("Stop", systemImage: "stop.fill") }
                } else {
                    Button(action: send) { Label("Send", systemImage: "arrow.up") }.keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.controlSize(.small)
        }.padding(16)
    }
}
