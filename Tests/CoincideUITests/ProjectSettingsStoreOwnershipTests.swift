import AppKit
import CoincideCore
import Foundation
import Testing
@testable import Coincide

@MainActor @Test func projectIconReloadsItsResolvedImageWhenRepositoryNamespaceChanges() async throws {
    let base = try projectActionsPhysicalTemporaryDirectory().appendingPathComponent("coincide-icon-namespace-" + UUID().uuidString)
    let checkout = base.appendingPathComponent("Checkout"), settingsRoot = base.appendingPathComponent("Settings")
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let suite = "coincide-icon-namespace-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let store = ProjectSettingsStore(root: settingsRoot, defaults: defaults)
    do {
        for (name, width) in [("first.png", 1), ("second.png", 2)] {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 1,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: checkout.appendingPathComponent(name))
        }
        var project = WorkspaceProject(path: checkout.path)
        try await store.update(project) { $0.icon = .image(path: "first.png") }
        await store.resolveIcon(for: project)
        guard case .image(let first) = store.icon(for: project) else { throw CoincideError("The original checkout icon was not loaded.") }
        #expect(first.size.width == 1)
        let remote = try #require(RepositoryIdentity.normalizedRemote("https://github.com/fixture/icon-namespace.git"))
        project.repositoryIdentity = try RepositoryIdentity(remote: remote, remoteName: "origin", rootPath: project.path, projectRelativePath: "")
        try ProjectSettingsFiles.save(.init(key: ProjectSettingsKey.primary(for: project), icon: .image(path: "second.png")), root: settingsRoot)
        #expect(store.icon(for: project) == nil, "The old namespace's cached image must disappear immediately.")
        await store.resolveIcon(for: project)
        guard case .image(let second) = store.icon(for: project) else { throw CoincideError("The repository icon was not loaded.") }
        #expect(second.size.width == 2)
    } catch { await store.shutdown(); try? FileManager.default.removeItem(at: base); throw error }
    await store.shutdown(); try FileManager.default.removeItem(at: base)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func projectSettingsEditorsAndReorderRowsRetainTheirOriginalCaptureAcrossOtherWindowAndSameStoreEdits() async throws {
    let base = try projectActionsPhysicalTemporaryDirectory().appendingPathComponent("coincide-settings-editor-" + UUID().uuidString)
    let root = base.appendingPathComponent("Settings"), checkout = base.appendingPathComponent("Checkout")
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let t3 = Data("{\"scripts\":[{\"name\":\"Original\",\"command\":\"never execute\"}]}".utf8)
    try t3.write(to: checkout.appendingPathComponent("t3.json"))
    let suite = "coincide-settings-editor-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let project = WorkspaceProject(path: checkout.path), first = ProjectSettingsStore(root: root, defaults: defaults), second = ProjectSettingsStore(root: root, defaults: defaults)
    do {
        let actions = try [ProjectAction(id: "one", input: .init(name: "One", command: "printf original-one")),
                           ProjectAction(id: "two", input: .init(name: "Two", command: "printf original-two"))]
        try await first.update(project) { $0.actions = actions }
        await second.load(project)
        let staleEditor = try #require(second.capture(for: project))
        try await first.update(project) { $0.actions = try ProjectActions.updating("one", with: .init(name: "One", command: "printf newer-one"), in: $0.actions ?? []) }
        await #expect(throws: CoincideError.self) {
            try await second.update(project, expectedCapture: staleEditor) { $0.actions = Array(($0.actions ?? []).reversed()) }
        }
        let current = try #require(try ProjectSettingsFiles.load(root: root, key: ProjectSettingsKey.primary(for: project)))
        #expect(current.actions?.map(\.id) == ["one", "two"] && current.actions?.first?.command == "printf newer-one")
        // A failed stale form refreshes the shared cache, but its captured token
        // remains old and cannot overwrite that newer state on a second Save.
        #expect(second.document(for: project).actions?.first?.command == "printf newer-one")
        await #expect(throws: CoincideError.self) {
            try await second.update(project, expectedCapture: staleEditor) { $0.actions = actions }
        }
        let sameStoreForm = try #require(second.capture(for: project))
        try await second.update(project) { $0.icon = .emoji("🌍") }
        await #expect(throws: CoincideError.self) {
            try await second.update(project, expectedCapture: sameStoreForm) { $0.icon = .emoji("🚀") }
        }
        #expect(try ProjectSettingsFiles.load(root: root, key: ProjectSettingsKey.primary(for: project))?.icon == .emoji("🌍"))
        #expect(try Data(contentsOf: checkout.appendingPathComponent("t3.json")) == t3)
    } catch { await first.shutdown(); await second.shutdown(); try? FileManager.default.removeItem(at: base); throw error }
    await first.shutdown(); await second.shutdown(); try FileManager.default.removeItem(at: base)
}

