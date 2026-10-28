import AppKit
import CoincideKit
import Testing
@testable import Coincide

@MainActor
struct CLISessionImportViewTests {
    @Test func previewIsReadOnlyAndImportIsAnExplicitActionWithDuplicateLabel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-import-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        let controller = CLISessionImportController(store: store, roots: [:])
        controller.loadViewIfNeeded()
        let buttons = descendants(controller.view).compactMap { $0 as? NSButton }
        let importButton = try #require(buttons.first { $0.title == String(localized: "Import") })
        #expect(!importButton.isEnabled && store.threadSummaries.isEmpty)
        let data = Data("""
            {"type":"session_meta","payload":{"id":"a0000000-0000-0000-0000-000000000001","cwd":"/tmp/fixture"}}
            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Question"}]}}
            {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Answer"}]}}
            """.utf8)
        let preview = try CLISessionImport.parse(data, sourceURL: directory.appendingPathComponent("source.jsonl"))
        controller.show(preview)
        #expect(importButton.isEnabled && store.threadSummaries.isEmpty && store.projects.isEmpty)
        let transcript = try #require(descendants(controller.view).compactMap { $0 as? NSTextView }.first)
        #expect(!transcript.isEditable && transcript.string.contains("Question") && transcript.string.contains("Answer"))
        let id = try store.importSession(preview)
        controller.show(preview)
        #expect(importButton.title == String(localized: "Open Existing Thread"))
        var opened: UUID?
        controller.onImport = { opened = $0 }
        importButton.performClick(nil)
        #expect(opened == id && store.threadSummaries.count == 1)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
