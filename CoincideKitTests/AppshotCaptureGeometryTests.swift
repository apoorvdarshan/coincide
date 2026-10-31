import CoreGraphics
import Foundation
import Testing

@testable import CoincideKit

/// The size of an appshot's picture: the window's own shape at its display's resolution. A window Chrome draws as a
/// toolbar strip in front of the page once came out as a 2000×110 picture with the page squeezed into one end.
struct AppshotCaptureGeometryTests {
    private static let chrome: Int32 = 500
    private static let notes: Int32 = 600

    private static func window(_ id: UInt32, _ pid: Int32, _ frame: CGRect, layer: Int = 0, alpha: Double = 1) -> AppshotWindow {
        AppshotWindow(id: id, ownerPID: pid, ownerName: "App \(pid)", layer: layer, bounds: frame, alpha: alpha)
    }

    /// Chrome's windows as the window server listed them on a 1470×956-point display: the tab strip and toolbar
    /// (1470×81) in front, an overlay over it, then the page below.
    private static let strip = window(4297, chrome, CGRect(x: 0, y: 33, width: 1470, height: 81))
    private static let overlay = window(14580, chrome, CGRect(x: 0, y: 33, width: 1470, height: 149))
    private static let page = window(4294, chrome, CGRect(x: 0, y: 114, width: 1470, height: 842))
    private static let laptop = AppshotDisplay(frame: CGRect(x: 0, y: 0, width: 1470, height: 956), scale: 2)

    @Test func chromesToolbarStripIsCapturedWithThePage() {
        let menuBar = Self.window(1, 0, CGRect(x: 0, y: 0, width: 1470, height: 33), layer: 24)
        let behind = Self.window(9, Self.notes, CGRect(x: 100, y: 100, width: 600, height: 400))
        let windows = [menuBar, Self.strip, Self.overlay, Self.page, behind]
        #expect(AppshotWindowPicker.choose(from: windows, frontmostPID: Self.chrome, excluding: []) == .capture(Self.strip))
        #expect(AppshotCaptureGeometry.group(of: Self.strip, in: windows) == [Self.strip, Self.overlay, Self.page])
        let frame = AppshotCaptureGeometry.groupFrame(of: Self.strip, in: windows)
        #expect(frame == CGRect(x: 0, y: 33, width: 1470, height: 923))
        let scale = AppshotCaptureGeometry.scale(for: frame, displays: [Self.laptop], fallback: 1)
        let size = AppshotCaptureGeometry.pixelSize(for: frame, scale: scale)
        // The window's shape at Retina resolution, not the strip's 2940×162.
        #expect(size == AppshotPixelSize(width: 2940, height: 1846))
        // Picked from behind (a strip too thin to choose), the group is the same.
        #expect(AppshotCaptureGeometry.groupFrame(of: Self.page, in: windows) == frame)
    }

    @Test func aWindowStandsAloneUnlessTheSameAppsWindowsTouchItInOrder() {
        let front = Self.window(1, Self.notes, CGRect(x: 100, y: 100, width: 500, height: 400))
        let apart = Self.window(2, Self.notes, CGRect(x: 900, y: 100, width: 300, height: 300))
        let otherApp = Self.window(3, Self.chrome, CGRect(x: 100, y: 100, width: 500, height: 400))
        let touching = Self.window(4, Self.notes, CGRect(x: 100, y: 500, width: 500, height: 40))
        // Another window of the app elsewhere on screen isn't part of it.
        #expect(AppshotCaptureGeometry.group(of: front, in: [front, apart]) == [front])
        // A window touching its edge is, but not past another app's window in between.
        #expect(AppshotCaptureGeometry.group(of: front, in: [front, touching]) == [front, touching])
        #expect(AppshotCaptureGeometry.group(of: front, in: [front, otherApp, touching]) == [front])
        // Invisible windows and menus don't join, and an unlisted window is alone.
        let hidden = Self.window(5, Self.notes, touching.bounds, alpha: 0)
        let menu = Self.window(6, Self.notes, touching.bounds, layer: 101)
        #expect(AppshotCaptureGeometry.group(of: front, in: [front, hidden, menu]) == [front])
        #expect(AppshotCaptureGeometry.groupFrame(of: front, in: []) == front.bounds)
    }

    /// The laptop's display, a 1× display to its right reaching higher, and a 3× one above the laptop.
    private static let displays = [
        laptop,
        AppshotDisplay(frame: CGRect(x: 1470, y: -400, width: 2560, height: 1440), scale: 1),
        AppshotDisplay(frame: CGRect(x: 0, y: -1080, width: 1470, height: 1080), scale: 3),
    ]

    @Test(arguments: [
        // On the laptop.
        (CGRect(x: 100, y: 100, width: 1000, height: 625), CGFloat(2), 2000, 1250),
        // On the 1× display: its own scale, not the main display's.
        (CGRect(x: 1600, y: 0, width: 1200, height: 800), 1, 1200, 800),
        // On the 3× display above.
        (CGRect(x: 200, y: -900, width: 640, height: 400), 3, 1920, 1200),
        // Across two displays: the one with most of it.
        (CGRect(x: 1300, y: 100, width: 1000, height: 600), 1, 1000, 600),
        (CGRect(x: 900, y: 100, width: 800, height: 600), 2, 1600, 1200),
        // Partly off the left edge of every display: the whole window, the part off screen included.
        (CGRect(x: -300, y: 200, width: 1000, height: 625), 2, 2000, 1250),
        // Hanging below the laptop's bottom edge.
        (CGRect(x: 200, y: 800, width: 600, height: 500), 2, 1200, 1000),
        // Off every display: the nearest one's scale.
        (CGRect(x: 5000, y: 0, width: 400, height: 300), 1, 400, 300),
    ])
    func thePictureIsTheWindowAtItsDisplaysScale(frame: CGRect, scale: CGFloat, width: Int, height: Int) {
        let found = AppshotCaptureGeometry.scale(for: frame, displays: Self.displays, fallback: 2)
        #expect(found == scale)
        let size = AppshotCaptureGeometry.pixelSize(for: frame, scale: found)
        #expect(size == AppshotPixelSize(width: width, height: height))
        #expect(abs(size.aspect - frame.width / frame.height) < 0.01)
    }

