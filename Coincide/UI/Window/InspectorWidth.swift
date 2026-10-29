import Foundation

/// How the inspector, the panel at the window's right (diff, pull requests, browser preview), shares the space right
/// of the thread list with the chat. Every panel uses the same share, kept as a fraction of that space so it follows
/// the window: the chat and the panel split it half and half until the user drags the divider between them.
///
/// "Available" is the chat's width plus the panel's, the divider between them left out. The split view keeps the panel
/// at `ratio(for:)` times the chat, below the minimums: when the space runs short the panel gives way first, down to
/// its minimum, so the chat keeps room for the composer. The functions here are what that layout comes to.
nonisolated enum InspectorWidth {
    static let defaultFraction = 0.5
    /// The panel's narrowest: the diff's file list and the pull request list still read at this width.
    static let minimumPanelWidth = 320.0
    /// The chat's narrowest, so the composer's controls fit.
    static let minimumChatWidth = 420.0
    /// Shares outside this range are treated as damaged and clamped; the minimums decide in practice.
    static let fractionRange = 0.05...0.95

    /// A saved share as the layout uses it: the default when there is none or it is not a number, else clamped.
    static func normalized(_ fraction: Double?) -> Double {
        guard let fraction, fraction.isFinite else { return defaultFraction }
        return min(max(fraction, fractionRange.lowerBound), fractionRange.upperBound)
    }

    /// The panel's width for `fraction` of `available` points: the share, shrunk to leave the chat its minimum but never
    /// below the panel's own. When both minimums don't fit, the panel keeps its minimum (see `shortfall`).
    static func panelWidth(fraction: Double?, available: Double) -> Double {
        let wanted = normalized(fraction) * max(0, available)
        return max(minimumPanelWidth, min(wanted, available - minimumChatWidth))
    }

    /// The share a panel `width` points wide takes of `available`, after the same limits, so a drag past a minimum
    /// saves where the divider actually stopped. Nil when there is no space to measure against.
    static func fraction(panelWidth width: Double, available: Double) -> Double? {
        guard available > 0, width.isFinite else { return nil }
        let limited = max(minimumPanelWidth, min(width, available - minimumChatWidth))
        return normalized(limited / available)
    }

    /// The panel's width as a multiple of the chat's: `fraction` of the whole is `fraction / (1 - fraction)` of the rest.
    static func ratio(for fraction: Double?) -> Double {
        let share = normalized(fraction)
        return share / (1 - share)
    }

    /// How many points the window has to grow for the chat and the panel both to get their minimums.
    static func shortfall(available: Double) -> Double {
        max(0, minimumPanelWidth + minimumChatWidth - available)
    }
}
