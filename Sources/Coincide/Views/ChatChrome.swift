import AppKit
import SwiftUI

/// Flat, adaptive surfaces matching the chat reference rather than a glass dashboard.
enum ChatChrome {
    static let canvas = color(light: 0.99, dark: 0.09)
    static let sidebar = color(light: 0.955, dark: 0.115)
    static let composer = color(light: 0.945, dark: 0.185)
    static let footer = color(light: 0.965, dark: 0.145)
    static let settingsCard = color(light: 0.975, dark: 0.135)
    static let separator = Color.primary.opacity(0.065)
    private static func color(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
        })
    }
}

struct WorkspaceRail: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        VStack(spacing: 12) {
            item("Home", icon: "house.fill", selected: !store.showingSettings) {
                store.showChat()
            }
            item("Projects and recent chats", icon: "sidebar.left", selected: false) {
                let returningFromSettings = store.showingSettings
                store.showChat()
                store.sidebarVisible = returningFromSettings ? true : !store.sidebarVisible
            }
            Spacer()
            item("Settings", icon: "gearshape", selected: store.showingSettings) { store.showSettings() }
        }
        .padding(.vertical, 10).frame(width: 48).background(ChatChrome.canvas)
    }
    private func item(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .regular))
                .frame(width: 34, height: 34)
                .background(selected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).foregroundStyle(selected ? .primary : .secondary).help(title).accessibilityLabel(title)
    }
}
