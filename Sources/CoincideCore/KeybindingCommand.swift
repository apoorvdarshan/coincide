import Foundation

/// A keybinding command ID. T3 Code's static IDs and `script.{id}.run` decode;
/// Coincide adds a few native window commands. Unknown IDs are configuration issues.
public struct KeybindingCommand: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public static let maxScriptIDLength = 24
    /// `script.<id>.run` with an id of `[a-z0-9][a-z0-9-]*`, at most 24 characters.
    public var scriptID: String? {
        guard rawValue.hasPrefix("script."), rawValue.hasSuffix(".run"), rawValue.count > "script..run".count else { return nil }
        let id = rawValue.dropFirst("script.".count).dropLast(".run".count)
        guard id.count <= Self.maxScriptIDLength, let first = id.unicodeScalars.first, Self.scriptLead.contains(first),
              id.unicodeScalars.allSatisfy(Self.scriptTail.contains) else { return nil }
        return String(id)
    }
    public static func script(_ id: String) -> KeybindingCommand { .init("script.\(id).run") }
    private static let scriptLead = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
    private static let scriptTail = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")

    /// Valid in a configuration file: a T3 static ID, a Coincide addition or a project script.
    public var isKnown: Bool { rawValue.utf16.count <= 96 && (KeybindingCatalog.entries[self] != nil || scriptID != nil) }
    public var availability: KeybindingCommandAvailability {
        if scriptID != nil { return .project }
        return KeybindingCatalog.entries[self]?.availability ?? .unknown
    }
    public var label: String { KeybindingCatalog.label(self) }

    public static let sidebarToggle = Self("sidebar.toggle")
    public static let navigationBack = Self("navigation.back")
    public static let navigationForward = Self("navigation.forward")
    public static let terminalToggle = Self("terminal.toggle")
    public static let terminalSplit = Self("terminal.split")
    public static let terminalSplitVertical = Self("terminal.splitVertical")
    public static let terminalNew = Self("terminal.new")
    public static let terminalClose = Self("terminal.close")
    public static let rightPanelToggle = Self("rightPanel.toggle")
    public static let viewReopenClosed = Self("view.reopenClosed")
    public static let diffToggle = Self("diff.toggle")
    public static let commandPaletteToggle = Self("commandPalette.toggle")
    public static let filePickerToggle = Self("filePicker.toggle")
    public static let projectSearchToggle = Self("projectSearch.toggle")
    public static let themeSelect = Self("theme.select")
    public static let appearanceCycle = Self("appearance.cycle")
    public static let chatNew = Self("chat.new")
    public static let chatNewLocal = Self("chat.newLocal")
    public static let chatFind = Self("chat.find")
    public static let editorOpenFavorite = Self("editor.openFavorite")
    public static let threadStop = Self("thread.stop")
    public static let threadPrevious = Self("thread.previous")
    public static let threadNext = Self("thread.next")
    public static let threadCopyReference = Self("thread.copyReference")
    public static let threadSettle = Self("thread.settle")
    public static let threadPin = Self("thread.pin")
    public static let threadUndo = Self("thread.undo")
    public static let threadJumps = (1...9).map { Self("thread.jump.\($0)") }
    public static func threadJump(_ number: Int) -> Self? { (1...9).contains(number) ? threadJumps[number - 1] : nil }
    /// One-based slot for `thread.jump.N`.
    public var threadJumpNumber: Int? { Self.threadJumps.firstIndex(of: self).map { $0 + 1 } }
    // Coincide additions for native window commands that T3 expresses differently.
    public static let projectNew = Self("project.new")
    public static let projectAdd = Self("project.add")
    public static let projectClone = Self("project.clone")
    public static let projectImport = Self("project.import")
    public static let windowNew = Self("window.new")
    public static let remoteOpen = Self("remote.open")
}

public enum KeybindingCommandAvailability: String, Sendable {
    /// Coincide dispatches this command.
    case available
    /// The ID and default are reserved for a native surface that owns its own handling.
    case reserved
    /// A valid T3 ID whose surface does not exist in Coincide; it is accepted and never dispatched.
    case unavailable
    /// `script.{id}.run`: executes only while that action is registered in the current main window.
    case project
    case unknown
}

