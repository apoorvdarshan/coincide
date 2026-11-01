import Foundation

public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    public nonisolated var displayName: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}

/// The typeface of agents' replies: Apple's New York serif, which sets them apart from the interface and the
/// user's own messages, or the system's San Francisco.
public enum ReplyTypeface: String, Codable, CaseIterable, Sendable {
    case newYork
    case system

    public nonisolated var displayName: String {
        switch self {
        case .newYork: String(localized: "New York")
        case .system: String(localized: "San Francisco")
        }
    }
}

/// Which side of the conversation the user's own messages sit on: the right, across from the agents' replies as in a
/// chat app, or the left, on the agent rail with the replies. In a right-to-left interface the transcript mirrors them.
public enum UserMessageSide: String, Codable, CaseIterable, Sendable {
    case right
    case left

    public nonisolated var displayName: String {
        switch self {
        case .right: String(localized: "Right")
        case .left: String(localized: "Left")
        }
    }
}

/// Where the terminal opens, and with it where its button sits: in a drawer below the chat, with its button in the
/// navigation rail on the window's left edge, or in the column on the right beside the diff, the pull requests and the
/// browser preview, with its button among theirs in the toolbar's top-right corner.
public enum TerminalPlacement: String, Codable, CaseIterable, Sendable {
    case bottom
    case right

    public nonisolated var displayName: String {
        switch self {
        case .bottom: String(localized: "Bottom panel")
        case .right: String(localized: "Right panel")
        }
    }
}

