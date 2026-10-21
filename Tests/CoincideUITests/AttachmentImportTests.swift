import AppKit
import CoincideCore
import CoreGraphics
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Coincide

@MainActor private func waitUI(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Native UI state did not settle") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func cancellingAnUnfinishedNativePasteDoesNotHoldAppShutdown() async throws {
    let provider = NSItemProvider(), progress = Progress(totalUnitCount: 1)
    provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { _ in progress }
    let load = Task { try await NativePasteData.load(provider, type: UTType.png.identifier) }
    try await Task.sleep(for: .milliseconds(30)); load.cancel()
    do { _ = try await load.value; Issue.record("A cancelled paste returned data") }
    catch is CancellationError {} // The underlying provider never completes its callback.
    #expect(progress.isCancelled)
}

@MainActor @Test func nativeImagePasteAndConcurrentFileImportsKeepAllValidAttachments() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("note.txt")
    try Data("Synthetic note".utf8).write(to: source)
    let store = WorkspaceStore(databaseURL: directory.appendingPathComponent("workspace.sqlite"))
    await store.load(); store.addProject(at: directory)
    try await waitUI { store.snapshot.projects.count == 1 }
    store.newThread(); try await waitUI { store.selectedThreadID != nil }
    do {
        let threadID = try #require(store.selectedThreadID)
        let context = try #require(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 1_600,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.12, green: 0.32, blue: 0.92, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let data = NSMutableData(), image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination))
        let paste = NSItemProvider(); paste.suggestedName = "Synthetic image.tiff"
        let bytes = data as Data
        paste.registerDataRepresentation(forTypeIdentifier: UTType.tiff.identifier, visibility: .all) { completion in completion(bytes, nil); return nil }
        store.importAttachments(providers: [paste], threadID: threadID)
        store.importAttachments(files: [source, directory], threadID: threadID) // A failed folder keeps the valid file.
        try await waitUI { !store.isImportingAttachments(threadID) }
        let references = try #require(store.thread(threadID)?.draftAttachments)
        #expect(references.count == 2 && references.contains(where: { $0.mimeType == "image/jpeg" }))
        #expect(store.errorMessage?.contains("regular file") == true)
        store.errorMessage = nil
        store.importAttachments(files: Array(repeating: source, count: 101), threadID: threadID)
        #expect(store.errorMessage?.contains("100") == true && !store.isImportingAttachments(threadID))
        #expect(store.thread(threadID)?.draftAttachments.count == 2)
        if ProcessInfo.processInfo.environment["COINCIDE_RENDER_ATTACHMENTS"] == "1" {
            try await captureAttachmentUI(store: store, references: references)
        }
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}

@MainActor private func captureAttachmentUI(store: WorkspaceStore, references: [ChatAttachment]) async throws {
    _ = NSApplication.shared
    let image = try #require(references.first(where: { $0.isImage }))
    let content = VStack(alignment: .leading, spacing: 16) {
        Text("Message attachments").font(.headline)
        AttachmentShelf(store: store, attachments: references, remove: { _ in })
        Divider()
        AttachmentPreview(store: store, attachment: image)
    }.padding(24).frame(width: 700, height: 500).background(Color(nsColor: .windowBackgroundColor))
    for scheme in [ColorScheme.light, .dark] {
        let hosting = NSHostingView(rootView: content.environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 700, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-attachments-\(scheme == .light ? "light" : "dark").png")
        let png = try #require(bitmap.representation(using: .png, properties: [:])); try png.write(to: path)
        print("Native attachment preview: \(path.path)"); window.close()
    }
}

@MainActor @Test func nativeFileURLPasteImportsAndRestoresTheDraft() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("workspace.sqlite"), source = directory.appendingPathComponent("Pasted note.txt")
    try Data("Synthetic pasted note".utf8).write(to: source)
    let store = WorkspaceStore(databaseURL: database)
    await store.load(); store.addProject(at: directory)
    try await waitUI { store.snapshot.projects.count == 1 }
    store.newThread(); try await waitUI { store.selectedThreadID != nil }
    let threadID = try #require(store.selectedThreadID)
    let provider = NSItemProvider(object: source as NSURL)
    #expect(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
    store.importAttachments(providers: [provider], threadID: threadID)
    #expect(store.isImportingAttachments(threadID))
    try await waitUI { !store.isImportingAttachments(threadID) }
    #expect(store.errorMessage == nil)
    let reference = try #require(store.thread(threadID)?.draftAttachments.first)
    #expect(reference.name == "Pasted note.txt")
    #expect(try await store.attachmentData(reference) == Data("Synthetic pasted note".utf8))
    store.setDraft("Keep this draft", id: threadID)
    await store.shutdown()
    let reopened = WorkspaceStore(databaseURL: database)
    await reopened.load()
    #expect(reopened.thread(threadID)?.draft == "Keep this draft" && reopened.thread(threadID)?.draftAttachments == [reference])
    reopened.removeAttachment(reference.id, threadID: threadID)
    try await waitUI { reopened.thread(threadID)?.draftAttachments.isEmpty == true }
    await reopened.shutdown()
}
