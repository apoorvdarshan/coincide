import AppKit
import SwiftUI
import Testing

@testable import Coincide
@testable import CoincideKit

/// The master's sync rows and the Sync sheet, rendered offscreen. Nothing here shows a window or touches the user's
/// instruction files.
@MainActor
struct InstructionSyncViewTests {
    private func model(iCloud: Bool, git: Bool, statuses: [InstructionCopySyncer.Key.Copy: InstructionCopySyncer.Status]) throws -> InstructionsModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-instruction-sync-\(UUID().uuidString)")
        let store = InstructionSettingsStore(directory: directory)
        var config = InstructionMasterConfig(isEnabled: true, masterPath: "/Users/me/.config/coincide/AGENTS.md")
        if iCloud { config.iCloud = InstructionICloudCopy(path: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Coincide/Instructions/Global.md") }
        if git {
            config.git = InstructionGitCopy(
                repository: "/Users/me/agent-instructions", path: "/Users/me/agent-instructions/Global.md", gitHubName: "me/agent-instructions")
        }
        try store.update(config, for: .global)
        let syncer = InstructionCopySyncer(store: store)
        for (copy, status) in statuses { syncer.statuses[.init(scope: .global, copy: copy)] = status }
        return InstructionsModel(scope: .global, store: store, syncer: syncer)
    }

    @Test func rowsListEachCopyThatIsOn() throws {
        let both = try model(iCloud: true, git: true, statuses: [:])
        #expect(both.repositoryDescription == "me/agent-instructions")
        let off = try model(iCloud: false, git: false, statuses: [:])
        #expect(off.repositoryDescription == nil)
        #expect(InstructionCopySyncer.Status.inStep.problem == nil)
        #expect(InstructionCopySyncer.Status.conflict.problem != nil)
    }

    /// Writes PNGs of the rows and the sheet in light and dark when `COINCIDE_SYNC_PNG_DIR` names a folder
    /// (`TEST_RUNNER_COINCIDE_SYNC_PNG_DIR` through xcodebuild).
    @Test func rendersTheRowsAndTheSheet() throws {
        guard let folder = ProcessInfo.processInfo.environment["COINCIDE_SYNC_PNG_DIR"], !folder.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let inStep = try model(iCloud: true, git: true, statuses: [.iCloud: .inStep, .git: .inStep])
        let troubled = try model(iCloud: true, git: true, statuses: [.iCloud: .conflict, .git: .failed("Couldn't fetch from the remote.")])
        let off = try model(iCloud: false, git: false, statuses: [:])
        let rows = VStack(alignment: .leading, spacing: 18) {
            SyncSummary(model: inStep)
            SyncSummary(model: troubled)
            SyncSummary(model: off)
        }
        .padding(10)
        .frame(width: 246, alignment: .leading)
        try render(rows.instructionsTheme(), size: NSSize(width: 246, height: 330), name: "rows", folder: folder)
        try render(SyncSheet(model: inStep).instructionsTheme(), size: NSSize(width: 540, height: 560), name: "sheet-on", folder: folder)
        try render(SyncSheet(model: troubled).instructionsTheme(), size: NSSize(width: 540, height: 620), name: "sheet-conflict", folder: folder)
        try render(SyncSheet(model: off).instructionsTheme(), size: NSSize(width: 540, height: 480), name: "sheet-off", folder: folder)
    }

    private func render(_ content: some View, size: NSSize, name: String, folder: String) throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: content.frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color(nsColor: Theme.contentBackground)))
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
