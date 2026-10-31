import Foundation

/// Tells "both ⌘ keys pressed together" apart from everyday ⌘ use, from the modifier flags of `flagsChanged` events.
///
/// The flags are `NSEvent.ModifierFlags.rawValue` (or `CGEventFlags.rawValue`, the same bits), whose low bits say which
/// side's key is down (IOKit's `NX_DEVICELCMDKEYMASK` and `NX_DEVICERCMDKEYMASK`). A chord starts when the first ⌘
/// goes down and ends when both are up. It fires once, when the second ⌘ goes down, unless:
/// - Shift, Control, Option or Fn was held at any point of it, or a key was pressed since it started (⌘C, then the
///   other ⌘), so shortcuts never take appshots;
/// - the second ⌘ came more than `pairingWindow` after the first, as when one ⌘ is held for ⌘-clicks;
/// - it came within `cooldown` of the last appshot, so a bouncing key or a quick double press takes one.
public struct BothCommandKeysDetector: Sendable {
    /// `NX_DEVICELCMDKEYMASK` and `NX_DEVICERCMDKEYMASK`.
    public nonisolated static let leftCommand: UInt = 0x0000_0008
    public nonisolated static let rightCommand: UInt = 0x0000_0010
    /// Shift, Control, Option and Fn (`NSEvent.ModifierFlags`). Caps Lock is a state, not a held key, so it doesn't count.
    public nonisolated static let otherModifiers: UInt = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 23)

    public var pairingWindow: TimeInterval
    public var cooldown: TimeInterval

    /// When the chord's first ⌘ went down; nil while no ⌘ is down.
    private var chordStart: TimeInterval?
    /// Something else was pressed during the chord, or it already fired or was turned down.
    private var settled = false
    private var lastFire: TimeInterval?

    public nonisolated init(pairingWindow: TimeInterval = 1, cooldown: TimeInterval = 1) {
        self.pairingWindow = pairingWindow
        self.cooldown = cooldown
    }

    /// Takes a `flagsChanged` event's flags at `time` (seconds, the events' clock: `NSEvent.timestamp`, system uptime).
    /// `lastKeyDown` is when a key last went down on that clock, when known
    /// (`CGEventSource.secondsSinceLastEventType`). Returns true when this event completes the chord.
    public nonisolated mutating func flagsChanged(_ flags: UInt, at time: TimeInterval, lastKeyDown: TimeInterval? = nil) -> Bool {
        let left = flags & Self.leftCommand != 0
        let right = flags & Self.rightCommand != 0
        guard left || right else {
            chordStart = nil
            settled = false
            return false
        }
        let start = chordStart ?? time
        chordStart = start
        if flags & Self.otherModifiers != 0 { settled = true }
        if let lastKeyDown, lastKeyDown >= start { settled = true }
        guard left, right, !settled else { return false }
        // Whatever happens now, this chord is decided: holding both keys longer, or lifting and pressing one of
        // them again while the other stays down, doesn't take another.
        settled = true
        guard time - start <= pairingWindow else { return false }
        if let lastFire, time - lastFire < cooldown, time >= lastFire { return false }
        lastFire = time
        return true
    }

    /// A key went down: a chord in progress is a shortcut, not an appshot. For events Coincide sees itself; others
    /// come in as `lastKeyDown`.
    public nonisolated mutating func keyDown() {
        if chordStart != nil { settled = true }
    }
}
