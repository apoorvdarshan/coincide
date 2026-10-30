import AppKit
import SwiftUI
import Testing

@testable import Coincide
@testable import CoincideKit

/// Settings › Archive lists archived threads only, newest first by project, and follows the store as threads are
/// archived and unarchived. Nothing here shows a window.
@MainActor
struct ArchiveSettingsTests {
    private func store(_ directory: TemporaryDirectory) throws -> (AppStore, [UUID]) {
        let store = AppStore(directory: directory.url)
        let first = store.addProject(at: try directory.folder("Website"))
        let second = store.addProject(at: try directory.folder("Coincide"))
        let now = Date()
        var ids: [UUID] = []
        for (index, (project, title, archived)) in [
            (first, "Fix the header", true), (first, "Draft the launch post", true), (second, "Sync copies", true),
            (second, "Still open", false),
        ].enumerated() {
            let id = store.createThread(in: project.id).id
            store.updateThread(id) {
                $0.title = title
                $0.isArchived = archived
                $0.updatedAt = now.addingTimeInterval(TimeInterval(-3600 * (index + 1)))
            }
            ids.append(id)
        }
        return (store, ids)
    }

    @Test func listsOnlyArchivedThreadsNewestFirst() throws {
        let directory = TemporaryDirectory("archive-settings")
        let (store, ids) = try store(directory)
        let model = ArchiveSettingsModel(store: store)
        #expect(model.groups.map(\.project.name) == ["Website", "Coincide"])
        #expect(model.groups[0].threads.map(\.title) == ["Fix the header", "Draft the launch post"])
        #expect(model.groups[1].threads.map(\.title) == ["Sync copies"])
        #expect(Set(model.allThreadIDs) == Set(ids.prefix(3)))

        model.filter = "launch"
        #expect(model.allThreadIDs == [ids[1]])
        model.filter = ""

        // Unarchiving or archiving elsewhere shows up here at once.
        store.updateThread(ids[2]) { $0.isArchived = false }
        store.updateThread(ids[3]) { $0.isArchived = true }
        #expect(model.groups.map(\.project.name) == ["Website", "Coincide"])
        #expect(model.groups[1].threads.map(\.title) == ["Still open"])
    }

    /// Writes PNGs of the pane in light and dark when `COINCIDE_ARCHIVE_PNG_DIR` names a folder
    /// (`TEST_RUNNER_COINCIDE_ARCHIVE_PNG_DIR` through xcodebuild).
    @Test func rendersThePane() throws {
        guard let folder = ProcessInfo.processInfo.environment["COINCIDE_ARCHIVE_PNG_DIR"], !folder.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let directory = TemporaryDirectory("archive-settings-render")
        let (store, _) = try store(directory)
        let model = ArchiveSettingsModel(store: store)
        let empty = ArchiveSettingsModel(store: AppStore(directory: TemporaryDirectory("archive-settings-empty").url))
        try render(ArchiveSettingsView(model: model), name: "archive", folder: folder)
        try render(ArchiveSettingsView(model: empty), name: "archive-empty", folder: folder)
    }

    private func render(_ content: some View, name: String, folder: String) throws {
        let size = NSSize(width: 640, height: 560)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: content
                .toggleStyle(ThemedSwitchToggleStyle()).buttonStyle(ThemedButtonStyle()).textFieldStyle(ThemedTextFieldStyle())
                .frame(width: size.width, height: size.height).background(Color(nsColor: Theme.contentBackground)))
            view.frame = NSRect(origin: .zero, size: size)
            view.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}
