import AppKit
import CoincideCore
import SwiftUI

struct RemoteThreadActionsView: View {
    let store: RemoteWorkspaceStore
    var body: some View {
        if store.descriptor?.capabilities.supportsRemoteThreadActions == true {
            VStack(alignment: .leading, spacing: 8) {
                if let capture = store.threadActions.capture {
                    HStack {
                        Button(capture.expectedPinned ? "Unpin" : "Pin", systemImage: capture.expectedPinned ? "pin.slash" : "pin") {
                            Task { _ = await store.perform(.threadAction(.setPinned(capture: capture, value: !capture.expectedPinned))) }
                        }
                        Button(capture.expectedArchived ? "Unarchive" : "Archive", systemImage: capture.expectedArchived ? "arrow.uturn.backward" : "archivebox") {
                            Task { _ = await store.perform(.threadAction(.setArchived(capture: capture, value: !capture.expectedArchived))) }
                        }.disabled(capture.runID != nil).help(capture.runID == nil ? "Change conversation visibility" : "Stop the running turn before archiving, as in the native conversation list.")
                    }.buttonStyle(.borderless).disabled(!store.canWrite)
                    if capture.expectedArchived { Text("Archived. Drafts, uploaded references and transcript remain available; unarchive before sending.").font(.caption).foregroundStyle(.secondary) }
                }
                if let group = store.threadActions.group {
                    HStack(spacing: 12) {
                        Text("\(group.kind.title) \(group.count == 1 ? "conversation" : "\(group.count) conversations")").font(.callout)
                        Button("Undo") { _ = store.threadActions.undo(group) }.disabled(!store.canWrite)
                            .accessibilityIdentifier("remote-thread-action-undo")
                    }.padding(10).coincideSurface(cornerRadius: 12)
                }
                if let error = store.threadActions.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
struct RemoteThreadUndoWindowRegistration: NSViewRepresentable {
    let store: RemoteThreadActionsStore
    let dispatcher: KeyboardCommandDispatcher?
    func makeNSView(context: Context) -> RegistrationView { RegistrationView(store: store, dispatcher: dispatcher) }
    func updateNSView(_ view: RegistrationView, context: Context) { view.store = store; view.dispatcher = dispatcher; view.register() }
    static func dismantleNSView(_ view: RegistrationView, coordinator: ()) { view.unregister() }
    final class RegistrationView: NSView {
        weak var store: RemoteThreadActionsStore?
        weak var dispatcher: KeyboardCommandDispatcher?
        private weak var previousWindow: NSWindow?, previousStore: RemoteThreadActionsStore?, previousDispatcher: KeyboardCommandDispatcher?
        init(store: RemoteThreadActionsStore, dispatcher: KeyboardCommandDispatcher?) { self.store = store; self.dispatcher = dispatcher; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); register() }
        func register() {
            guard previousWindow !== window || previousStore !== store || previousDispatcher !== dispatcher else { return }
            unregister()
            guard let window, let store else { return }
            if let dispatcher { dispatcher.registerRemoteUndo(store, window: window) } else { store.bind(window: window) }
            previousWindow = window; previousStore = store; previousDispatcher = dispatcher
        }
        func unregister() {
            if let window = previousWindow, let store = previousStore {
                if let dispatcher = previousDispatcher { dispatcher.unregisterRemoteUndo(store, window: window) } else { store.unbind(window: window) }
            }
            previousWindow = nil; previousStore = nil; previousDispatcher = nil
        }
    }
}
