import CoreGraphics
import Foundation

// MARK: - The window

/// A window on screen as the window server lists it (`CGWindowListCopyWindowInfo`), with what choosing the one to
/// capture needs.
public struct AppshotWindow: Hashable, Sendable {
    public var id: UInt32
    public var ownerPID: Int32
    public var ownerName: String
    /// The window's title. The window server gives other apps' titles only to apps allowed to record the screen.
    public var title: String?
    /// The window level; 0 is ordinary app windows, above them are menus, panels of the menu bar and the Dock.
    public var layer: Int
    /// In points, from the top left of the main display.
    public var bounds: CGRect
    public var alpha: Double
    /// False for windows that asked not to be captured (`NSWindow.sharingType = .none`), such as password managers'.
    public var isShareable: Bool
    /// The owner is an app in the Dock (a regular activation policy), not a helper or a menu bar extra.
    public var ownerIsRegularApp: Bool

    public nonisolated init(
        id: UInt32, ownerPID: Int32, ownerName: String, title: String? = nil, layer: Int = 0, bounds: CGRect,
        alpha: Double = 1, isShareable: Bool = true, ownerIsRegularApp: Bool = true
    ) {
        self.id = id
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.title = title
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
        self.isShareable = isShareable
        self.ownerIsRegularApp = ownerIsRegularApp
    }

    /// Reads one entry of `CGWindowListCopyWindowInfo`; nil when it lacks the window's number, owner or bounds.
    /// `isRegularApp` says whether a process is an app in the Dock.
    public nonisolated init?(windowListEntry entry: [String: Any], isRegularApp: (Int32) -> Bool = { _ in true }) {
        guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
            let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            let boundsInfo = entry[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary)
        else { return nil }
        let title = (entry[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let sharing = (entry[kCGWindowSharingState as String] as? NSNumber)?.uint32Value
        self.init(
            id: number, ownerPID: pid, ownerName: entry[kCGWindowOwnerName as String] as? String ?? "", title: title,
            layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0, bounds: bounds,
            alpha: (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
            isShareable: sharing != CGWindowSharingType.none.rawValue, ownerIsRegularApp: isRegularApp(pid))
    }
}

/// Which window an appshot captures.
public enum AppshotWindowChoice: Equatable, Sendable {
    case capture(AppshotWindow)
    /// The frontmost window asked not to be captured. No other window is taken in its place.
    case protected(AppshotWindow)
    /// No app window is in front: the front app has none open, or only Coincide's are on screen.
    case none
}

public enum AppshotWindowPicker {
    /// Smaller windows are a tool tip, a drag image or another app's helper, never what the user is looking at.
    public nonisolated static let minimumSide: CGFloat = 40

    /// The frontmost window of the frontmost app that isn't `excluded` (Coincide). `windows` are front to back, as the
    /// window server lists them. While another app is in front (`frontmostPID`) only its windows count, so a window
    /// of an app behind it is never taken instead; while Coincide is, the app whose window is next in front.
    public nonisolated static func choose(
        from windows: [AppshotWindow], frontmostPID: Int32?, excluding excluded: Set<Int32>
    ) -> AppshotWindowChoice {
        let candidates = windows.filter { window in
            window.layer == 0 && window.alpha > 0 && window.bounds.width >= minimumSide
                && window.bounds.height >= minimumSide && !excluded.contains(window.ownerPID)
        }
        let window: AppshotWindow?
        if let frontmostPID, !excluded.contains(frontmostPID) {
            window = candidates.first { $0.ownerPID == frontmostPID }
        } else {
            window = candidates.first { $0.ownerIsRegularApp }
        }
        guard let window else { return .none }
        return window.isShareable ? .capture(window) : .protected(window)
    }
}

// MARK: - The thread

/// Which thread an appshot goes to: the one the user interacted with in the last minute, as in ChatGPT, otherwise a
/// new chat. Times are seconds on one steady clock (system uptime), so changing the Mac's clock doesn't matter.
public struct AppshotDestination: Sendable {
    public nonisolated static let recentInteraction: TimeInterval = 60

    public private(set) var thread: UUID?
    public private(set) var interactedAt: TimeInterval?

    public nonisolated init() {}

    /// The user interacted with `thread` (nil: with no thread) at `time`. A later appshot within a minute joins it,
    /// so consecutive appshots go to the same chat.
    public nonisolated mutating func recordInteraction(with thread: UUID?, at time: TimeInterval) {
        if let interactedAt, time < interactedAt { return }
        self.thread = thread
        interactedAt = time
    }

    /// The thread for an appshot taken at `time`, or nil to start a new chat. `isAvailable` says whether a thread still
    /// takes messages (it wasn't deleted or archived).
    public nonisolated func target(at time: TimeInterval, isAvailable: (UUID) -> Bool) -> UUID? {
        guard let thread, let interactedAt, time >= interactedAt, time - interactedAt <= Self.recentInteraction,
            isAvailable(thread)
        else { return nil }
        return thread
    }
}
