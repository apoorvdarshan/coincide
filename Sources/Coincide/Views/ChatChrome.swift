import AppKit
import SwiftUI

/// Flat, adaptive surfaces matching the chat reference rather than a glass dashboard.
enum ChatChrome {
    static let canvas = color(light: 0.995, dark: 0.067)
    static let sidebar = color(light: 0.955, dark: 0.115)
    static let composer = color(light: 0.96, dark: 0.14)
    static let footer = color(light: 0.975, dark: 0.105)
    static let settingsCard = color(light: 0.975, dark: 0.12)
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
            item("Plugins and integrations", icon: "puzzlepiece.extension", selected: store.showingSettings && [.skills, .commands, .mcp, .plugins, .hooks].contains(store.settingsPage)) {
                store.showSettings(.plugins)
            }
            item("Agent sessions", icon: "rectangle.stack", selected: store.showingSettings && store.settingsPage == .sessions) {
                store.showSettings(.sessions)
            }
            Spacer()
            item("Settings", icon: "gearshape", selected: store.showingSettings) { store.showSettings() }
        }
        .padding(.vertical, 10).frame(width: 48).background(ChatChrome.canvas)
    }
    private func item(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .regular))
        }.buttonStyle(ChatIconButtonStyle(selected: selected, size: 34))
            .foregroundStyle(selected ? .primary : .secondary).help(title).accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A quiet hit target shared by native chat controls, with no layout movement on hover.
struct ChatIconButtonStyle: ButtonStyle {
    var selected = false
    var size: CGFloat = 30
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: size, height: size)
            .modifier(ChatControlHover(selected: selected, pressed: configuration.isPressed))
    }
}

struct ChatControlHover: ViewModifier {
    var selected = false
    var pressed = false
    var cornerRadius: CGFloat = 8
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(!isEnabled ? 0 : pressed ? 0.12 : selected ? 0.09 : hovered ? 0.055 : 0),
                        in: RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}