public struct ProviderSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    /// Absolute path to the CLI, when the user overrides PATH lookup.
    public var executablePath: String?
    /// Extra model ids the user added by hand, shown in the picker.
    public var customModels: [String]
    /// Extra environment variables for this provider's process.
    public var environment: [String: String]
    /// The accounts added besides the default one, in the order the user added them (`ProviderAccount`).
    public var accounts: [ProviderAccount]

    public nonisolated init(
        isEnabled: Bool = true, executablePath: String? = nil, customModels: [String] = [],
        environment: [String: String] = [:], accounts: [ProviderAccount] = []
    ) {
        self.isEnabled = isEnabled
        self.executablePath = executablePath
        self.customModels = customModels
        self.environment = environment
        self.accounts = accounts
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        customModels = try container.decodeIfPresent([String].self, forKey: .customModels) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        // An account this version cannot read is left out rather than failing the provider's settings, and one
        // claiming the default's id or repeating an id is dropped.
        var seen: Set<String> = [ProviderAccount.defaultID]
        accounts = container.lenientArray(ProviderAccount.self, forKey: .accounts).filter { seen.insert($0.id).inserted }
    }

    /// The default account followed by the added ones, all of `kind`.
    public nonisolated func allAccounts(of kind: ProviderKind) -> [ProviderAccount] {
        [.defaultAccount(for: kind)] + (kind.supportsAccounts ? accounts.filter { $0.provider == kind } : [])
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var defaultSelection: ModelSelection
    public var defaultAccessMode: AccessMode
    public var providers: [ProviderKind: ProviderSettings]
    public var appearance: AppearanceMode
    /// System regional numbers by default; International uses three-digit comma grouping for numeric displays.
    public var numberFormat: NumberFormatMode
    /// Return sends; Shift-Return inserts a newline. When false, Command-Return sends.
    public var sendOnReturn: Bool
    /// What a message sent while the agent works does in new threads: the last choice made in a thread's composer
    /// (`AppStore.setFollowUpBehavior`) or here. Each thread keeps its own.
    public var followUpBehavior: FollowUpBehavior
    /// What threads without a choice of their own do: those made before each thread kept one, which go on as the
    /// app-wide setting had them.
    public var existingThreadsFollowUpBehavior: FollowUpBehavior
    public var showReasoning: Bool
    public var confirmBeforeDeletingThreads: Bool
    /// Archiving a thread (⌘W, its archive button, the menus) asks first.
    public var confirmBeforeArchivingThreads: Bool
    /// The `coincide` command-line tool may drive Coincide over its local socket (`CommandLineControl`).
    public var commandLineControl: Bool
    /// Agents may view and control this Mac through Coincide's private, thread-scoped Computer Use connection.
    public var computerUseEnabled: Bool
    /// Coincide draws the agent's cursor on whichever display it acts on (Cua Driver's own overlay covers only the main
    /// display, trycua/cua#5336).
    public var computerUseShowsAgentCursor: Bool
    /// Settings › Appshots: both ⌘ keys (or a shortcut) capture the frontmost window of another app into a chat. Off by
    /// default, and then no key is watched.
    public var appshots: AppshotSettings
    /// What an agent schedules in its thread (`coincide_schedule`) waits for the user to allow it before it can run.
    public var approvesAgentSchedules: Bool
    /// Keep Awake: the Mac never sleeps, closing the lid included (`AlwaysOnController`). The lid watcher reads it
    /// from settings.json too.
    public var alwaysOn: AlwaysOnSettings
    /// ⌘Q quits only when held or pressed twice (`QuitShortcutGuard`); a single press shows a hint. Quitting from the
    /// menu, the Dock, logging out or AppleScript is never held up.
    public var holdToQuit: Bool
    /// A plain click on a web link opens it in the default browser, and a ⌘-click in Coincide's browser preview. Off
    /// by default: links open in the preview, and ⌘-click opens the default browser (`LinkRouting`).
    public var opensLinksInDefaultBrowser: Bool
    /// Have the thread's agent name a new thread from its first message and first reply (T3 Code's generated titles).
    public var generatesThreadTitles: Bool
    /// With `generatesThreadTitles`, also have the agent look at the title again every few turns of a thread in use
    /// (`ThreadTitles.dueRefresh`). Off by default: each look costs a small request.
    public var updatesThreadTitles: Bool
    /// App update checks are opt-in and run at most daily, including across launches.
    public var lastAppUpdateCheck: Date?
    public var checksForAppUpdates: Bool
    /// Continue a thread on its own once the usage limit that stopped it resets (T3 Code's auto-resume).
    public var resumesAfterUsageLimit: Bool
    /// New Thread (⌘N) starts a chat without a project instead of a thread in the current project.
    public var newThreadStartsChat: Bool
    /// Provider sessions idle this long are shut down to free memory; their ids are kept for resume.
    public var idleSessionTimeoutMinutes: Int
    /// Post a system notification when a turn finishes or needs approval while Coincide is in the background.
    public var notifyWhenInBackground: Bool
    /// Create a git checkpoint before each turn so the turn can be reverted.
    public var checkpointsEnabled: Bool
    /// Branch name prefix for new worktrees.
    public var worktreeBranchPrefix: String
    /// Font size for the transcript and composer.
    public var fontSize: Double
    public var replyTypeface: ReplyTypeface
    /// Where the user's messages sit in the conversation; the right by default.
    public var userMessageSide: UserMessageSide
    /// Where the terminal opens: below the chat (its button in the rail), as it always has, or in the right column (its
    /// button in the toolbar's top-right group).
    public var terminalPlacement: TerminalPlacement
    /// The terminal draws with Metal on the GPU (SwiftTerm's renderer) instead of Core Graphics, falling back to Core
    /// Graphics where Metal can't start. On by default; Settings › General › GPU rendering turns it off.
    public var terminalGPURendering: Bool
    /// The terminal's background lets the blurred desktop show through. Off by default, as Coincide's surfaces are opaque.
    public var terminalTranslucentBackground: Bool
    /// The pointing-hand cursor shows over what can be clicked (buttons, links, tabs, list rows), as on the web, instead
    /// of the arrow (`PointerCursor`). On by default; off leaves every cursor as macOS sets it.
    public var showsPointingHand: Bool
    /// Bundle identifier of the app the "Open In" button opens project folders in, picked in Settings › General or from
    /// any Open In menu; nil for automatic, the first installed editor. (Earlier versions kept it in the interface
    /// state, `UIState`, from where it moves here once.)
    public var preferredOpenTarget: String?
    /// The color themes used in dark and light mode, by id. An id this version does not know falls back to the first
    /// theme of its kind.
    public var darkTheme: String
    public var lightTheme: String
    /// Menu shortcuts the user changed, by `KeyCommand` id, written like T3 Code's keybindings (`mod+shift+k`).
    /// An empty string removes the command's shortcut. Commands not listed use their defaults.
    public var shortcutOverrides: [String: String]
    /// Read the Cursor CLI's login from the macOS Keychain to show the plan's usage limits (T3 Code's
    /// `cursorKeychainUsageEnabled`). Off by default, because macOS may ask the user to allow the read.
    public var cursorKeychainUsageEnabled: Bool
    /// Settings › Usage also counts Claude Code and Codex sessions run outside Coincide (in a terminal or another app),
    /// read from the CLIs' own logs on this Mac.
    public var usageIncludesOtherSessions: Bool
    /// Coincide's menu bar item shows the plans' usage limits.
    public var showsUsageInMenuBar: Bool
    /// What the menu bar item shows: by default the last agent used, with its most used limit.
    public var menuBarUsage: MenuBarUsageChoice
    /// A second figure shown beside the first, such as Codex next to Claude; nil for none.
    public var menuBarSecondaryUsage: MenuBarUsageChoice?
    /// Whether usage figures read as what is used or what is left, in the menu bar, its popover and Settings › Usage.
    public var usageDisplayMode: UsageDisplayMode
    /// Advisory warnings acknowledged by the user, shared across windows and saved across restarts.
    public var dismissedWarnings: Set<String>
    /// How often usage is read again on its own (`UsageRefreshInterval`).
    public var usageRefresh: UsageRefreshInterval
    /// Sites whose usage pages Settings › Usage may read with the user's sign-in in Coincide's browser, for details
    /// the agents' APIs don't give. None by default.
    public var usageBrowserSignIn: [BrowserUsageSource]
    /// Models the user starred (T3 Code's favorites), in the order they were starred. The model picker lists them
    /// first, and together in its Favorites tab.
    public var favoriteModels: [ModelReference]
    /// Models the user never uses (T3 Code's hidden models), left out of the model picker. Settings › Models shows
    /// them again.
    public var hiddenModels: [ModelReference]
    /// Settings › Voice: dictation in the composer.
    public var voice: VoiceSettings

    public nonisolated init() {
        defaultSelection = ModelSelection(provider: .claude, modelID: "default")
        defaultAccessMode = .fullAccess
        providers = [:]
        appearance = .system
        numberFormat = .system
        sendOnReturn = true
        followUpBehavior = .steer
        existingThreadsFollowUpBehavior = .steer
        showReasoning = true
        confirmBeforeDeletingThreads = true
        confirmBeforeArchivingThreads = true
        commandLineControl = true
        computerUseEnabled = false
        computerUseShowsAgentCursor = true
        appshots = AppshotSettings()
        approvesAgentSchedules = true
        alwaysOn = AlwaysOnSettings()
        holdToQuit = true
        opensLinksInDefaultBrowser = false
        generatesThreadTitles = true
        updatesThreadTitles = false
        lastAppUpdateCheck = nil
        checksForAppUpdates = false
        resumesAfterUsageLimit = false
        newThreadStartsChat = false
        idleSessionTimeoutMinutes = 30
        notifyWhenInBackground = true
        checkpointsEnabled = true
        worktreeBranchPrefix = "coincide/"
        fontSize = 13
        replyTypeface = .newYork
        userMessageSide = .right
        terminalPlacement = .bottom
        terminalGPURendering = true
        terminalTranslucentBackground = false
        showsPointingHand = true
        preferredOpenTarget = nil
        darkTheme = "carbon"
        lightTheme = "carbon-light"
        shortcutOverrides = [:]
        cursorKeychainUsageEnabled = false
        usageIncludesOtherSessions = true
        showsUsageInMenuBar = true
        menuBarUsage = .lastActive
        menuBarSecondaryUsage = nil
        usageDisplayMode = .used
        dismissedWarnings = []
        usageRefresh = .automatic
        usageBrowserSignIn = []
        favoriteModels = []
        hiddenModels = []
        voice = VoiceSettings()
    }

    public nonisolated func settings(for provider: ProviderKind) -> ProviderSettings {
        providers[provider] ?? ProviderSettings()
    }

    public nonisolated init(from decoder: Decoder) throws {
        let defaults = AppSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        defaultSelection = value(.defaultSelection, defaults.defaultSelection)
        defaultAccessMode = value(.defaultAccessMode, defaults.defaultAccessMode)
        // Settings of providers this version does not know are skipped, not the whole list.
        providers = container.lenientProviderMap(ProviderSettings.self, forKey: .providers)
        appearance = value(.appearance, defaults.appearance)
        numberFormat = value(.numberFormat, defaults.numberFormat)
        sendOnReturn = value(.sendOnReturn, defaults.sendOnReturn)
        followUpBehavior = value(.followUpBehavior, defaults.followUpBehavior)
        // Settings from before threads kept their own: the app-wide setting carries on for the threads there were.
        existingThreadsFollowUpBehavior = value(.existingThreadsFollowUpBehavior, followUpBehavior)
        showReasoning = value(.showReasoning, defaults.showReasoning)
        confirmBeforeDeletingThreads = value(.confirmBeforeDeletingThreads, defaults.confirmBeforeDeletingThreads)
        confirmBeforeArchivingThreads = value(.confirmBeforeArchivingThreads, defaults.confirmBeforeArchivingThreads)
        commandLineControl = value(.commandLineControl, defaults.commandLineControl)
        computerUseEnabled = value(.computerUseEnabled, defaults.computerUseEnabled)
        computerUseShowsAgentCursor = value(.computerUseShowsAgentCursor, defaults.computerUseShowsAgentCursor)
        appshots = value(.appshots, defaults.appshots)
        approvesAgentSchedules = value(.approvesAgentSchedules, defaults.approvesAgentSchedules)
        alwaysOn = value(.alwaysOn, defaults.alwaysOn)
        holdToQuit = value(.holdToQuit, defaults.holdToQuit)
        opensLinksInDefaultBrowser = value(.opensLinksInDefaultBrowser, defaults.opensLinksInDefaultBrowser)
        generatesThreadTitles = value(.generatesThreadTitles, defaults.generatesThreadTitles)
        updatesThreadTitles = value(.updatesThreadTitles, defaults.updatesThreadTitles)
        lastAppUpdateCheck = value(.lastAppUpdateCheck, defaults.lastAppUpdateCheck)
        checksForAppUpdates = value(.checksForAppUpdates, defaults.checksForAppUpdates)
        resumesAfterUsageLimit = value(.resumesAfterUsageLimit, defaults.resumesAfterUsageLimit)
        newThreadStartsChat = value(.newThreadStartsChat, defaults.newThreadStartsChat)
        idleSessionTimeoutMinutes = value(.idleSessionTimeoutMinutes, defaults.idleSessionTimeoutMinutes)
        notifyWhenInBackground = value(.notifyWhenInBackground, defaults.notifyWhenInBackground)
        checkpointsEnabled = value(.checkpointsEnabled, defaults.checkpointsEnabled)
        worktreeBranchPrefix = value(.worktreeBranchPrefix, defaults.worktreeBranchPrefix)
        fontSize = value(.fontSize, defaults.fontSize)
        replyTypeface = value(.replyTypeface, defaults.replyTypeface)
        userMessageSide = value(.userMessageSide, defaults.userMessageSide)
        terminalPlacement = value(.terminalPlacement, defaults.terminalPlacement)
        terminalGPURendering = value(.terminalGPURendering, defaults.terminalGPURendering)
        terminalTranslucentBackground = value(.terminalTranslucentBackground, defaults.terminalTranslucentBackground)
        showsPointingHand = value(.showsPointingHand, defaults.showsPointingHand)
        preferredOpenTarget = value(.preferredOpenTarget, defaults.preferredOpenTarget)
        darkTheme = value(.darkTheme, defaults.darkTheme)
        lightTheme = value(.lightTheme, defaults.lightTheme)
        // A value that is not text stays as written, so the Keyboard pane can point it out.
        shortcutOverrides = (container.lenient([String: JSONValue].self, forKey: .shortcutOverrides) ?? [:])
            .compactMapValues { $0.isNull ? nil : ($0.string ?? $0.displayText) }
        cursorKeychainUsageEnabled = value(.cursorKeychainUsageEnabled, defaults.cursorKeychainUsageEnabled)
        usageIncludesOtherSessions = value(.usageIncludesOtherSessions, defaults.usageIncludesOtherSessions)
        showsUsageInMenuBar = value(.showsUsageInMenuBar, defaults.showsUsageInMenuBar)
        menuBarUsage = value(.menuBarUsage, defaults.menuBarUsage)
        menuBarSecondaryUsage = value(.menuBarSecondaryUsage, defaults.menuBarSecondaryUsage)
        usageDisplayMode = value(.usageDisplayMode, defaults.usageDisplayMode)
        dismissedWarnings = value(.dismissedWarnings, defaults.dismissedWarnings)
        usageRefresh = value(.usageRefresh, defaults.usageRefresh)
        // A site this version doesn't know is dropped rather than failing the whole list.
        usageBrowserSignIn = value(.usageBrowserSignIn, [String]()).compactMap(BrowserUsageSource.init(rawValue:))
        // Models of agents this version does not know are skipped, not the whole list.
        favoriteModels = container.lenientArray(ModelReference.self, forKey: .favoriteModels)
        hiddenModels = container.lenientArray(ModelReference.self, forKey: .hiddenModels)
        voice = value(.voice, defaults.voice)
    }
}

