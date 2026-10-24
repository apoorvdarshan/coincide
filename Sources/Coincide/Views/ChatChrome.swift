import AppKit
import SwiftUI

/// Flat, adaptive surfaces matching the chat reference rather than a glass dashboard.
enum ChatChrome {
    static let canvas = color(light: 0.99, dark: 0.065)
    static let sidebar = color(light: 0.955, dark: 0.115)
    static let composer = color(light: 0.945, dark: 0.125)
    static let footer = color(light: 0.965, dark: 0.095)
    private static func color(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
        })
    }
}

struct WorkspaceRail: View {
    @Bindable var store: WorkspaceStore
    let toggleTerminal: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            item("New chat", icon: "square.and.pencil", selected: !store.showingSettings) {
                store.showingSettings = false; store.newThread()
            }
            item("Projects and recent chats", icon: "sidebar.left", selected: false) {
                store.showingSettings = false; store.sidebarVisible.toggle()
            }
            item("Files and changes", icon: "folder", selected: store.inspectorVisible) {
                store.showingSettings = false; store.inspectorVisible.toggle()
            }
            item("Terminal", icon: "terminal", selected: false, action: toggleTerminal)
                .disabled(store.selectedThread == nil)
            Spacer()
            item("Settings", icon: "gearshape", selected: store.showingSettings) { store.showingSettings.toggle() }
        }
        .padding(.vertical, 16).frame(width: 52).background(ChatChrome.canvas)
    }
    private func item(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .regular))
                .frame(width: 36, height: 36)
                .background(selected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).foregroundStyle(.secondary).help(title).accessibilityLabel(title)
    }
}
