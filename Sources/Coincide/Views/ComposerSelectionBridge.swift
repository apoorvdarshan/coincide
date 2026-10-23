import AppKit
import SwiftUI

struct ComposerSelectionRequest: Equatable {
    let id = UUID()
    let text: String
    let range: NSRange
}

/// SwiftUI exposes TextEditor selection only on macOS 15+. This observer keeps
/// the existing editor, delegate, undo, input methods and paste handling intact.
/// It observes only the editable NSTextView in this editor's local view tree.
struct ComposerSelectionBridge: NSViewRepresentable {
    let request: ComposerSelectionRequest?
    let selectionChanged: @MainActor (String, NSRange) -> Void
    let keyDown: @MainActor (NSEvent) -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor(); anchor.moved = { [weak coordinator = context.coordinator] in coordinator?.scheduleAttach() }
        context.coordinator.anchor = anchor; return anchor
    }
    func updateNSView(_ view: Anchor, context: Context) {
        context.coordinator.parent = self; context.coordinator.scheduleAttach()
    }
    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) { view.moved = nil; coordinator.detach() }
    final class Anchor: NSView {
        var moved: (() -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); moved?() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); moved?() }
        override func layout() { super.layout(); moved?() }
    }
    @MainActor final class Coordinator {
        var parent: ComposerSelectionBridge
        weak var anchor: Anchor?
        weak var editor: NSTextView?
        private var observations: [NSObjectProtocol] = []
        private var monitor: Any?
        private var scheduled = false
        private var detached = false
        private var appliedRequest: UUID?
        init(_ parent: ComposerSelectionBridge) { self.parent = parent }
        func scheduleAttach() {
            guard !detached, !scheduled else { return }; scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.detached else { return }; self.scheduled = false; self.attach()
            }
        }
        private func attach() {
            if editor?.window !== anchor?.window { stopObserving(); editor = nil }
            if editor == nil, let anchor {
                var ancestor = anchor.superview
                for _ in 0..<7 {
                    guard let view = ancestor else { break }
                    let candidates = Self.editors(in: view, depth: 0)
                    if candidates.count == 1 { editor = candidates[0]; break }
                    if candidates.count > 1 { break }
                    ancestor = view.superview
                }
                if let editor {
                    for name in [NSTextView.didChangeSelectionNotification, NSText.didChangeNotification] {
                        observations.append(NotificationCenter.default.addObserver(forName: name, object: editor, queue: .main) { [weak self] _ in
                            MainActor.assumeIsolated { self?.publish() }
                        })
                    }
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak editor] event in
                        let handled = MainActor.assumeIsolated {
                            guard let self, let editor, event.window === editor.window,
                                  editor.window?.firstResponder === editor, !editor.hasMarkedText() else { return false }
                            return self.parent.keyDown(event)
                        }
                        return handled ? nil : event
                    }
                }
            }
            guard let editor else { return }
            if let request = parent.request, request.id != appliedRequest, editor.string.utf8.elementsEqual(request.text.utf8),
               ComposerUTF16Selection.isValid(request.range, in: editor.string) {
                appliedRequest = request.id; editor.setSelectedRange(request.range)
                editor.window?.makeFirstResponder(editor); editor.scrollRangeToVisible(request.range)
            }
            publish()
        }
        private static func editors(in view: NSView, depth: Int) -> [NSTextView] {
            if let editor = view as? NSTextView { return editor.isEditable ? [editor] : [] }
            guard depth < 10 else { return [] }
            return view.subviews.flatMap { editors(in: $0, depth: depth + 1) }
        }
        private func publish() {
            guard let editor else { return }; parent.selectionChanged(editor.string, editor.selectedRange())
        }
        private func stopObserving() {
            for token in observations { NotificationCenter.default.removeObserver(token) }; observations.removeAll()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
        func detach() { detached = true; stopObserving(); editor = nil; anchor = nil }
    }
}
