import CoreGraphics
import Testing
@testable import Coincide

/// The agent cursor lands on the display the agent acts on, including displays above, below or left of the main one
/// (trycua/cua#5336). AppKit frames below are what `NSScreen.frame` reports for each layout.
struct AgentCursorGeometryTests {
    /// Built-in main display 1470×956 at the origin, external 1920×1080 above it at x = -227, y = -1080 (top-left).
    private let above = (primaryHeight: CGFloat(956), frames: [
        CGRect(x: 0, y: 0, width: 1470, height: 956), CGRect(x: -227, y: 956, width: 1920, height: 1080),
    ])
    /// Main 3008×1692, built-in 1800×1169 directly below it, portrait 1080×1920 to the left at x = -1080, y = -228.
    private let belowAndLeft = (primaryHeight: CGFloat(1692), frames: [
        CGRect(x: 0, y: 0, width: 3008, height: 1692), CGRect(x: 0, y: -1169, width: 1800, height: 1169),
        CGRect(x: -1080, y: 0, width: 1080, height: 1920),
    ])

    private func screen(for topLeft: CGPoint, in layout: (primaryHeight: CGFloat, frames: [CGRect])) -> (Int?, CGPoint) {
        let point = AgentCursorGeometry.appKitPoint(fromTopLeft: topLeft, primaryHeight: layout.primaryHeight)
        guard let index = AgentCursorGeometry.screenIndex(containing: point, in: layout.frames) else { return (nil, point) }
        return (index, AgentCursorGeometry.local(point, in: layout.frames[index]))
    }

    @Test func aPointOnADisplayAboveTheMainOneIsDrawnThere() {
        let (index, local) = screen(for: CGPoint(x: 733, y: -540), in: above)
        #expect(index == 1)
        #expect(local == CGPoint(x: 960, y: 540))
        let (main, mainLocal) = screen(for: CGPoint(x: 100, y: 100), in: above)
        #expect(main == 0)
        #expect(mainLocal == CGPoint(x: 100, y: 856))
    }

    @Test func displaysBelowAndLeftOfTheMainOneGetTheirOwnPoints() {
        let (below, belowLocal) = screen(for: CGPoint(x: 900, y: 2000), in: belowAndLeft)
        #expect(below == 1)
        #expect(belowLocal == CGPoint(x: 900, y: 861))
        let (left, leftLocal) = screen(for: CGPoint(x: -540, y: 500), in: belowAndLeft)
        #expect(left == 2)
        #expect(leftLocal == CGPoint(x: 540, y: 1192))
    }

    @Test func aPointOffEveryDisplayIsKeptOnTheNearestOne() {
        let outside = AgentCursorGeometry.appKitPoint(fromTopLeft: CGPoint(x: 5000, y: -540), primaryHeight: above.primaryHeight)
        #expect(AgentCursorGeometry.screenIndex(containing: outside, in: above.frames) == 1)
        let clamped = AgentCursorGeometry.clamped(outside, in: above.frames)
        #expect(above.frames[1].contains(clamped))
        #expect(AgentCursorGeometry.screenIndex(containing: .zero, in: []) == nil)
    }

    @Test func aCursorOnAnEdgeIsDrawnOnBothDisplays() {
        // The tip sits just inside the main display under the external one; the cursor hangs below it, so only main.
        let mainOnly = CGPoint(x: 400, y: 950)
        #expect(AgentCursorGeometry.screensShowing(tip: mainOnly, in: above.frames) == [0])
        // A tip just over the boundary on the external display hangs down onto the main one: both draw it.
        let straddling = CGPoint(x: 400, y: 960)
        #expect(AgentCursorGeometry.screensShowing(tip: straddling, in: above.frames) == [0, 1])
    }

    @Test func glidesEaseFromStartToEnd() {
        let start = CGPoint(x: 0, y: 0), end = CGPoint(x: 100, y: -200)
        #expect(AgentCursorGeometry.glide(from: start, to: end, progress: 0) == start)
        #expect(AgentCursorGeometry.glide(from: start, to: end, progress: 1) == end)
        #expect(AgentCursorGeometry.glide(from: start, to: end, progress: 2) == end)
        #expect(AgentCursorGeometry.glide(from: start, to: end, progress: 0.5) == CGPoint(x: 50, y: -100))
        let early = AgentCursorGeometry.glide(from: start, to: end, progress: 0.25)
        #expect(early.x > 0 && early.x < 25)
    }
}