// MARK: - Favorite and hidden models

extension AppSettings {
    public nonisolated func isFavorite(_ model: ModelReference) -> Bool { favoriteModels.contains(model) }

    public nonisolated func isHidden(_ model: ModelReference) -> Bool { hiddenModels.contains(model) }

    /// Stars or unstars a model. A starred model shows again if it was hidden.
    public nonisolated mutating func setFavorite(_ isFavorite: Bool, _ model: ModelReference) {
        favoriteModels.removeAll { $0 == model }
        guard isFavorite else { return }
        favoriteModels.append(model)
        hiddenModels.removeAll { $0 == model }
    }

    /// Hides a model from the picker or shows it again. A hidden model is no longer a favorite.
    public nonisolated mutating func setHidden(_ isHidden: Bool, _ model: ModelReference) {
        hiddenModels.removeAll { $0 == model }
        guard isHidden else { return }
        hiddenModels.append(model)
        favoriteModels.removeAll { $0 == model }
    }

    /// An agent's models as the picker lists them: its favorites first, then the rest, each in the agent's order, and
    /// none that are hidden but the `current` one.
    public nonisolated func pickerModels(_ models: [ModelOption], current: ModelSelection?) -> [ModelOption] {
        let visible = models.filter { model in
            !isHidden(model.reference) || (model.provider == current?.provider && model.modelID == current?.modelID)
        }
        return visible.filter { isFavorite($0.reference) } + visible.filter { !isFavorite($0.reference) }
    }

