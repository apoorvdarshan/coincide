import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoincideKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Reads the window list and takes the picture of one window, for appshots.
nonisolated enum AppshotCapture {
    enum Failure: LocalizedError {
        case windowGone, notSaved

        var errorDescription: String? {
            switch self {
            case .windowGone: String(localized: "The window closed before Coincide could capture it.")
            case .notSaved: String(localized: "The appshot couldn’t be saved.")
            }
        }
    }

    /// The windows on screen, front to back. Needs no permission; other apps' titles come only with Screen Recording.
    @MainActor
    static func windows() -> [AppshotWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return [] }
        let regular = Set(
            NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        return list.compactMap { AppshotWindow(windowListEntry: $0) { regular.contains($0) } }
    }

    /// Captures the window and saves the picture into the attachments folder, returning its path.
    @concurrent
    static func capture(_ window: AppshotWindow, into directory: URL) async throws -> String {
        try await save(image(of: window), into: directory)
    }

    /// The window alone at the display's full (Retina) resolution, through ScreenCaptureKit: no other window, no
    /// cursor, no shadow, never the rest of the screen.
    private static func image(of window: AppshotWindow) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let shareable = content.windows.first(where: { $0.windowID == window.id }) else { throw Failure.windowGone }
        let filter = SCContentFilter(desktopIndependentWindow: shareable)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Saves the picture into the attachments folder the way the composer saves pasted images (at most 2000 pixels on
    /// the long edge), so every agent takes it.
    private static func save(_ image: CGImage, into directory: URL) async throws -> String {
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.notSaved
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer),
            let imported = await ComposerAttachmentImporter.importImage(.data(data as Data), into: directory)
        else { throw Failure.notSaved }
        return imported.path
    }
}

/// What keeps a window out of appshots besides its own wish (`AppshotWindow.isShareable`): a password being typed.
nonisolated enum AppshotPrivacy {
    /// The process that turned secure keyboard entry on (a password field has focus, or Terminal's Secure Keyboard
    /// Entry): nil while it's off, 0 when it's on but macOS doesn't say whose.
    static func secureInputOwner() -> Int32? {
        guard IsSecureEventInputEnabled() else { return nil }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value ?? 0
    }

    /// Whether the window's app is taking a password: it turned secure input on (or someone did and macOS doesn't
    /// say who), or, when Coincide may read it, its focused field is a password field.
    static func isTakingPassword(_ window: AppshotWindow, canReadApp: Bool) -> Bool {
        if let owner = secureInputOwner(), owner == 0 || owner == window.ownerPID { return true }
        guard canReadApp else { return false }
        let app = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXFocusedUIElement" as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        var subrole: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(focused as! AXUIElement, "AXSubrole" as CFString, &subrole)
        return subrole as? String == "AXSecureTextField"
    }
}

/// The text an app makes available in a window through Accessibility: its labels, text views and fields, in reading
/// order, skipping password fields and what's scrolled out of the window. Bounded in elements, time and length, so a
/// huge document or a slow app can't hold the appshot up.
nonisolated enum AppshotWindowText {
    static let maxElements = 6000
    static let timeLimit: TimeInterval = 1.5
    private static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXComboBox"]
    private static let attributes = ["AXRole", "AXSubrole", "AXValue", "AXChildren", "AXPosition", "AXSize"]

    @concurrent
    static func read(from window: AppshotWindow) async -> String? {
        let app = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let root = matchingWindow(in: app, frame: window.bounds) else { return nil }
        let deadline = Date().addingTimeInterval(timeLimit)
        var pieces: [String] = []
        var length = 0
        var visited = 0
        // Depth first, children in order: the order the app reads them out.
        var stack: [AXUIElement] = [root]
        while let element = stack.popLast(), visited < maxElements, length < MessageContext.maxWindowTextLength,
            Date() < deadline
        {
            visited += 1
            let values = Self.values(of: element)
            let role = values.role ?? ""
            if values.subrole == "AXSecureTextField" { continue }
            // Scrolled out of the window: none of it shows.
            if let frame = values.frame, frame.width > 0, frame.height > 0, !frame.intersects(window.bounds) { continue }
            if textRoles.contains(role), let text = values.text {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed != pieces.last {
                    pieces.append(trimmed)
                    length += trimmed.count + 1
                }
            }
            stack.append(contentsOf: values.children.reversed())
        }
        let text = pieces.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// The app's accessibility window at the captured window's place: the window server and Accessibility don't share
    /// ids. Nil when none matches, rather than another window's text.
    private static func matchingWindow(in app: AXUIElement, frame: CGRect) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else { return nil }
        let framed = windows.compactMap { window in values(of: window).frame.map { (window, $0) } }
        let matches = framed.filter { abs($0.1.minX - frame.minX) <= 4 && abs($0.1.minY - frame.minY) <= 4 }
            .min { distance($0.1, frame) < distance($1.1, frame) }
        return matches?.0
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    private struct Values {
        var role: String?
        var subrole: String?
        var text: String?
        var children: [AXUIElement] = []
        var frame: CGRect?
    }

    /// One round trip to the app for every attribute the walk needs.
    private static func values(of element: AXUIElement) -> Values {
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &result)
            == .success, let array = result as? [AnyObject], array.count == 6
        else { return Values() }
        var values = Values()
        values.role = array[0] as? String
        values.subrole = array[1] as? String
        values.text = array[2] as? String
        values.children = array[3] as? [AXUIElement] ?? []
        if let origin = point(array[4]), let size = size(array[5]) { values.frame = CGRect(origin: origin, size: size) }
        return values
    }

    private static func point(_ value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}
