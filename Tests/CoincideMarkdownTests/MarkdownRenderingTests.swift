import AppKit
import ImageIO
import SwiftUI
import Testing
@testable import CoincideMarkdown

@MainActor @Test func nativeMarkdownRendersRichResponsesInBothAppearances() async throws {
    let source = #"""
    # A native coding conversation

    This response has **bold text**, *emphasis*, ~~removed text~~, `inline code`, and a [source link](https://swift.org).

    ## Update the model

    ```swift
    // Keep streaming text intact, including Unicode.
    struct Greeting {
        let text = "Hello, 世界 🪁"
        func show() { print(text) }
    }
    ```

    > The queue keeps its place across a restart.

    - [x] Parse native Markdown
    - [x] Render native display equations
      - Keep unsupported expressions readable as source.

    ```math
    x=\frac{-b\pm\sqrt{b^2-4ac}}{2a}
    ```

    | Feature | Result |
    | :--- | ---: |
    | **Streaming** | Ready |
    | Code copying | Exact text |

    ---

    3. Run the tests.
    4. Review the changes.
    """#
    let document = MarkdownDocument(parsing: source)
    for scheme in [ColorScheme.light, .dark] {
        let view = MarkdownBlocksView(blocks: document.blocks, workspace: nil, openFile: { _, _ in })
            .font(.system(size: 15)).lineSpacing(4).padding(24).frame(width: 700)
            .background(Color(nsColor: .textBackgroundColor)).environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view); renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(image.width == 700 && image.height > 600 && image.height < 2_000)
        if ProcessInfo.processInfo.environment["COINCIDE_RENDER_MARKDOWN"] == "1" {
            // ImageRenderer omits AppKit-backed scroll content. Capture an unshown
            // native hosting window as well, so code and table pixels can be reviewed.
            _ = NSApplication.shared
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 700, height: image.height), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let name = scheme == .light ? "light" : "dark"
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-markdown-\(name).png")
            let destination = try #require(CGImageDestinationCreateWithURL(path as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try #require(bitmap.cgImage), nil)
            #expect(CGImageDestinationFinalize(destination))
            print("Native Markdown preview: \(path.path)")
            window.close()
        }
    }
}

@MainActor @Test func extendedMarkdownBlocksRenderInBothAppearancesAndRunNeverFiresOnRender() async throws {
    let source = #"""
    > [!WARNING]
    > Back up first, see https://example.com/docs.

    Inline $\sqrt{x}$ math with a note[^1] and <kbd>⌘K</kbd>.

    ```bash title="setup.sh"
    npm install
    ```

    ```mermaid
    graph LR
    A[Edit] --> B{Tests?}
    B -->|pass| C([Ship])
    ```

    <details open>
    <summary>Long log</summary>

    | Step | Formula | Detail |
    | --- | --- | --- |
    | one | $|x|$ | a deliberately long table cell that should wrap instead of widening the table without bound |

    </details>

    ::artifact-template{skill_name="artifact-template-deck" skill_directory="/tmp/skills/deck" display_name="Quarterly deck" artifact_kind="presentation"}

    [^1]: The footnote body.
    """#
    let document = MarkdownDocument(parsing: source)
    #expect(document.footnotes.count == 1)
    var commands: [String] = []
    for scheme in [ColorScheme.light, .dark] {
        let view = MarkdownBlocksView(blocks: document.blocks, context: .init(workspace: nil, openFile: { _, _ in }, runShell: { commands.append($0) }, footnotes: document.footnotes))
            .font(.system(size: 15)).lineSpacing(4).padding(24).frame(width: 640)
            .background(Color(nsColor: .textBackgroundColor)).environment(\.colorScheme, scheme)
        let size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 640, height: 10_000))
        #expect(size.width <= 641 && size.height > 500 && size.height < 3_000)
        let renderer = ImageRenderer(content: view); renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(image.width == 640)
        if ProcessInfo.processInfo.environment["COINCIDE_RENDER_MARKDOWN"] == "1" {
            _ = NSApplication.shared
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 640, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-markdown-extended-\(scheme == .light ? "light" : "dark").png")
            let destination = try #require(CGImageDestinationCreateWithURL(path as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try #require(bitmap.cgImage), nil)
            #expect(CGImageDestinationFinalize(destination))
            print("Extended Markdown preview: \(path.path)")
            window.close()
        }
    }
    #expect(commands.isEmpty, "Rendering must never run a suggested command.")
    let settings = NSHostingController(rootView: Form { MarkdownSettingsSection() }.formStyle(.grouped))
    #expect(settings.sizeThatFits(in: CGSize(width: 500, height: 800)).height > 60)
}
