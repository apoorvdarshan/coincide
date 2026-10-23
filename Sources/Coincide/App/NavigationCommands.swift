import AppKit
import CoincideCore
import SwiftUI

/// Native menu surface for keybinding commands. Each item shows the shortcut
/// configured in keybindings.json and targets the focused main window; the
/// remote window publishes no controller, so these items disable there.
struct NavigationCommands: Commands {
    let keybindings: KeybindingsStore
    @FocusedValue(\.mainWindowController) private var controller: MainWindowController?

    var body: some Commands {
        // The palette's Go to File uses ⌘P; Coincide has nothing to print.
        CommandGroup(replacing: .printItem) { }
        CommandGroup(after: .textEditing) {
            CommandItem("Find in Thread…", .chatFind, controller: controller, keybindings: keybindings)
        }
        CommandGroup(before: .sidebar) {
            CommandItem("Command Palette…", .commandPaletteToggle, controller: controller, keybindings: keybindings)
            CommandItem("Toggle Sidebar", .sidebarToggle, controller: controller, keybindings: keybindings)
            CommandItem("Toggle Terminal", .terminalToggle, controller: controller, keybindings: keybindings)
            CommandItem("Show Changes", .diffToggle, controller: controller, keybindings: keybindings)
            CommandItem("Go to File…", .filePickerToggle, controller: controller, keybindings: keybindings)
            CommandItem("Search Project Contents…", .projectSearchToggle, controller: controller, keybindings: keybindings)
            CommandItem("Reopen Closed View", .viewReopenClosed, controller: controller, keybindings: keybindings)
            Divider()
            AppearanceMenu(controller: controller, keybindings: keybindings)
            Divider()
        }
        CommandMenu("Go") {
            GoMenuItems(controller: controller, keybindings: keybindings)
        }
    }
}

/// Thread-menu additions for the focused main window.
struct ThreadMenuItems: View {
    let keybindings: KeybindingsStore
    @FocusedValue(\.mainWindowController) private var controller: MainWindowController?
    var body: some View {
        CommandItem(controller?.selectedThread?.isPinned == true ? "Unpin Thread" : "Pin Thread", .threadPin, controller: controller, keybindings: keybindings)
        CommandItem("Copy Thread ID", .threadCopyReference, controller: controller, keybindings: keybindings)
        CommandItem("Open Workspace in Preferred Editor", .editorOpenFavorite, controller: controller, keybindings: keybindings)
        Divider()
    }
}

/// One menu item bound to a keybinding command.
struct CommandItem: View {
    let title: LocalizedStringKey
    let command: KeybindingCommand
    let controller: MainWindowController?
    let keybindings: KeybindingsStore
    var enabled: Bool? = nil
    init(_ title: LocalizedStringKey, _ command: KeybindingCommand, controller: MainWindowController?, keybindings: KeybindingsStore, enabled: Bool? = nil) {
        self.title = title; self.command = command; self.controller = controller; self.keybindings = keybindings; self.enabled = enabled
    }
    var body: some View {
        Button(title) { MenuCommandInvocation.run(command, controller: controller, dispatcher: keybindings.dispatcher) }
            .keyboardShortcut(keybindings.menuShortcut(command))
            .disabled(!(enabled ?? controller?.canPerform(command) ?? false))
    }
}

enum MenuCommandInvocation {
    /// A key equivalent whose keybinding condition was false (for example ⌘F in a
    /// terminal) does not run the menu command. Find falls back to the focused
    /// view's own find interface, so terminals and editors keep ⌘F.
    @MainActor static func run(_ command: KeybindingCommand, controller: MainWindowController?, dispatcher: KeyboardCommandDispatcher?) {
        if dispatcher?.declinedCurrentEvent() == true {
            if command == .chatFind {
                let item = NSMenuItem(); item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
                NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
            }
            return
        }
        controller?.perform(command)
    }
}

private struct GoMenuItems: View {
    let controller: MainWindowController?
    let keybindings: KeybindingsStore
    var body: some View {
        // Compute the visible order once; menus re-render on every workspace change.
        let order = controller?.store.visibleThreadOrder ?? []
        let current = controller?.store.selectedThreadID
        CommandItem("Back", .navigationBack, controller: controller, keybindings: keybindings)
        CommandItem("Forward", .navigationForward, controller: controller, keybindings: keybindings)
        Divider()
        CommandItem("Previous Thread", .threadPrevious, controller: controller, keybindings: keybindings,
                    enabled: controller != nil && ThreadTraversal.adjacent(in: order, current: current, direction: .previous) != nil)
        CommandItem("Next Thread", .threadNext, controller: controller, keybindings: keybindings,
                    enabled: controller != nil && ThreadTraversal.adjacent(in: order, current: current, direction: .next) != nil)
        Divider()
        ForEach(1...9, id: \.self) { number in
            let id = order.count >= number ? order[number - 1] : nil
            let title = id.flatMap { controller?.store.thread($0)?.title } ?? String(localized: "Thread \(number)")
            Button(title) { MenuCommandInvocation.run(KeybindingCommand.threadJumps[number - 1], controller: controller, dispatcher: keybindings.dispatcher) }
                .keyboardShortcut(keybindings.menuShortcut(KeybindingCommand.threadJumps[number - 1]))
                .disabled(controller == nil || id == nil)
        }
    }
}

private struct AppearanceMenu: View {
    let controller: MainWindowController?
    let keybindings: KeybindingsStore
    @AppStorage(AppearanceMode.defaultsKey) private var appearance = AppearanceMode.system.rawValue
    var body: some View {
        Menu("Appearance") {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
            }.pickerStyle(.inline).labelsHidden()
            Divider()
            Button("Cycle Appearance") { if !keybindings.dispatcher.declinedCurrentEvent() { AppearanceMode.cycle() } }
                .keyboardShortcut(keybindings.menuShortcut(.appearanceCycle))
            CommandItem("Change Appearance…", .themeSelect, controller: controller, keybindings: keybindings)
        }
    }
}
