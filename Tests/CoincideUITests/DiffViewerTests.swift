import AppKit
import CoincideCore
import SwiftUI
import Testing
@testable import Coincide

private let diffViewerPatch = """
diff --git a/Sources/App/Main.swift b/Sources/App/Main.swift
--- a/Sources/App/Main.swift
+++ b/Sources/App/Main.swift
@@ -1,3 +1,3 @@ struct Main {
 let title = "Coincide"
-let count = 1 // old
+let count = 2 // new
 let done = true
diff --git a/Sources/App/View.swift b/Sources/App/View.swift
new file mode 100644
--- /dev/null
+++ b/Sources/App/View.swift
@@ -0,0 +1,2 @@
+import SwiftUI
+struct ContentView {}
diff --git a/README.md b/README.md
deleted file mode 100644
--- a/README.md
+++ /dev/null
@@ -1 +0,0 @@
-# Readme

"""

@MainActor @Test func diffFileTreeCompressesSingleFolderChainsAndOrdersFoldersFirst() {
    let diff = UnifiedDiff.parse(diffViewerPatch)
    let tree = DiffFileTree.build(diff.files)
    #expect(tree.map(\.name) == ["Sources/App", "README.md"])
    #expect(tree[0].isFolder && tree[0].children.map(\.name) == ["Main.swift", "View.swift"])
    #expect(tree[0].additions == 3 && tree[0].deletions == 1 && tree[1].status == .deleted)
    let nested = DiffFileTree.build(UnifiedDiff.parse("diff --git a/a/b/c.txt b/a/b/c.txt\n--- a/a/b/c.txt\n+++ b/a/b/c.txt\n@@ -1 +1 @@\n-x\n+y\ndiff --git a/a/d.txt b/a/d.txt\n--- a/a/d.txt\n+++ b/a/d.txt\n@@ -1 +1 @@\n-x\n+y\n").files)
    #expect(nested.map(\.name) == ["a"] && nested[0].children.map(\.name) == ["b", "d.txt"])
}

@MainActor @Test func diffCollapseDefaultsLargeFilesAndRowsFollowTheLayout() {
    var lines = "diff --git a/big.txt b/big.txt\n--- a/big.txt\n+++ b/big.txt\n@@ -0,0 +1,401 @@\n"
    for index in 0..<401 { lines += "+line \(index)\n" }
    let big = UnifiedDiff.parse(lines).files[0], small = UnifiedDiff.parse(diffViewerPatch).files[0]
    var state = DiffCollapseState()
    #expect(state.isCollapsed(big) && !state.isCollapsed(small))
    state.toggle(big); #expect(!state.isCollapsed(big))
    state.collapseAll([big, small]); #expect(state.isCollapsed(big) && state.isCollapsed(small))
    state.expandAll([big, small]); #expect(!state.isCollapsed(big) && !state.isCollapsed(small))
    let unified = DiffRenderRow.rows(for: small, layout: .unified), split = DiffRenderRow.rows(for: small, layout: .split)
    #expect(unified.count == 5 && split.count == 4)
    if case .split(_, let row) = split[2] { #expect(row.left?.text == "let count = 1 // old" && row.right?.text == "let count = 2 // new") }
    else { Issue.record("The changed pair must share one split row.") }
    #expect(DiffPresentation.language(forExtension: "swift") == "swift" && DiffPresentation.language(forExtension: "tsx") == "tsx" && DiffPresentation.language(forExtension: "zzz").isEmpty)
    let colored = DiffHighlightCache.attributed("let value = \"text\" // note", language: "swift")
    #expect(String(colored.characters) == "let value = \"text\" // note")
    #expect(colored.runs.contains { $0.foregroundColor != nil })
}

@MainActor @Test func diffViewRendersUnifiedAndSplitAtInspectorAndSheetWidthsInBothAppearances() async throws {
    _ = NSApplication.shared
    let diff = UnifiedDiff.parse(diffViewerPatch, truncated: true)
    let defaults = UserDefaults.standard, saved = defaults.string(forKey: DiffViewerDefaults.layout)
    defer { if let saved { defaults.set(saved, forKey: DiffViewerDefaults.layout) } else { defaults.removeObject(forKey: DiffViewerDefaults.layout) } }
    for layout in DiffLayout.allCases {
        defaults.set(layout.rawValue, forKey: DiffViewerDefaults.layout)
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(300), 720] {
                let view = DiffView(diff: diff, ignoreWhitespace: .constant(false), focusPath: "README.md")
                    .environment(\.colorScheme, scheme).frame(width: width, height: 480)
                let controller = NSHostingController(rootView: view)
                let size = controller.sizeThatFits(in: CGSize(width: width, height: 480))
                #expect(size.width <= width + 1 && size.height <= 481)
                let hosting = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 480), styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua); hosting.appearance = window.appearance; window.isReleasedWhenClosed = false
                window.contentView = hosting; hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(60)); hosting.layoutSubtreeIfNeeded()
                #expect(hosting.fittingSize.width <= width + 1)
                if ProcessInfo.processInfo.environment["COINCIDE_RENDER_DIFF"] == "1" {
                    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)); hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-diff-\(layout.rawValue)-\(scheme == .light ? "light" : "dark")-\(Int(width)).png")
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: path); print("Native diff preview: \(path.path)")
                }
                window.close()
            }
        }
    }
    let empty = NSHostingController(rootView: DiffView(diff: .init(), emptyTitle: "No Branch Changes").frame(width: 280, height: 200))
    #expect(empty.sizeThatFits(in: CGSize(width: 280, height: 200)).width <= 281)
}