    /// The favorites among `models` (every agent's, in display order), for the picker's Favorites tab: grouped by agent
    /// as `models` lists them, as T3 Code orders them.
    public nonisolated func favorites(in models: [ModelOption]) -> [ModelOption] {
        models.filter { isFavorite($0.reference) && !isHidden($0.reference) }
    }
}

// MARK: - Keyboard shortcuts

extension AppSettings {
    /// The shortcut of every menu command, with the user's overrides applied.
    public nonisolated var keyBindings: KeyBindings { KeyBindings(overrides: shortcutOverrides) }

    /// Gives `command` a shortcut, or none. Choosing the default removes the override, so the command follows
    /// later changes to its default.
    public nonisolated mutating func setShortcut(_ shortcut: KeyShortcut?, for command: KeyCommand) {
        if shortcut == command.defaultShortcut {
            shortcutOverrides.removeValue(forKey: command.rawValue)
        } else {
            shortcutOverrides[command.rawValue] = shortcut?.stringValue ?? ""
        }
    }

    /// Puts one command back on its default shortcut.
    public nonisolated mutating func resetShortcut(for command: KeyCommand) {
        shortcutOverrides.removeValue(forKey: command.rawValue)
    }

    /// Puts every command back on its default shortcut.
    public nonisolated mutating func resetAllShortcuts() {
        shortcutOverrides = [:]
    }

    /// Removes the saved overrides Coincide can't use (`KeyBindings.issues`).
    public nonisolated mutating func removeUnusableShortcuts() {
        for issue in keyBindings.issues { shortcutOverrides.removeValue(forKey: issue.commandID) }
    }
}

/// The modifier keys of a keyboard shortcut.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public nonisolated init(rawValue: Int) { self.rawValue = rawValue }

    public nonisolated static let control = KeyModifiers(rawValue: 1 << 0)
    public nonisolated static let option = KeyModifiers(rawValue: 1 << 1)
    public nonisolated static let shift = KeyModifiers(rawValue: 1 << 2)
    public nonisolated static let command = KeyModifiers(rawValue: 1 << 3)

    /// The modifiers' glyphs in Apple's order: ⌃ ⌥ ⇧ ⌘.
    public nonisolated var glyphs: [String] {
        var glyphs: [String] = []
        if contains(.control) { glyphs.append("⌃") }
        if contains(.option) { glyphs.append("⌥") }
        if contains(.shift) { glyphs.append("⇧") }
        if contains(.command) { glyphs.append("⌘") }
        return glyphs
    }
}

/// A key and the modifiers held with it, written the way T3 Code writes keybindings: `mod+shift+k`.
///
/// `mod` (also `cmd`, `command` or `meta`) is Command; the other modifiers are `ctrl` (or `control`), `alt` (or
/// `option`) and `shift`. The key is one character (`k`, `1`, `[`, `+`) or a name: `enter`, `tab`, `space`, `esc`,
/// `backspace` (⌫), `delete` (⌦), `arrowup`, `arrowdown`, `arrowleft`, `arrowright`, `home`, `end`, `pageup`,
/// `pagedown`, or `f1` to `f20`. Letters are lowercase: Shift is a modifier like the others.
public struct KeyShortcut: Hashable, Sendable, CustomStringConvertible {
    /// A lowercase character or one of the key names above.
    public let key: String
    public let modifiers: KeyModifiers

    /// A shortcut for `key` (a character or key name, in any case), or nil when it is not a key.
    public nonisolated init?(key: String, modifiers: KeyModifiers = []) {
        guard let key = Self.normalizedKey(key) else { return nil }
        self.key = key
        self.modifiers = modifiers
    }

    /// Reads T3 Code's keybinding syntax: parts joined by `+`, in any order and case, such as `Mod+Shift+K`.
    public nonisolated init?(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var tokens = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // As in T3, empty parts at the end are the "+" key itself: "mod++" is Command-Plus.
        if tokens.last == "" {
            while tokens.last == "" { tokens.removeLast() }
            tokens.append("+")
        }
        guard !tokens.contains("") else { return nil }
        var key: String?
        var modifiers: KeyModifiers = []
        for token in tokens {
            switch token {
            case "mod", "cmd", "command", "meta": modifiers.insert(.command)
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default:
                guard key == nil else { return nil }
                key = token
            }
        }
        guard let key else { return nil }
        self.init(key: key, modifiers: modifiers)
    }

    /// The shortcut of a menu item's key equivalent (`NSMenuItem.keyEquivalent`, such as "k", "\r" or
    /// `NSF5FunctionKey`). As in AppKit, an uppercase letter implies Shift.
    public nonisolated init?(menuKeyEquivalent: String, modifiers: KeyModifiers) {
        guard menuKeyEquivalent.unicodeScalars.count == 1, let scalar = menuKeyEquivalent.unicodeScalars.first else {
            return nil
        }
        if let name = Self.keyName(forMenuScalar: scalar.value) {
            self.init(key: name, modifiers: modifiers)
        } else {
            let isUppercase = menuKeyEquivalent.lowercased() != menuKeyEquivalent
            self.init(key: menuKeyEquivalent, modifiers: isUppercase ? modifiers.union(.shift) : modifiers)
        }
    }

