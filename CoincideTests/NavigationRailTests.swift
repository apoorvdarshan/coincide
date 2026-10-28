import AppKit
import Testing

@testable import Coincide

@MainActor
struct NavigationRailTests {
    /// The rail's buttons paint their highlight across their frames, so the frames must be the laid-out squares with
    /// a gap between them; the push style's alignment insets once made neighbouring highlights touch.
    @Test func railButtonsAreSquaresWithGapsBetweenThem() throws {
        let rail = NavigationRailViewController()
        rail.view.frame = NSRect(x: 0, y: 0, width: NavigationRailViewController.width, height: 800)
        rail.view.layoutSubtreeIfNeeded()
        var buttons: [RailButton] = []
        func collect(_ view: NSView) {
            if let button = view as? RailButton { buttons.append(button) }
            view.subviews.forEach(collect)
        }
        collect(rail.view)
        #expect(buttons.count == 8)
        let frames = buttons.map { $0.convert($0.bounds, to: rail.view) }.sorted { $0.minY < $1.minY }
        for frame in frames {
            #expect(frame.width == RailButton.side)
            #expect(frame.height == RailButton.side)
        }
        for (upper, lower) in zip(frames, frames.dropFirst()) {
            #expect(lower.minY - upper.maxY >= 4, "\(upper) and \(lower) leave no gap")
        }
    }
}
