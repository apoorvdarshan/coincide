import CoincideCore
import SwiftUI

/// The `chat.find` bar. Return and Shift-Return step through matches; Escape closes.
struct ThreadFindBar: View {
    @Bindable var model: ThreadFindModel
    let close: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Find in thread", text: $model.query).textFieldStyle(.plain)
                .frame(minWidth: 120)
                .focused($focused)
                .accessibilityLabel("Find in thread").accessibilityIdentifier("thread-find-field")
                .onKeyPress(keys: [.return], phases: .down) { press in
                    press.modifiers.contains(.shift) ? model.previous() : model.next(); return .handled
                }
                .onKeyPress(.escape) { close(); return .handled }
            Text(model.status).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                .accessibilityIdentifier("thread-find-status")
            Button { model.previous() } label: { Image(systemName: "chevron.up") }
                .help("Previous match (⇧↩)").accessibilityLabel("Previous match").disabled(model.matches.isEmpty)
            Button { model.next() } label: { Image(systemName: "chevron.down") }
                .help("Next match (↩)").accessibilityLabel("Next match").disabled(model.matches.isEmpty)
            Button("Done", action: close).accessibilityIdentifier("thread-find-done")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .coincideSurface(cornerRadius: 12)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain).accessibilityIdentifier("thread-find")
        .onAppear { focused = true }
        .onChange(of: model.focusGeneration) { focused = true }
    }
}

/// Connects a window's find model to one transcript: shows the bar, keeps
/// matches current while messages stream, and scrolls to the current match.
struct ThreadFindScrolling: ViewModifier {
    let threadID: UUID
    let messages: [ChatMessage]
    let proxy: ScrollViewProxy
    @Environment(MainWindowController.self) private var controller: MainWindowController?

    func body(content: Content) -> some View {
        let find = controller?.find.flatMap { $0.threadID == threadID ? $0 : nil }
        // Only an open find bar observes transcript changes.
        let observed = find == nil ? [] : messages
        content
            .overlay(alignment: .top) {
                if let find, let controller {
                    ThreadFindBar(model: find, close: { controller.closeFind() }).padding(.top, 8).padding(.horizontal, 24)
                }
            }
            .onChange(of: observed, initial: true) { _, value in find?.update(messages: value) }
            .onChange(of: find?.scrollGeneration) {
                guard let id = find?.current?.messageID else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
    }
}

/// Tints a message row that contains find matches; the current match is stronger.
struct ThreadFindHighlight: ViewModifier {
    let messageID: String
    @Environment(MainWindowController.self) private var controller: MainWindowController?
    func body(content: Content) -> some View {
        let find = controller?.find
        let current = find?.current?.messageID == messageID
        let matched = current || find?.matchedMessageIDs.contains(messageID) == true
        content.background {
            if matched {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.yellow.opacity(current ? 0.22 : 0.08)).padding(-8)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func threadFind(threadID: UUID, messages: [ChatMessage], proxy: ScrollViewProxy) -> some View {
        modifier(ThreadFindScrolling(threadID: threadID, messages: messages, proxy: proxy))
    }
    func threadFindHighlight(_ messageID: String) -> some View { modifier(ThreadFindHighlight(messageID: messageID)) }
}