    /// The shortcut a key press records: its virtual key code (`NSEvent.keyCode`), the character the key types with
    /// no modifiers held, and the modifiers. Nil for a modifier key on its own, or a key that types nothing.
    public nonisolated static func recorded(keyCode: UInt16, character: String?, modifiers: KeyModifiers) -> KeyShortcut? {
        if modifierKeyCodes.contains(keyCode) { return nil }
        if let name = keyCodeNames[keyCode] { return KeyShortcut(key: name, modifiers: modifiers) }
        guard let character, !character.isEmpty else { return nil }
        if character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
            let name = keyName(forMenuScalar: scalar.value)
        {
            return KeyShortcut(key: name, modifiers: modifiers)
        }
        return KeyShortcut(key: character, modifiers: modifiers)
    }

    /// The shortcut as text that `init(_:)` reads back: modifiers in T3 Code's order (`mod`, `ctrl`, `alt`,
    /// `shift`), then the key.
    public nonisolated var stringValue: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("mod") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    public nonisolated var description: String { stringValue }

    /// Modifier glyphs in Apple's order (⌃ ⌥ ⇧ ⌘) followed by the key, one key cap each.
    public nonisolated var glyphs: [String] { modifiers.glyphs + [keyGlyph] }

    /// The shortcut as menus show it, such as ⇧⌘K.
    public nonisolated var displayString: String { glyphs.joined() }

    /// The key as a key cap shows it: "K", "↩", "F5".
    public nonisolated var keyGlyph: String {
        if key == "space" { return String(localized: "Space") }
        if let named = Self.namedKeys[key] { return named.glyph }
        if let number = Self.functionKeyNumber(key) { return "F\(number)" }
        return key.uppercased()
    }

    /// The shortcut read out by name, for VoiceOver: "Shift Command K".
    public nonisolated var spokenDescription: String {
        var words: [String] = []
        if modifiers.contains(.control) { words.append(String(localized: "Control")) }
        if modifiers.contains(.option) { words.append(String(localized: "Option")) }
        if modifiers.contains(.shift) { words.append(String(localized: "Shift")) }
        if modifiers.contains(.command) {
            words.append(String(localized: "key.command", defaultValue: "Command", comment: "Spoken name of the ⌘ key"))
        }
        words.append(spokenKey)
        return words.joined(separator: " ")
    }

    /// Whether a menu item can use it without taking the key from text fields: it needs Command or Control, unless
    /// the key is a function key.
    public nonisolated var isUsableInMenus: Bool {
        !modifiers.isDisjoint(with: [.command, .control]) || Self.functionKeyNumber(key) != nil
    }

    /// The key as `NSMenuItem.keyEquivalent` spells it: the character, "\r" for Return, `NSF5FunctionKey` for F5…
    public nonisolated var menuKeyEquivalent: String {
        if let named = Self.namedKeys[key], let scalar = Unicode.Scalar(named.menuScalar) { return String(scalar) }
        if let number = Self.functionKeyNumber(key), let scalar = Unicode.Scalar(Self.firstFunctionKey + UInt32(number) - 1) {
            return String(scalar)
        }
        return key
    }

    // MARK: Keys

    /// `NSF1FunctionKey`; F2 to F20 follow it.
    private nonisolated static let firstFunctionKey: UInt32 = 0xF704

    /// Named keys: the glyph menus show, and the character `NSMenuItem.keyEquivalent` uses.
    private nonisolated static let namedKeys: [String: (glyph: String, menuScalar: UInt32)] = [
        "enter": ("↩", 0x0D), "tab": ("⇥", 0x09), "space": ("␣", 0x20), "esc": ("⎋", 0x1B),
        "backspace": ("⌫", 0x08), "delete": ("⌦", 0xF728), "arrowup": ("↑", 0xF700), "arrowdown": ("↓", 0xF701),
        "arrowleft": ("←", 0xF702), "arrowright": ("→", 0xF703), "home": ("↖", 0xF729), "end": ("↘", 0xF72B),
        "pageup": ("⇞", 0xF72C), "pagedown": ("⇟", 0xF72D),
    ]

    /// Virtual key codes (`kVK_…`) of keys that type no character of their own.
    private nonisolated static let keyCodeNames: [UInt16: String] = [
        0x24: "enter", 0x4C: "enter", 0x30: "tab", 0x31: "space", 0x33: "backspace", 0x35: "esc", 0x75: "delete",
        0x73: "home", 0x77: "end", 0x74: "pageup", 0x79: "pagedown", 0x7B: "arrowleft", 0x7C: "arrowright",
        0x7D: "arrowdown", 0x7E: "arrowup", 0x7A: "f1", 0x78: "f2", 0x63: "f3", 0x76: "f4", 0x60: "f5", 0x61: "f6",
        0x62: "f7", 0x64: "f8", 0x65: "f9", 0x6D: "f10", 0x67: "f11", 0x6F: "f12", 0x69: "f13", 0x6B: "f14",
        0x71: "f15", 0x6A: "f16", 0x40: "f17", 0x4F: "f18", 0x50: "f19", 0x5A: "f20",
    ]

    /// Command, Shift, Caps Lock, Option, Control (each side) and Function.
    private nonisolated static let modifierKeyCodes: Set<UInt16> = [0x37, 0x36, 0x38, 0x3C, 0x39, 0x3A, 0x3D, 0x3B, 0x3E, 0x3F]

