import Foundation

/// Whether usage reads as what is used ("62% used", bars that fill up) or what is left ("38% left", bars that drain).
/// The user picks it in Settings › Usage or the menu bar popover; the menu bar title, the popover and Settings › Usage
/// all follow it. Colors keep warning as the limit nears either way.
public enum UsageDisplayMode: String, Codable, CaseIterable, Hashable, Sendable {
    case used
    case remaining
}

extension UsageLimitWindow {
    /// The whole percent shown in `mode`: used, or what is left. The two always add up to 100.
    public nonisolated func shownPercent(_ mode: UsageDisplayMode) -> Int {
        let used = Int(usedPercent.rounded())
        return mode == .used ? used : 100 - used
    }

    /// How much of a bar is filled in `mode`, 0–1: what is used, or what is left.
    public nonisolated func barFill(_ mode: UsageDisplayMode) -> Double {
        mode == .used ? usedPercent / 100 : 1 - usedPercent / 100
    }

    /// Where the pace mark goes on a bar in `mode`, 0–1: where the fill would be with even spending across the window.
    /// Spending faster than that puts the fill past the mark when showing what is used, and short of it when showing
    /// what is left. Nil without the window's length and reset time.
    public nonisolated func paceMark(at now: Date, mode: UsageDisplayMode) -> Double? {
        elapsedShare(at: now).map { mode == .used ? $0 : 1 - $0 }
    }
}
