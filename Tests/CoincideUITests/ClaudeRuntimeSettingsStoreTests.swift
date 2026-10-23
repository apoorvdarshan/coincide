import AppKit
import CoincideCore
import Foundation
import SwiftUI
import Testing
@testable import Coincide

@Test @MainActor func claudeRuntimeSettingsPublishesDurableProfileNamespaceAndPreservesItAfterShutdown() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-settings-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeRuntimeSettingsStore(rootURL: root)
    await store.load()
    let initial = store.profile
    #expect(store.isLoaded && !store.hasUnsavedChanges)
    store.autoCompactWindowText = "200000"
    await store.applySelection()
    #expect(store.profile.instanceID == initial.instanceID && store.profile.autoCompactWindow == 200_000)
    store.configurationDirectory = "/private/selected-native-home"
    await store.applySelection()
    let selected = store.profile
    #expect(selected.instanceID != initial.instanceID && !store.hasUnsavedChanges)
    let reopened = ClaudeRuntimeSettingsStore(rootURL: root)
    await reopened.load()
    #expect(reopened.profile == selected)
    await store.shutdown()
    store.executable = "/private/late-executable"; store.autoCompactWindowText = "900000"
    #expect(store.executable == selected.executable && store.autoCompactWindowText == "200000")
    store.cancelShutdown(); store.autoCompactWindowText = "300000"
    await store.applySelection()
    #expect(store.profile.instanceID == selected.instanceID && store.profile.autoCompactWindow == 300_000)
    #expect(reopened.profile == selected)
    await store.shutdown(); await reopened.shutdown()
}

@Test @MainActor func claudeRuntimeSettingsConflictNeverPublishesUnsavedProfileOrOverwritesForeignBytes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-settings-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = ClaudeRuntimeSettingsStore(rootURL: root), second = ClaudeRuntimeSettingsStore(rootURL: root)
    await first.load(); await second.load()
    first.executable = "/private/first-cli"; await first.applySelection()
    let file = root.appendingPathComponent("ClaudeSettings/profile.json"), original = try Data(contentsOf: file)
    second.executable = "/private/second-cli"; await second.applySelection()
    #expect(second.profile.executable == "claude" && second.errorMessage != nil && second.hasUnsavedChanges)
    #expect(!second.canApply && !second.isLoaded)
    #expect(try Data(contentsOf: file) == original)
    await second.load()
    #expect(second.profile == first.profile && second.isLoaded && !second.hasUnsavedChanges)
    try Data("preserved damaged settings".utf8).write(to: file)
    await second.load()
    #expect(second.profile == first.profile && !second.isLoaded && second.errorMessage != nil)
    second.executable = "/private/third-cli"; await second.applySelection()
    #expect(try String(contentsOf: file, encoding: .utf8) == "preserved damaged settings")
    await first.shutdown(); await second.shutdown()
}

@Test @MainActor func claudeRuntimeSettingsRejectsMalformedThresholdAndRendersDefaultsOffscreenWithoutLaunchingCLI() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-settings-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeRuntimeSettingsStore(rootURL: root); await store.load()
    for text in ["99999", "1000001", "0100000", "100_000", "1e6", " 200000", "NaN"] {
        store.autoCompactWindowText = text
        #expect(store.draftProfile == nil && !store.canApply)
        await store.applySelection()
    }
    store.useCLIDefaults()
    for scheme in [ColorScheme.light, .dark] {
        for width in [CGFloat(360), 640] {
            let host = NSHostingController(rootView: Form { ClaudeRuntimeSettingsSection(runtime: store) }
                .formStyle(.grouped).environment(\.colorScheme, scheme).frame(width: width, height: 560))
            let size = host.sizeThatFits(in: .init(width: width, height: 560))
            #expect(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 && size.width <= width + 1 && size.height <= 561)
            host.view.frame = .init(origin: .zero, size: size); host.view.layoutSubtreeIfNeeded()
            #expect(host.view.window == nil)
        }
    }
    #expect(store.profile == .init() && !store.hasUnappliedChanges)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ClaudeSettings/profile.json").path))
    await store.shutdown()
}
