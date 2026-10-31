import CoreGraphics
import Foundation

/// A display as an appshot sizes its picture for it: where it is, in window-server coordinates (points from the top
/// left of the main display, like `AppshotWindow.bounds`), and its points-to-pixels scale (2 on Retina).
public struct AppshotDisplay: Hashable, Sendable {
    public var frame: CGRect
    public var scale: CGFloat

    public nonisolated init(frame: CGRect, scale: CGFloat) {
        self.frame = frame
        self.scale = scale
    }

    /// A display from AppKit's coordinates (`NSScreen.frame`: points from the bottom left of the main display, y up).
    /// `mainHeight` is the main display's height, which both coordinate systems share their origin with.
    public nonisolated init(appKitFrame: CGRect, scale: CGFloat, mainHeight: CGFloat) {
        self.init(
            frame: CGRect(x: appKitFrame.minX, y: mainHeight - appKitFrame.maxY, width: appKitFrame.width, height: appKitFrame.height),
            scale: scale)
    }
}

/// The size of an appshot's picture in pixels.
public struct AppshotPixelSize: Hashable, Sendable {
    public var width: Int
    public var height: Int

    public nonisolated init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public nonisolated var aspect: CGFloat { CGFloat(width) / CGFloat(max(1, height)) }
}

/// How big an appshot's picture is, and which windows make up what ScreenCaptureKit draws.
///
/// An app's window can be drawn as several windows: Chrome puts its tab strip and toolbar in a thin window of their
/// own (1470×81 points on a 1470-point display) in front of the window with the page. That strip is the frontmost
/// window of the app, so it is the one an appshot captures, and ScreenCaptureKit draws the whole window, strip and
/// page together, into whatever size it is asked for, keeping the aspect and leaving the rest transparent. Sized for
/// the strip alone, the page came out as a sliver at one end of a 2000×110 picture. So the picture is sized for the
/// group the window is drawn with: the app's windows directly in front of and behind it that touch it.
public enum AppshotCaptureGeometry {
    /// The longest edge ScreenCaptureKit is asked for, whatever the window's size: a window spanning several 6K
    /// displays still makes a picture that fits in memory. The composer then saves at most 2000 pixels.
    public nonisolated static let maxPixelEdge = 8192

    /// The windows `window` is drawn with, front to back: the run of the same app's visible ordinary windows right in
    /// front of and behind it in `windows` (front to back, as the window server lists them) that touch or overlap it.
    /// Just the window when it stands alone or isn't listed.
    public nonisolated static func group(of window: AppshotWindow, in windows: [AppshotWindow]) -> [AppshotWindow] {
        let pool = windows.filter { $0.layer == 0 && $0.alpha > 0 }
        guard let index = pool.firstIndex(where: { $0.id == window.id }) else { return [window] }
        var group = [pool[index]]
        var frame = pool[index].bounds
        func joins(_ other: AppshotWindow) -> Bool {
            other.ownerPID == window.ownerPID && other.bounds.width > 0 && other.bounds.height > 0
                && frame.insetBy(dx: -1, dy: -1).intersects(other.bounds)
        }
        var front = index - 1
        while front >= 0, joins(pool[front]) {
            group.insert(pool[front], at: 0)
            frame = frame.union(pool[front].bounds)
            front -= 1
        }
        var back = index + 1
        while back < pool.count, joins(pool[back]) {
            group.append(pool[back])
            frame = frame.union(pool[back].bounds)
            back += 1
        }
        return group
    }

    /// Where the window and the windows it's drawn with are, together.
    public nonisolated static func groupFrame(of window: AppshotWindow, in windows: [AppshotWindow]) -> CGRect {
        group(of: window, in: windows).map(\.bounds).reduce(window.bounds) { $0.union($1) }
    }

