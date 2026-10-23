import CoincideCore
import CoincideTerminal
import SwiftUI

struct RemoteTerminalPanel: View {
    @Bindable var store: RemoteTerminalStore
    let hide: () -> Void
    @State private var pendingClose: RemoteTerminalTab?
    @AppStorage("terminalFontSize") private var fontSize = 12.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Menu("Workspaces") {
                    if store.canShowCurrentWorkspace { Button("Current Workspace") { store.showCurrentWorkspace() }; Divider() }
                    ForEach(store.workspaces.filter { !$0.tabs.isEmpty }) { workspace in
                        Button(workspace.target.workspacePath + " · " + String(workspace.target.threadID.uuidString.prefix(8))) { store.showRetained(workspace) }
                    }
                }.fixedSize().disabled(store.workspaces.allSatisfy { $0.tabs.isEmpty })
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(store.sessions) { tab in
                            HStack(spacing: 6) {
                                Button(tab.renderer.title) { store.current?.selectedID = tab.id }
                                    .foregroundStyle(store.selected?.id == tab.id ? .primary : .secondary).lineLimit(1).frame(maxWidth: 180)
                                if tab.isClosing || tab.preparingClose { ProgressView().controlSize(.mini) }
                                Button {
                                    Task { if !((await store.close(tab))) { pendingClose = tab } }
                                } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                .accessibilityLabel("Close \(tab.renderer.title)").disabled(tab.isClosing || tab.preparingClose)
                            }.padding(.horizontal, 8).padding(.vertical, 5)
                                .background(store.selected?.id == tab.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }.scrollIndicators(.hidden)
                Button { store.selected?.renderer.showFind() } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Find in remote terminal").disabled(store.selected == nil)
                Menu {
                    ForEach([10.0, 12.0, 14.0, 16.0, 18.0, 20.0], id: \.self) { size in
                        Button("\(Int(size)) pt") { fontSize = size }
                    }
                } label: { Image(systemName: "textformat.size") }.accessibilityLabel("Remote terminal text size")
                Button { Task { await store.newTerminal() } } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New remote terminal").disabled(!store.canOpen)
                Button(action: hide) { Image(systemName: "chevron.down") }.accessibilityLabel("Hide remote terminal")
            }.buttonStyle(.borderless).font(.caption).padding(.horizontal, 12).padding(.vertical, 6).coincideSurface(cornerRadius: 0)
            Divider()
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(8) }
            if let tab = store.selected {
                NativeRemoteTerminalView(session: tab.renderer, fontSize: fontSize).id(tab.renderer.displayGeneration).padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                VStack(alignment: .leading, spacing: 6) {
                    Text(tab.status).foregroundStyle(.secondary)
                    if let notice = tab.notice { Text(notice).textSelection(.enabled) }
                    if let error = tab.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    HStack {
                        if tab.openUnconfirmed {
                            Button("Inspect Open Result") { Task { await store.inspectOpenResult(tab) } }
                        } else if !tab.isAttached, tab.reference != nil {
                            Button("Attach to This Session") { Task { await store.attach(tab) } }
                        }
                        if tab.uncertainInput != nil { Button("Check Input Result") { Task { await store.checkInputResult(tab) } } }
                        Spacer()
                    }
                }.font(.caption).padding(8)
            } else {
                ContentUnavailableView {
                    Label("Remote Terminal", systemImage: "terminal")
                } description: {
                    Text("New Terminal starts a shell on the connected Mac. Reconnecting and showing this panel never restart a shell or repeat input.")
                } actions: {
                    Button("New Terminal") { Task { await store.newTerminal() } }.disabled(!store.canOpen)
                }
            }
        }
        .accessibilityIdentifier("remote-terminal-panel")
        .confirmationDialog("Close this remote terminal and stop its foreground command?", isPresented: Binding(get: { pendingClose != nil }, set: { visible in
            if !visible, let tab = pendingClose { store.cancelClose(tab); pendingClose = nil }
        })) {
            Button("Close Remote Terminal", role: .destructive) {
                let tab = pendingClose; pendingClose = nil
                if let tab { Task { await store.close(tab, confirmed: true) } }
            }
            Button("Cancel", role: .cancel) { if let tab = pendingClose { store.cancelClose(tab) }; pendingClose = nil }
        } message: {
            Text("Closing waits for this exact remote process to stop. Unconfirmed input will not be sent again.")
        }
    }
}

private struct NativeRemoteTerminalView: NSViewRepresentable {
    let session: RemoteTerminalSession
    let fontSize: Double
    func makeNSView(context: Context) -> NSView { session.setFontSize(fontSize); return session.view }
    func updateNSView(_ view: NSView, context: Context) { session.setFontSize(fontSize) }
}