    @Test func withoutDisplaysScreenCaptureKitsScaleIsUsed() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(AppshotCaptureGeometry.scale(for: frame, displays: [], fallback: 2) == 2)
        #expect(AppshotCaptureGeometry.scale(for: frame, displays: [], fallback: 0) == 1)
    }

    @Test func appKitScreensTurnIntoWindowServerCoordinates() {
        // A display to the right of a 956-point-high main display, its bottom 500 points above the main one's.
        let display = AppshotDisplay(appKitFrame: CGRect(x: 1470, y: 500, width: 1920, height: 1080), scale: 1, mainHeight: 956)
        #expect(display.frame == CGRect(x: 1470, y: -624, width: 1920, height: 1080))
        let main = AppshotDisplay(appKitFrame: CGRect(x: 0, y: 0, width: 1470, height: 956), scale: 2, mainHeight: 956)
        #expect(main.frame == CGRect(x: 0, y: 0, width: 1470, height: 956))
    }

    @Test func aHugeWindowIsCappedKeepingItsShape() {
        let size = AppshotCaptureGeometry.pixelSize(for: CGRect(x: 0, y: 0, width: 10000, height: 3000), scale: 2)
        #expect(size.width == AppshotCaptureGeometry.maxPixelEdge)
        #expect(abs(size.aspect - 10000.0 / 3000) < 0.01)
        #expect(AppshotCaptureGeometry.pixelSize(for: .zero, scale: 2) == AppshotPixelSize(width: 1, height: 1))
    }

    @Test func aPictureTheContentDidntFillIsTakenAgainAtTheContentsShape() {
        let group = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let window = CGRect(x: 300, y: 200, width: 400, height: 300)
        let output = AppshotPixelSize(width: 2800, height: 1800)
        func refined(_ width: Int, _ height: Int) -> CGRect? {
            AppshotCaptureGeometry.refinedFrame(
                content: AppshotPixelSize(width: width, height: height), output: output, used: group, alternatives: [window])
        }
        // Filled, give or take a pixel's rounding: nothing to do.
        #expect(refined(2800, 1800) == nil)
        #expect(refined(2799, 1800) == nil)
        // Only the front window was drawn, in its 4:3 shape: again at its own frame.
        #expect(refined(2400, 1800) == window)
        // Drawn smaller but in the group's shape: no better frame to try.
        #expect(refined(1400, 900) == nil)
    }
}

/// Cutting a captured picture down to where ScreenCaptureKit drew the window.
struct AppshotImageTrimTests {
    /// A transparent picture with `opaque` (from the top left) filled in.
    static func image(width: Int, height: Int, opaque: [CGRect]) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        for rect in opaque {
            // Core Graphics draws from the bottom left.
            context.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
        }
        return context.makeImage()!
    }

    @Test func theStripPictureIsCutToTheWindow() {
        // The broken appshot: the window drawn 176 pixels wide at the left of 2000×110, the rest transparent.
        let image = Self.image(width: 2000, height: 110, opaque: [CGRect(x: 0, y: 0, width: 176, height: 110)])
        #expect(AppshotImageTrim.contentBounds(of: image) == CGRect(x: 0, y: 0, width: 176, height: 110))
        let trimmed = AppshotImageTrim.trimmed(image)
        #expect(trimmed.width == 176 && trimmed.height == 110)
    }

    @Test func contentAnywhereIsFound() {
        let image = Self.image(width: 300, height: 200, opaque: [CGRect(x: 40, y: 30, width: 100, height: 50)])
        #expect(AppshotImageTrim.contentBounds(of: image) == CGRect(x: 40, y: 30, width: 100, height: 50))
        let trimmed = AppshotImageTrim.trimmed(image)
        #expect(trimmed.width == 100 && trimmed.height == 50)
    }

    @Test func roundedCornersAreKept() {
        // A window whose corner pixels are transparent: every edge row and column still has some of it.
        let image = Self.image(
            width: 200, height: 100,
            opaque: [CGRect(x: 4, y: 0, width: 192, height: 100), CGRect(x: 0, y: 4, width: 200, height: 92)])
        #expect(AppshotImageTrim.contentBounds(of: image) == CGRect(x: 0, y: 0, width: 200, height: 100))
        let trimmed = AppshotImageTrim.trimmed(image)
        #expect(trimmed.width == 200 && trimmed.height == 100)
    }

    @Test func anEmptyPictureIsLeftAlone() {
        let image = Self.image(width: 50, height: 40, opaque: [])
        #expect(AppshotImageTrim.contentBounds(of: image) == nil)
        #expect(AppshotImageTrim.trimmed(image).width == 50)
    }
}