    private nonisolated static func normalizedKey(_ raw: String) -> String? {
        let key = raw.lowercased()
        switch key {
        case "escape": return "esc"
        case "return": return "enter"
        case " ": return "space"
        default: break
        }
        if namedKeys[key] != nil || functionKeyNumber(key) != nil { return key }
        // One character that types something: not a control character or one of AppKit's function-key characters.
        guard key.count == 1, let scalar = key.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar),
            !CharacterSet.whitespacesAndNewlines.contains(scalar), !(0xE000...0xF8FF).contains(scalar.value)
        else { return nil }
        return key
    }

    /// 1–20 for "f1"…"f20".
    private nonisolated static func functionKeyNumber(_ key: String) -> Int? {
        guard key.hasPrefix("f"), let number = Int(key.dropFirst()), (1...20).contains(number), key == "f\(number)" else {
            return nil
        }
        return number
    }

    private nonisolated static func keyName(forMenuScalar value: UInt32) -> String? {
        switch value {
        case 0x03: "enter"
        case 0x7F: "backspace"
        case firstFunctionKey..<(firstFunctionKey + 20): "f\(value - firstFunctionKey + 1)"
        default: namedKeys.first { $0.value.menuScalar == value }?.key
        }
    }

    private nonisolated var spokenKey: String {
        switch key {
        case "enter": String(localized: "Return")
        case "tab": String(localized: "Tab")
        case "space": String(localized: "Space")
        case "esc": String(localized: "Escape")
        case "backspace": String(localized: "key.delete", defaultValue: "Delete", comment: "Spoken name of the ⌫ key")
        case "delete": String(localized: "Forward Delete")
        case "arrowup": String(localized: "Up Arrow")
        case "arrowdown": String(localized: "Down Arrow")
        case "arrowleft": String(localized: "Left Arrow")
        case "arrowright": String(localized: "Right Arrow")
        case "home": String(localized: "Home")
        case "end": String(localized: "End")
        case "pageup": String(localized: "Page Up")
        case "pagedown": String(localized: "Page Down")
        default: keyGlyph
        }
    }

    /// A shortcut written in Coincide's own source, which is known to read.
    nonisolated static func builtIn(_ text: String) -> KeyShortcut {
        guard let shortcut = KeyShortcut(text) else { preconditionFailure("Invalid built-in shortcut \(text)") }
        return shortcut
    }
}

/// A menu command whose shortcut the user can change. Raw values are the ids `AppSettings.shortcutOverrides` uses:
/// T3 Code's keybinding command ids where T3 has the same command.
///
/// Cases are in menu-bar order. When commands share a shortcut, a changed shortcut wins over a default one, as a
/// user's keybinding overrides a default in T3; otherwise the command higher in the menu bar runs.
public enum KeyCommand: String, CaseIterable, Sendable, Identifiable {
    // File
    case newThread = "chat.new"
    case newChat = "chat.newProjectless"
    case addProject = "project.add"
    case openInEditor = "editor.openFavorite"
    case revealInFinder = "project.revealInFinder"
    // Edit
    case addToComposer = "composer.addSelection"
    // Edit › Find
    case searchThreads = "sidebar.search"
    // View
    case toggleSidebar = "sidebar.toggle"
    case toggleTerminal = "terminal.toggle"
    case toggleDiff = "diff.toggle"
    case showSchedules = "schedules.show"
    case commandPalette = "commandPalette.toggle"
    case increaseFontSize = "view.increaseFontSize"
    case decreaseFontSize = "view.decreaseFontSize"
    case resetFontSize = "view.resetFontSize"
    case showArchive = "archive.show"
    // Thread
    case stopTurn = "thread.stop"
    case previousThread = "thread.previous"
    case nextThread = "thread.next"
    case jumpToThread1 = "thread.jump.1"
    case jumpToThread2 = "thread.jump.2"
    case jumpToThread3 = "thread.jump.3"
    case jumpToThread4 = "thread.jump.4"
    case jumpToThread5 = "thread.jump.5"
    case jumpToThread6 = "thread.jump.6"
    case jumpToThread7 = "thread.jump.7"
    case jumpToThread8 = "thread.jump.8"
    case jumpToThread9 = "thread.jump.9"
    case chooseModel = "modelPicker.toggle"
    case reasoningEffort = "composer.effort"
    case accessMode = "composer.mode"
    case planMode = "composer.planMode"
    case renameThread = "thread.rename"
    case pinThread = "thread.pin"
    case archiveThread = "thread.archive"
    case copyThreadPath = "thread.copyPath"
    case deleteThread = "thread.delete"
    // Help: the GitHub issue forms (`CommunityLink`), with no shortcut until the user gives them one.
    case reportIssue = "help.reportIssue"
    case requestFeature = "help.requestFeature"

    /// The menu bar menu a command is in.
    public enum Menu: Sendable, CaseIterable {
        case file
        case edit
        case view
        case thread
        case help

        public nonisolated var title: String {
            switch self {
            case .file: String(localized: "File")
            case .edit: String(localized: "Edit")
            case .view: String(localized: "View")
            case .thread: String(localized: "Thread")
            case .help: String(localized: "Help")
            }
        }
    }

    public nonisolated var id: String { rawValue }

    /// The command for "Go to Thread `index`" (1–9).
    public nonisolated static func jumpToThread(_ index: Int) -> KeyCommand? {
        KeyCommand(rawValue: "thread.jump.\(index)")
    }

    /// 1–9 for the "Go to Thread" commands.
    public nonisolated var threadJumpIndex: Int? {
        guard rawValue.hasPrefix("thread.jump.") else { return nil }
        return Int(rawValue.dropFirst("thread.jump.".count))
    }

    public nonisolated var menu: Menu {
        switch self {
        case .newThread, .newChat, .addProject, .openInEditor, .revealInFinder: .file
        case .addToComposer, .searchThreads: .edit
        case .toggleSidebar, .toggleTerminal, .toggleDiff, .showSchedules, .commandPalette, .increaseFontSize,
            .decreaseFontSize, .resetFontSize, .showArchive:
            .view
        case .reportIssue, .requestFeature: .help
        default: .thread
        }
    }

