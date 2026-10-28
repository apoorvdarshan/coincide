import CoincideKit
import Foundation

/// What a send from the composer does, ported from T3 Code's `resolveComposerDispatchMode`: while a turn runs, the
/// follow-up behavior setting picks steer or queue, and the alternate send does the other for one message.
nonisolated enum ComposerDispatch: Equatable, Sendable {
    /// No turn runs, so the message starts one.
    case send
    /// The message goes into the running turn (`ThreadRunner.steer`).
    case steer
    /// The message waits for the running turn to finish.
    case queue

    /// What the main send does while a turn runs: the setting, except that it steers while an approval is shown, as in
    /// T3 Code. Sending declines the approval to redirect the agent, so the message must reach the waiting turn rather
    /// than queue behind it.
    static func followUpBehavior(_ setting: FollowUpBehavior, approvalShown: Bool) -> FollowUpBehavior {
        approvalShown ? .steer : setting
    }

    /// The send's outcome. `alternate` is the alternate send; a turn that can't take a message now
    /// (`ThreadRunner.canSteer`) gets it queued either way.
    static func resolve(running: Bool, canSteer: Bool, alternate: Bool, behavior: FollowUpBehavior) -> ComposerDispatch {
        guard running else { return .send }
        guard canSteer else { return .queue }
        switch alternate ? behavior.opposite : behavior {
        case .steer: return .steer
        case .queue: return .queue
        }
    }
}

/// The composer's send keys, which follow the "Send messages with" setting and can't be changed. The menu bar sees
/// keys first, so a key a menu command was given never reaches the composer; it is left out here, and the tooltips
/// built from these keys don't offer it.
struct ComposerSendKeys: Equatable {
    /// Sends, or does what the follow-up behavior says while a turn runs: ↩, or ⌘↩ when Return inserts a new line.
    let send: KeyShortcut?
    /// The alternate send, which does the other while a turn runs: ⌘↩, or ⇧⌘↩ when ⌘↩ sends.
    let alternate: KeyShortcut?
    /// Sends the oldest queued message into the running turn, as T3 Code's steer-queued shortcut: ⇧⌘↩, when Return
    /// sends. Otherwise ⇧⌘↩ is the alternate send.
    let steerQueued: KeyShortcut?

    /// `menuHas` says whether a menu item has a shortcut (`KeyBindingsController.menuBarHas(_:)`).
    init(sendOnReturn: Bool, menuHas: (KeyShortcut) -> Bool = { _ in false }) {
        func reaching(_ shortcut: KeyShortcut) -> KeyShortcut? { menuHas(shortcut) ? nil : shortcut }
        send = reaching(sendOnReturn ? Self.returnKey : Self.commandReturn)
        alternate = reaching(sendOnReturn ? Self.commandReturn : Self.shiftCommandReturn)
        steerQueued = sendOnReturn ? reaching(Self.shiftCommandReturn) : nil
    }

    /// The send button's tooltip: what a click and the send keys do now, and while a turn runs what the alternate send
    /// and ⌘-click do instead, as T3 Code's "Click to steer, ⌘-click or ⌘↩ to queue".
    func sendToolTip(running: Bool, canSteer: Bool, behavior: FollowUpBehavior) -> String {
        guard running else {
            let text = String(localized: "Send")
            return send.map { String(localized: "\(text) (\($0.displayString))") } ?? text
        }
        guard canSteer else { return String(localized: "Queue message. It is sent when the current turn finishes.") }
        let others = alternate.map { String(localized: "\($0.displayString) or ⌘-click") } ?? String(localized: "⌘-click")
        switch (behavior, send?.displayString) {
        case (.steer, let keys?):
            return String(localized: "Steer: send into the current turn (\(keys)). \(others) queues it for after the turn.")
        case (.steer, nil):
            return String(localized: "Steer: send into the current turn. \(others) queues it for after the turn.")
        case (.queue, let keys?):
            return String(localized: "Queue: send when the current turn finishes (\(keys)). \(others) sends it into the current turn instead.")
        case (.queue, nil):
            return String(localized: "Queue: send when the current turn finishes. \(others) sends it into the current turn instead.")
        }
    }

    private static let returnKey = builtIn(key: "enter", modifiers: [])
    private static let commandReturn = builtIn(key: "enter", modifiers: .command)
    private static let shiftCommandReturn = builtIn(key: "enter", modifiers: [.shift, .command])

    private static func builtIn(key: String, modifiers: KeyModifiers) -> KeyShortcut {
        guard let shortcut = KeyShortcut(key: key, modifiers: modifiers) else { preconditionFailure("Invalid key \(key)") }
        return shortcut
    }
}