@MainActor @Test func projectSettingsStorePreservesCorruptionAfterCaptureAndRejectsLateShutdownEdits() async throws {
    let base = try projectActionsPhysicalTemporaryDirectory().appendingPathComponent("coincide-settings-stale-file-" + UUID().uuidString)
    let project = WorkspaceProject(path: base.appendingPathComponent("Checkout").path)
    let suite = "coincide-settings-stale-file-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let store = ProjectSettingsStore(root: base, defaults: defaults)
    do {
        try await store.update(project) { $0.icon = .emoji("🌍") }
        let capture = try #require(store.capture(for: project)), file = ProjectSettingsFiles.fileURL(root: base, key: ProjectSettingsKey.primary(for: project))
        let corrupt = Data("{private malformed settings".utf8); try corrupt.write(to: file)
        await #expect(throws: CoincideError.self) { try await store.update(project, expectedCapture: capture) { $0.icon = nil } }
        #expect(try Data(contentsOf: file) == corrupt)
        #expect(store.loadErrors[store.key(for: project)] != nil && store.capture(for: project) == nil)
        await store.shutdown()
        await #expect(throws: CancellationError.self) { try await store.update(project) { $0.actions = [] } }
        #expect(try Data(contentsOf: file) == corrupt)
    } catch { await store.shutdown(); try? FileManager.default.removeItem(at: base); throw error }
    await store.shutdown(); try FileManager.default.removeItem(at: base)
}

@MainActor @Test func projectSettingsRetainedFormRefusesChangedRegisteredNamespaceWithoutWritingEitherKey() async throws {
    let f = try keyboardFixtureStore(), project = f.projects[0], store = f.store.projectSettings
    do {
        try await store.update(project) { $0.icon = .emoji("🌍") }
        let capture = try #require(store.capture(for: project)), scope = ProjectSettingsPresentationScope(project: project)
        var resolved = project
        let remote = try #require(RepositoryIdentity.normalizedRemote("https://github.com/fixture/private-local-test.git"))
        resolved.repositoryIdentity = try RepositoryIdentity(remote: remote, remoteName: "origin", rootPath: project.path, projectRelativePath: "")
        let primary = ProjectSettingsKey.primary(for: resolved), fallback = ProjectSettingsKey.primary(for: project)
        #expect(primary != fallback)
        try ProjectSettingsFiles.save(.init(key: primary, icon: .emoji("🚀")), root: store.root)
        let primaryBytes = try Data(contentsOf: ProjectSettingsFiles.fileURL(root: store.root, key: primary))
        let fallbackBytes = try Data(contentsOf: ProjectSettingsFiles.fileURL(root: store.root, key: fallback))
        let index = try #require(f.store.snapshot.projects.firstIndex(where: { $0.id == project.id }))
        f.store.snapshot.projects[index] = resolved
        // File CAS alone remains valid for the old fallback, so the registered
        // namespace guard is what prevents this retained editor from saying Saved.
        #expect(try ProjectSettingsFiles.capture(root: store.root, keys: [fallback]).revisions == capture.revisions)
        await #expect(throws: CoincideError.self) {
            try await store.update(project, expectedCapture: capture,
                sourceIsCurrent: { scope.matches(f.store.snapshot.projects.first(where: { $0.id == project.id })) }) { $0.icon = .emoji("🧪") }
        }
        #expect(try Data(contentsOf: ProjectSettingsFiles.fileURL(root: store.root, key: primary)) == primaryBytes)
        #expect(try Data(contentsOf: ProjectSettingsFiles.fileURL(root: store.root, key: fallback)) == fallbackBytes)
        var recreated = project; recreated.createdAt = Date(timeIntervalSince1970: (project.createdAt?.timeIntervalSince1970 ?? 0) + 1)
        #expect(!scope.matches(recreated))
        var moved = project; moved.path += "/moved"; #expect(!scope.matches(moved))
    } catch { await f.store.shutdown(); try? FileManager.default.removeItem(at: f.root); throw error }
    await f.store.shutdown(); try FileManager.default.removeItem(at: f.root)
}

private final class ProjectSettingsQueuedWriteGate: @unchecked Sendable {
    let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let semaphore = DispatchSemaphore(value: 0)
    init() { let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1)); started = pair.stream; continuation = pair.continuation }
    func hold() { continuation.yield(()); continuation.finish(); semaphore.wait() }
    func release() { semaphore.signal() }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func projectSettingsQueuedWriteRechecksNamespaceBeforeOriginalWorkerAdmission() async throws {
    let f = try keyboardFixtureStore(), project = f.projects[0], store = f.store.projectSettings
    let gate = ProjectSettingsQueuedWriteGate(); defer { gate.release() }
    do {
        try await store.update(project) { $0.icon = .emoji("🌍") }
        let first = Task { try await store.update(project) { gate.hold(); $0.icon = .emoji("🌱") } }
        for await _ in gate.started { break }
        var isCurrent = true, checks = 0
        let second = Task { try await store.update(project, sourceIsCurrent: { checks += 1; return isCurrent }) { $0.icon = .emoji("🧪") } }
        while checks == 0 { await Task.yield() }
        isCurrent = false
        gate.release()
        _ = try await first.value
        switch await second.result {
        case .success: Issue.record("A queued settings edit was admitted after its namespace changed.")
        case .failure(let error): #expect(error.localizedDescription == ProjectSettingsPresentationScope.changed.localizedDescription)
        }
        #expect(checks >= 2)
        #expect(try ProjectSettingsFiles.load(root: store.root, key: ProjectSettingsKey.primary(for: project))?.icon == .emoji("🌱"))
    } catch { gate.release(); await f.store.shutdown(); try? FileManager.default.removeItem(at: f.root); throw error }
    await f.store.shutdown(); try FileManager.default.removeItem(at: f.root)
}