    /// The command's name in the Keyboard pane. A menu item whose title changes (Show Sidebar, Hide Sidebar) has one
    /// name for both.
    public nonisolated var title: String {
        if let index = threadJumpIndex { return String(localized: "Go to Thread \(index)") }
        switch self {
        case .newThread: return String(localized: "New Thread")
        case .newChat: return String(localized: "New Chat")
        case .addProject: return String(localized: "Add Project…")
        case .openInEditor: return String(localized: "Open in Editor")
        case .revealInFinder: return String(localized: "Reveal in Finder")
        case .addToComposer: return String(localized: "Add Selection to Composer")
        case .searchThreads: return String(localized: "Search Threads")
        case .toggleSidebar: return String(localized: "Show or Hide Sidebar")
        case .toggleTerminal: return String(localized: "Show or Hide Terminal")
        case .toggleDiff: return String(localized: "Show or Hide Diff")
        case .showSchedules: return String(localized: "Show or Hide Scheduled Tasks")
        case .commandPalette: return String(localized: "Command Palette…")
        case .increaseFontSize: return String(localized: "Increase Font Size")
        case .decreaseFontSize: return String(localized: "Decrease Font Size")
        case .resetFontSize: return String(localized: "Reset Font Size")
        case .stopTurn: return String(localized: "Stop")
        case .previousThread: return String(localized: "Previous Thread")
        case .nextThread: return String(localized: "Next Thread")
        case .chooseModel: return String(localized: "Choose Agent and Model…")
        case .reasoningEffort: return String(localized: "Reasoning Effort…")
        case .accessMode: return String(localized: "Access…")
        case .planMode: return String(localized: "Plan Mode")
        case .renameThread: return String(localized: "Rename…")
        case .pinThread: return String(localized: "Pin or Unpin Thread")
        case .archiveThread: return String(localized: "Archive or Unarchive Thread")
        case .copyThreadPath: return String(localized: "Copy Path")
        case .deleteThread: return String(localized: "Delete Thread…")
        case .showArchive: return String(localized: "Archived Threads…")
        case .reportIssue: return String(localized: "Report an Issue…")
        case .requestFeature: return String(localized: "Request a Feature…")
        default: return rawValue
        }
    }

    /// The shortcut the command has until the user changes it.
    public nonisolated var defaultShortcut: KeyShortcut? { Self.defaults[self] }

    private nonisolated static let defaults: [KeyCommand: KeyShortcut] = {
        var defaults: [KeyCommand: String] = [
            .newThread: "mod+n", .newChat: "mod+shift+n", .addProject: "mod+shift+o", .openInEditor: "mod+o", .searchThreads: "mod+alt+f",
            // As in Cursor and VS Code, which add the selection to the chat with Command-L.
            .addToComposer: "mod+l",
            .toggleSidebar: "mod+b", .toggleTerminal: "mod+j", .toggleDiff: "mod+d", .commandPalette: "mod+k",
            .increaseFontSize: "mod++", .decreaseFontSize: "mod+-", .resetFontSize: "mod+0", .stopTurn: "mod+.",
            .previousThread: "mod+shift+[", .nextThread: "mod+shift+]", .chooseModel: "mod+shift+m",
            .reasoningEffort: "mod+shift+e", .accessMode: "mod+shift+a", .pinThread: "mod+shift+p",
            // ⌘R renames the open thread in the sidebar. A focused terminal and the browser panel leave it to the menu, so
            // it renames from there too (a web page that handles ⌘R itself gets it first, as with any menu shortcut).
            .renameThread: "mod+r",
            // ⌘W puts the open thread away in the archive, where it can be brought back. File › Close Window moves to ⌘⇧W,
            // and other windows still close with ⌘W.
            .archiveThread: "mod+w", .showArchive: "mod+alt+a",
            // Beside ⌥⌘A's Archived Threads in the View menu; free in macOS, the terminal and the browser panel.
            .showSchedules: "mod+alt+s",
        ]
        for index in 1...9 {
            if let command = jumpToThread(index) { defaults[command] = "mod+\(index)" }
        }
        return defaults.mapValues(KeyShortcut.builtIn)
    }()
}

/// The shortcut of every `KeyCommand`: the user's override when Coincide can use it, otherwise the default.
public struct KeyBindings: Equatable, Sendable {
    /// A saved override Coincide ignores, so its command keeps the default shortcut (T3's keybindings config issues).
    public struct Issue: Hashable, Sendable, Identifiable {
        public enum Reason: Hashable, Sendable {
            /// No command has this id: a typo, or a command of a newer version.
            case unknownCommand
            /// The text is not a shortcut.
            case unreadable
            /// The shortcut has neither Command nor Control, so as a menu shortcut it would take the key from text fields.
            case needsCommandOrControl
        }

        public let commandID: String
        public let value: String
        public let reason: Reason

        public nonisolated var id: String { commandID }
    }

    private let shortcuts: [KeyCommand: KeyShortcut]
    /// Commands whose shortcut differs from the default.
    public let customized: Set<KeyCommand>
    /// Overrides that were ignored, by command id.
    public let issues: [Issue]

