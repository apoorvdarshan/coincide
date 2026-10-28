import AppKit
import Testing

@testable import Coincide
@testable import CoincideKit

@MainActor
struct ProjectDefaultsEditorTests {
    @Test func editsStayInTheSheetUntilSaveAndResetRestoresInheritance() throws {
        let folder = TemporaryDirectory("project-defaults-editor")
        let store = AppStore(directory: folder.url)
        let project = store.addProject(at: folder.url)
        let registry = ProviderRegistry(store: store, providers: [])
        let editor = ProjectDefaultsEditor(project: project, store: store, registry: registry)
        var saved: [ProjectThreadDefaults?] = []
        editor.onSave = { saved.append($0) }
        let checkbox = try #require(descendants(editor.view).compactMap { $0 as? ThemedCheckbox }.first)
        #expect(checkbox.state == .on)
        checkbox.performClick(nil)
        let controls = descendants(editor.view).compactMap { $0 as? ComposerControlButton }
        let mode = try #require(controls.first { $0.accessibilityLabel() == "Mode" })
        let menu = try #require(mode.menuProvider?())
        let planIndex = try #require(menu.items.firstIndex { ($0.representedObject as? InteractionMode) == .plan })
        menu.performActionForItem(at: planIndex)
        #expect(store.project(project.id)?.threadDefaults == nil)
        #expect(saved.isEmpty)
        func button(_ title: String) throws -> ThemedButton {
            try #require(descendants(editor.view).compactMap { $0 as? ThemedButton }.first { $0.title == title })
        }
        try button("Save").performClick(nil)
        #expect(saved.count == 1 && saved[0]?.interactionMode == .plan)
        try button("Reset to Global").performClick(nil)
        #expect(checkbox.state == .on && controls.allSatisfy { !$0.isEnabled })
        try button("Save").performClick(nil)
        #expect(saved.count == 2 && saved[1] == nil)
    }

    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
}
