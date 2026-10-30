import AppKit
import SwiftUI
import Testing

@testable import Coincide

/// The Full Disk Access guide: when the browser import comes back after macOS reopens Coincide, and how the drag card
/// looks. Nothing here shows a window.
@MainActor
struct FullDiskAccessGuideTests {
    private let key = "browserImport.resumeAfterFullDiskAccess"

    @Test func importComesBackOnlyRightAfterAskingAndOnce() {
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let now = Date()
        UserDefaults.standard.removeObject(forKey: key)
        #expect(!FullDiskAccess.takeResumeRequest(now: now, isGranted: true))

        UserDefaults.standard.set(now.addingTimeInterval(-60), forKey: key)
        #expect(FullDiskAccess.takeResumeRequest(now: now, isGranted: true))
        #expect(!FullDiskAccess.takeResumeRequest(now: now, isGranted: true))

        UserDefaults.standard.set(now.addingTimeInterval(-60), forKey: key)
        #expect(!FullDiskAccess.takeResumeRequest(now: now, isGranted: false))

        UserDefaults.standard.set(now.addingTimeInterval(-3600), forKey: key)
        #expect(!FullDiskAccess.takeResumeRequest(now: now, isGranted: true))
    }

    @Test func rendersTheCard() throws {
        guard let folder = ProcessInfo.processInfo.environment["COINCIDE_FDA_PNG_DIR"], !folder.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: FullDiskAccessCardView {})
            view.frame = NSRect(x: 0, y: 0, width: 420, height: 92)
            view.appearance = NSAppearance(named: name)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("card-\(suffix).png"))
        }
    }
}