    /// Applies `overrides` (`AppSettings.shortcutOverrides`) to the defaults.
    public nonisolated init(overrides: [String: String] = [:]) {
        var shortcuts: [KeyCommand: KeyShortcut] = [:]
        var customized: Set<KeyCommand> = []
        var issues: [Issue] = []
        for command in KeyCommand.allCases { shortcuts[command] = command.defaultShortcut }
        for (id, value) in overrides {
            guard let command = KeyCommand(rawValue: id) else {
                issues.append(Issue(commandID: id, value: value, reason: .unknownCommand))
                continue
            }
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                shortcuts[command] = nil
                if command.defaultShortcut != nil { customized.insert(command) }
                continue
            }
            guard let shortcut = KeyShortcut(value) else {
                issues.append(Issue(commandID: id, value: value, reason: .unreadable))
                continue
            }
            guard shortcut.isUsableInMenus else {
                issues.append(Issue(commandID: id, value: value, reason: .needsCommandOrControl))
                continue
            }
            shortcuts[command] = shortcut
            if shortcut != command.defaultShortcut { customized.insert(command) }
        }
        self.shortcuts = shortcuts
        self.customized = customized
        self.issues = issues.sorted { $0.commandID < $1.commandID }
    }

    /// The command's shortcut, or nil when it has none.
    public nonisolated func shortcut(for command: KeyCommand) -> KeyShortcut? { shortcuts[command] }

    public nonisolated func isCustomized(_ command: KeyCommand) -> Bool { customized.contains(command) }

    /// Commands set to `shortcut`, in menu-bar order.
    public nonisolated func commands(using shortcut: KeyShortcut) -> [KeyCommand] {
        KeyCommand.allCases.filter { shortcuts[$0] == shortcut }
    }

    /// The command `shortcut` runs: of the commands set to it, the first changed one in menu-bar order, otherwise the
    /// first one.
    public nonisolated func command(runBy shortcut: KeyShortcut) -> KeyCommand? {
        let commands = commands(using: shortcut)
        return commands.first(where: customized.contains) ?? commands.first
    }

    /// The shortcut the command's menu item gets: its shortcut, unless that runs another command (`command(runBy:)`)
    /// or belongs to one of the menu bar's fixed items (`fixed`), which keep theirs as AppKit's standard items do.
    public nonisolated func menuShortcut(for command: KeyCommand, keeping fixed: Set<KeyShortcut> = []) -> KeyShortcut? {
        guard let shortcut = shortcuts[command], self.command(runBy: shortcut) == command, !fixed.contains(shortcut) else {
            return nil
        }
        return shortcut
    }

    /// The modifiers of the Go to Thread commands' menu shortcuts (`menuShortcut(for:keeping:)`), each once, in the
    /// commands' order. Holding one of them shows the sidebar's thread numbers, as T3 shows its jump hints while the
    /// modifiers of a jump shortcut are held.
    public nonisolated func threadJumpModifiers(keeping fixed: Set<KeyShortcut> = []) -> [KeyModifiers] {
        var result: [KeyModifiers] = []
        for index in 1...9 {
            guard let command = KeyCommand.jumpToThread(index), let modifiers = menuShortcut(for: command, keeping: fixed)?.modifiers,
                !result.contains(modifiers)
            else { continue }
            result.append(modifiers)
        }
        return result
    }

    /// What else uses the command's shortcut: other commands in menu-bar order, then the reserved shortcuts it
    /// matches, in the order given.
    public nonisolated func conflicts(for command: KeyCommand, reserved: [ReservedShortcut]) -> [ShortcutConflict] {
        guard let shortcut = shortcuts[command] else { return [] }
        let winner = self.command(runBy: shortcut)
        let commands = commands(using: shortcut).filter { $0 != command }.map {
            ShortcutConflict.command($0, runsInstead: $0 == winner)
        }
        var seen: Set<ReservedShortcut> = []
        let others = reserved.filter { $0.shortcut == shortcut && seen.insert($0).inserted }.map(ShortcutConflict.reserved)
        return commands + others
    }

    /// Commands whose shortcut has a conflict worth a warning, in menu-bar order.
    public nonisolated func commandsWithConflicts(reserved: [ReservedShortcut]) -> [KeyCommand] {
        KeyCommand.allCases.filter { conflicts(for: $0, reserved: reserved).contains(where: \.isWarning) }
    }
}

/// A shortcut something other than Coincide's commands uses.
public struct ReservedShortcut: Hashable, Sendable {
    public enum Owner: Hashable, Sendable {
        /// macOS handles it before Coincide sees it.
        case system
        /// One of Coincide's own shortcuts that can't be changed, such as Edit › Copy or sending from the composer.
        /// Menu items keep theirs (`KeyBindings.menuShortcut(for:keeping:)`); other keys go to the command.
        case app
        /// A key that a part of the window (named by an id such as "terminal") keeps for itself while it has focus.
        case focusedView(String)
    }

    public let shortcut: KeyShortcut
    /// What uses it: "Spotlight", "Edit › Copy", "Split right".
    public let title: String
    public let owner: Owner

    public nonisolated init(shortcut: KeyShortcut, title: String, owner: Owner) {
        self.shortcut = shortcut
        self.title = title
        self.owner = owner
    }

    /// Shortcuts macOS keeps for itself in a standard setup (System Settings › Keyboard › Keyboard Shortcuts) or adds
    /// to every app, so a menu command never receives them.
    public nonisolated static let macOS: [ReservedShortcut] = [
        ("mod+space", String(localized: "Spotlight")),
        ("mod+alt+space", String(localized: "Finder search window")),
        ("ctrl+space", String(localized: "Select the previous input source")),
        ("ctrl+alt+space", String(localized: "Select the next input source")),
        ("mod+tab", String(localized: "Switch apps")),
        ("mod+shift+tab", String(localized: "Switch apps")),
        ("mod+`", String(localized: "Move focus to the next window")),
        ("mod+shift+`", String(localized: "Move focus to the previous window")),
        ("mod+shift+3", String(localized: "Screenshot")),
        ("mod+shift+4", String(localized: "Screenshot of an area")),
        ("mod+shift+5", String(localized: "Screenshot and recording options")),
        ("mod+ctrl+shift+3", String(localized: "Copy a screenshot")),
        ("mod+ctrl+shift+4", String(localized: "Copy a screenshot of an area")),
        ("mod+ctrl+q", String(localized: "Lock Screen")),
        ("mod+shift+q", String(localized: "Log Out")),
        ("mod+alt+shift+q", String(localized: "Log Out")),
        ("mod+alt+esc", String(localized: "Force Quit")),
        ("mod+ctrl+space", String(localized: "Emoji & Symbols")),
        ("mod+shift+/", String(localized: "Search the Help menu")),
        ("mod+alt+d", String(localized: "Show or hide the Dock")),
        ("ctrl+arrowup", String(localized: "Mission Control")),
        ("ctrl+arrowdown", String(localized: "Application windows")),
        ("ctrl+arrowleft", String(localized: "Move left a space")),
        ("ctrl+arrowright", String(localized: "Move right a space")),
        ("ctrl+f2", String(localized: "Move focus to the menu bar")),
        ("ctrl+f3", String(localized: "Move focus to the Dock")),
        ("ctrl+f4", String(localized: "Move focus to the active or next window")),
        ("ctrl+f5", String(localized: "Move focus to the window toolbar")),
        ("ctrl+f6", String(localized: "Move focus to the floating window")),
        ("ctrl+f7", String(localized: "Change the way Tab moves focus")),
        ("ctrl+f8", String(localized: "Move focus to status menus")),
    ].map { ReservedShortcut(shortcut: .builtIn($0), title: $1, owner: .system) }
}

/// Something else that uses a command's shortcut.
public enum ShortcutConflict: Hashable, Sendable {
    /// Another command has the same shortcut. `runsInstead` is true when the shortcut runs that command, not this one.
    case command(KeyCommand, runsInstead: Bool)
    case reserved(ReservedShortcut)

    /// False for a key a focused part of the window keeps for itself: the command still runs everywhere else.
    public nonisolated var isWarning: Bool {
        if case .reserved(let reserved) = self, case .focusedView = reserved.owner { return false }
        return true
    }
}