    /// The scale of the display a window is on: the one showing most of it, as AppKit picks a window's backing scale.
    /// A window entirely off every display takes the nearest one's; `fallback` (ScreenCaptureKit's own answer) when
    /// no display is known.
    public nonisolated static func scale(for frame: CGRect, displays: [AppshotDisplay], fallback: CGFloat) -> CGFloat {
        let usable = displays.filter { $0.scale > 0 && !$0.frame.isEmpty }
        func area(_ display: AppshotDisplay) -> CGFloat {
            let overlap = display.frame.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        func distance(_ display: AppshotDisplay) -> CGFloat {
            let dx = max(display.frame.minX - frame.maxX, frame.minX - display.frame.maxX, 0)
            let dy = max(display.frame.minY - frame.maxY, frame.minY - display.frame.maxY, 0)
            return dx * dx + dy * dy
        }
        let best =
            usable.filter { area($0) > 0 }.max { area($0) < area($1) }
            ?? usable.min { distance($0) < distance($1) }
        return best?.scale ?? (fallback > 0 ? fallback : 1)
    }

    /// The picture's size for a window group at `frame` (points) on a display of `scale`: the whole frame in pixels,
    /// the parts off the display included (ScreenCaptureKit draws those too), within `maxPixelEdge`, keeping the
    /// aspect.
    public nonisolated static func pixelSize(for frame: CGRect, scale: CGFloat) -> AppshotPixelSize {
        let width = max(1, frame.width * scale)
        let height = max(1, frame.height * scale)
        let fit = min(1, CGFloat(maxPixelEdge) / max(width, height))
        return AppshotPixelSize(width: max(1, Int((width * fit).rounded())), height: max(1, Int((height * fit).rounded())))
    }

    /// After a capture at `output` that drew its content at `content` (the opaque part, `AppshotImageTrim`): nil when
    /// the content filled it, as it should; otherwise the one of `alternatives` whose shape the content has, to capture
    /// again at, when it's closer than the frame used (`used`). A window in front of an unrelated one of the same app
    /// counts as their group, but ScreenCaptureKit draws only the window: the second capture takes it at full size.
    public nonisolated static func refinedFrame(
        content: AppshotPixelSize, output: AppshotPixelSize, used: CGRect, alternatives: [CGRect]
    ) -> CGRect? {
        let tolerance = 2
        guard content.width < output.width - tolerance || content.height < output.height - tolerance else { return nil }
        let aspect = content.aspect
        func mismatch(_ frame: CGRect) -> CGFloat {
            guard frame.width > 0, frame.height > 0 else { return .infinity }
            return abs(log((frame.width / frame.height) / aspect))
        }
        guard let best = alternatives.filter({ $0 != used }).min(by: { mismatch($0) < mismatch($1) }),
            mismatch(best) < mismatch(used)
        else { return nil }
        return best
    }
}

/// The part of a captured picture ScreenCaptureKit drew the window in. It draws a window into the size it's asked for
/// keeping the window's aspect, and leaves the rest transparent, so a picture whose shape didn't match is cut to the
/// window rather than kept with empty bands.
public enum AppshotImageTrim {
    /// The smallest rectangle (pixels, from the top left) holding every pixel that isn't fully transparent; nil when
    /// the whole picture is. A window's rounded corners are transparent, but their rows and columns aren't entirely.
    public nonisolated static func contentBounds(of image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = context.data
        else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let stride = context.bytesPerRow
        let alpha = data.bindMemory(to: UInt8.self, capacity: stride * height)
        func rowIsEmpty(_ y: Int) -> Bool {
            let row = alpha + y * stride
            for x in 0..<width where row[x * 4 + 3] != 0 { return false }
            return true
        }
        func columnIsEmpty(_ x: Int, rows: ClosedRange<Int>) -> Bool {
            for y in rows where alpha[y * stride + x * 4 + 3] != 0 { return false }
            return true
        }
        // The bitmap's first row is the picture's top.
        guard let top = (0..<height).first(where: { !rowIsEmpty($0) }),
            let bottom = (0..<height).reversed().first(where: { !rowIsEmpty($0) })
        else { return nil }
        let rows = top...bottom
        let left = (0..<width).first { !columnIsEmpty($0, rows: rows) } ?? 0
        let right = (0..<width).reversed().first { !columnIsEmpty($0, rows: rows) } ?? width - 1
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    /// The picture cut to `contentBounds`, or unchanged when there's nothing to cut (or nothing in it at all).
    public nonisolated static func trimmed(_ image: CGImage) -> CGImage {
        guard let bounds = contentBounds(of: image),
            bounds.width < CGFloat(image.width) || bounds.height < CGFloat(image.height)
        else { return image }
        return image.cropping(to: bounds) ?? image
    }
}