public enum KeybindingCatalog {
    public struct Entry: Sendable {
        public let availability: KeybindingCommandAvailability
        public let label: String?
    }
    /// T3 STATIC_KEYBINDING_COMMANDS at the pinned revision, in contract order.
    public static let t3StaticCommands: [KeybindingCommand] = [
        "sidebar.toggle", "navigation.back", "navigation.forward", "terminal.toggle", "terminal.split", "terminal.splitVertical",
        "terminal.new", "terminal.close", "rightPanel.toggle", "rightPanel.new", "threadPanel.toggle", "rightPanel.toggleMaximized",
        "rightPanel.close", "view.reopenClosed", "pullRequest.copyNumber", "diff.toggle", "preview.toggle", "preview.refresh",
        "preview.focusUrl", "preview.zoomIn", "preview.zoomOut", "preview.resetZoom", "commandPalette.toggle", "filePicker.toggle",
        "projectSearch.toggle", "usage.open", "theme.select", "appearance.cycle", "themeEditor.toggle", "composer.stash",
        "composer.sendAlternate", "composer.sendBackground", "composer.sendAndNewThread", "composer.host", "composer.cycleHost",
        "composer.effort", "composer.increaseEffort", "composer.decreaseEffort", "composer.mode", "composer.workspace",
        "composer.previousWorktree", "composer.branch", "chat.new", "chat.newLocal", "chat.newWithoutProject", "chat.find",
        "editor.openFavorite", "usage.cost", "usage.tokens", "usage.limits", "usage.period.day", "usage.period.week",
        "usage.period.month", "usage.period.quarter", "modelPicker.toggle", "modelPicker.previousProvider", "modelPicker.nextProvider",
    ].map { KeybindingCommand($0) } + (1...9).map { KeybindingCommand("modelPicker.jump.\($0)") } + [
        "thread.stop", "thread.steerQueuedMessage", "thread.editQueuedMessage", "thread.previous", "thread.next",
        "thread.copyReference", "thread.settle", "thread.pin", "thread.undo",
    ].map { KeybindingCommand($0) } + KeybindingCommand.threadJumps

    private static let available: Set<KeybindingCommand> = Set([
        .sidebarToggle, .navigationBack, .navigationForward, .terminalToggle, .rightPanelToggle, .viewReopenClosed, .diffToggle,
        .commandPaletteToggle, .filePickerToggle, .projectSearchToggle, .themeSelect, .appearanceCycle, .chatNew, .chatNewLocal,
        .chatFind, .editorOpenFavorite, .threadStop, .threadPrevious, .threadNext, .threadCopyReference, .threadSettle, .threadPin,
        .terminalNew, .terminalClose, .terminalSplit, .terminalSplitVertical,
    ] + KeybindingCommand.threadJumps)
    private static let reserved: Set<KeybindingCommand> = []
    private static let additions: [KeybindingCommand: String] = [
        .projectNew: "Project: New Project", .projectAdd: "Project: Add Project", .projectClone: "Project: Clone Repository",
        .projectImport: "Project: Import Agent Projects", .windowNew: "Window: New Window", .remoteOpen: "Remote: Open Remote Workspaces",
    ]
    private static let labels: [KeybindingCommand: String] = [
        .threadCopyReference: "Thread: Copy Thread ID", .viewReopenClosed: "View: Reopen Closed View",
        .rightPanelToggle: "Inspector: Toggle", .diffToggle: "Inspector: Show Changes", .filePickerToggle: "Go to File",
        .projectSearchToggle: "Search Project Contents", .themeSelect: "Appearance: Change Appearance", .chatFind: "Find in Current Thread",
        .chatNew: "Chat: New Thread", .chatNewLocal: "Chat: New Thread in Current Project", .editorOpenFavorite: "Editor: Open Workspace in Preferred Editor",
        .commandPaletteToggle: "Command Palette", .threadStop: "Thread: Stop Turn",
    ]
    public static let entries: [KeybindingCommand: Entry] = {
        var result: [KeybindingCommand: Entry] = [:]
        for command in t3StaticCommands {
            let availability: KeybindingCommandAvailability = available.contains(command) ? .available : reserved.contains(command) ? .reserved : .unavailable
            result[command] = .init(availability: availability, label: labels[command])
        }
        for (command, label) in additions { result[command] = .init(availability: .available, label: label) }
        return result
    }()
    /// Every non-script command, in a stable order for pickers.
    public static var allCommands: [KeybindingCommand] { entries.keys.sorted { label($0).localizedStandardCompare(label($1)) == .orderedAscending } }

    public static func label(_ command: KeybindingCommand) -> String {
        if let label = entries[command]?.label { return label }
        if let id = command.scriptID { return "Run Script: " + titleCase(id) }
        if let number = command.threadJumpNumber { return "Thread: Jump to \(number)" }
        return command.rawValue.split(separator: ".").map { titleCase(String($0)) }.joined(separator: ": ")
    }
    /// T3 settings groups, by the command's first segment.
    public static func group(_ command: KeybindingCommand) -> String {
        let prefix = command.rawValue.split(separator: ".").first.map(String.init) ?? ""
        switch prefix {
        case "sidebar", "rightPanel", "commandPalette", "filePicker", "projectSearch", "editor", "navigation", "view": return "Navigation"
        case "thread", "chat", "pullRequest": return "Threads"
        case "composer", "modelPicker": return "Composer"
        case "terminal": return "Terminal"
        case "preview", "diff": return "Preview & Diff"
        case "theme", "appearance", "themeEditor": return "Appearance"
        case "script": return "Project Scripts"
        case "project", "window", "remote": return "Projects & Windows"
        default: return "Other"
        }
    }
    public static let groupOrder = ["Navigation", "Threads", "Composer", "Terminal", "Preview & Diff", "Appearance", "Projects & Windows", "Project Scripts", "Other"]

    static func titleCase(_ segment: String) -> String {
        var spaced = ""
        var previous: Character?
        for character in segment {
            if character.isUppercase, let previous, previous.isLowercase || previous.isNumber { spaced.append(" ") }
            spaced.append(character); previous = character
        }
        return spaced.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
