import Foundation

/// What takes an appshot: pressing both ⌘ keys together, as in ChatGPT, or a shortcut the user records.
public enum AppshotTrigger: String, Codable, CaseIterable, Sendable {
    case bothCommandKeys
    case shortcut
}

/// A shortcut recorded for appshots: the key as menus write it (`KeyShortcut`'s text, such as `mod+ctrl+s`) for
/// showing it, and the key's virtual key code (`kVK_…`), which the system's hotkey registration takes.
public struct AppshotShortcut: Codable, Hashable, Sendable {
    public var keyCode: Int
    public var shortcut: String

    public nonisolated init(keyCode: Int, shortcut: KeyShortcut) {
        self.keyCode = keyCode
        self.shortcut = shortcut.stringValue
    }

    /// The shortcut, or nil when the saved text isn't one, or the key code isn't a key.
    public nonisolated var keyShortcut: KeyShortcut? {
        guard (0...0x7F).contains(keyCode), let shortcut = KeyShortcut(shortcut), shortcut.isUsableInMenus else { return nil }
        return shortcut
    }
}

/// Settings › Appshots: capturing the frontmost window of another app into a chat (`AppshotController`). Off by
/// default; while off, Coincide watches no keys at all.
public struct AppshotSettings: Codable, Hashable, Sendable {
    public var enabled = false
    public var trigger: AppshotTrigger = .bothCommandKeys
    /// The shortcut for `.shortcut`; nil until the user records one.
    public var shortcut: AppshotShortcut?
    /// Add the text the app exposes in that window through Accessibility, as a "Window text" card.
    public var includesWindowText = true
    /// Play the screenshot sound when an appshot is taken, at the alert volume.
    public var playsSound = true

    public nonisolated init() {}

    /// A value this version can't read keeps its default, without losing the others.
    public nonisolated init(from decoder: Decoder) throws {
        let defaults = AppshotSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? defaults.enabled
        trigger = (try? container.decodeIfPresent(AppshotTrigger.self, forKey: .trigger)) ?? defaults.trigger
        shortcut = (try? container.decodeIfPresent(AppshotShortcut.self, forKey: .shortcut)) ?? defaults.shortcut
        includesWindowText = (try? container.decodeIfPresent(Bool.self, forKey: .includesWindowText)) ?? defaults.includesWindowText
        playsSound = (try? container.decodeIfPresent(Bool.self, forKey: .playsSound)) ?? defaults.playsSound
    }

    /// The recorded shortcut when it is the trigger and usable; nil otherwise.
    public nonisolated var activeShortcut: AppshotShortcut? {
        guard trigger == .shortcut, let shortcut, shortcut.keyShortcut != nil else { return nil }
        return shortcut
    }
}
