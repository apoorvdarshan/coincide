import Darwin
import Foundation
import Testing
@testable import CoincideCore

private func withExternalEditorWorkspace(_ body: (URL, WorkspaceFileService) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-editor-core-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = WorkspaceFileService(root: root)
    do { try await body(root, service); await service.close() }
    catch { await service.close(); throw error }
}

@Test func externalEditorCatalogUsesKnownUniqueIDsAndPositiveOneBasedLocations() throws {
    let expected = ["cursor", "trae", "kiro", "vscode", "vscode-insiders", "vscodium", "zed", "antigravity", "idea", "aqua", "clion", "datagrip", "dataspell", "goland", "phpstorm", "pycharm", "rider", "rubymine", "rustrover", "webstorm", "file-manager", "xcode"]
    let descriptors = ExternalEditorCatalog.editors
    #expect(Set(descriptors.map { $0.id.rawValue }) == Set(expected))
    #expect(descriptors.count == expected.count && descriptors.allSatisfy { !$0.name.isEmpty })
    for descriptor in descriptors {
        let encoded = try JSONEncoder().encode(descriptor.id)
        #expect(try JSONDecoder().decode(ExternalEditorID.self, from: encoded) == descriptor.id)
    }
    #expect(throws: (any Error).self) { try JSONDecoder().decode(ExternalEditorID.self, from: Data("\"unknown-editor\"".utf8)) }
    for line in [0, -1, Int.min] { #expect(throws: (any Error).self) { try ExternalEditorLocation(line: line) } }
    for column in [0, -1, Int.min] { #expect(throws: (any Error).self) { try ExternalEditorLocation(line: 1, column: column) } }
    _ = try ExternalEditorLocation(line: 1)
    _ = try ExternalEditorLocation(line: 12, column: 4)
}

@Test(.timeLimit(.minutes(1)))
func externalEditorMetadataAllowsExistingBinaryFilesDirectoriesAndInternalLinksWithoutReadingContents() async throws {
    try await withExternalEditorWorkspace { root, service in
        let directory = root.appendingPathComponent("nested"), file = directory.appendingPathComponent("binary file.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0, 255, 1, 0]).write(to: file)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("file-link").path, withDestinationPath: "nested/binary file.bin")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("directory-link").path, withDestinationPath: "nested")
        let workspace = try await service.metadata(), folder = try await service.metadata(relativePath: "directory-link")
        let binary = try await service.metadata(relativePath: "nested/binary file.bin"), link = try await service.metadata(relativePath: "file-link")
        #expect(workspace.kind == .directory && workspace.resolvedURL.path == root.path)
        #expect(folder.kind == .directory && folder.resolvedURL.path == directory.path)
        #expect(binary.kind == .file && binary.byteLength == 4 && binary.resolvedURL.path == file.path)
        #expect(link.kind == .file && link.resolvedURL.path == file.path && link.byteLength == 4)
        #expect(try Data(contentsOf: file) == Data([0, 255, 1, 0]))
    }
}

private func makeEditorBundle(root: URL, name: String, identifier: String, launcher: String) throws -> URL {
    let application = root.appendingPathComponent(name + ".app")
    let info: [String: String] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": identifier, "CFBundleExecutable": "Application"]
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    let contents = application.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    try plist.write(to: contents.appendingPathComponent("Info.plist"))
    for path in ["Contents/MacOS/Application", launcher] {
        let executable = application.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 97\n".utf8).write(to: executable)
        #expect(chmod(executable.path, 0o755) == 0)
    }
    return application
}

@Test(.timeLimit(.minutes(1)))
func externalEditorPlansPreserveLiteralArgvAndEditorSpecificLineConventionsWithoutExecutingThem() async throws {
    try await withExternalEditorWorkspace { root, service in
        let file = root.appendingPathComponent("file $value; [x]:7.swift")
        try Data("Saved file\n".utf8).write(to: file)
        let metadata = try await service.metadata(relativePath: file.lastPathComponent), location = try ExternalEditorLocation(line: 12, column: 4)
        let cases: [(ExternalEditorID, String, String, String, [String])] = [
            (.cursor, "Cursor", "com.todesktop.230313mzl4w4u92", "Contents/Resources/app/bin/cursor", ["--classic", "--goto", file.path + ":12:4"]),
            (.vscode, "Visual Studio Code", "com.microsoft.VSCode", "Contents/Resources/app/bin/code", ["--goto", file.path + ":12:4"]),
            (.kiro, "Kiro", "dev.kiro.desktop", "Contents/Resources/app/bin/kiro", ["--goto", file.path + ":12:4"]),
            (.zed, "Zed", "dev.zed.Zed", "Contents/MacOS/cli", [file.path + ":12:4"]),
            (.idea, "IntelliJ IDEA 2026.1.4", "com.jetbrains.intellij", "Contents/MacOS/idea", ["--line", "12", "--column", "4", file.path]),
            (.xcode, "Xcode", "com.apple.dt.Xcode", "Contents/Developer/usr/bin/xed", ["--line", "12", file.path])
        ]
        for (id, name, identifier, launcher, expectedArguments) in cases {
            let application = try makeEditorBundle(root: root, name: name, identifier: identifier, launcher: launcher)
            let installation = try ExternalEditorInstallation(id: id, applicationURL: application)
            let plan = try ExternalEditorCatalog.plan(editor: id, installation: installation, metadata: metadata, location: location)
            if case .command(let executable, let arguments) = plan {
                #expect(executable.path == application.appendingPathComponent(launcher).path && arguments == expectedArguments)
            } else { Issue.record("A positioned editor open did not preserve its documented argument vector.") }
            let withoutLocation = try ExternalEditorCatalog.plan(editor: id, installation: installation, metadata: metadata)
            if id == .cursor {
                if case .command(let executable, let arguments) = withoutLocation {
                    #expect(executable.path == application.appendingPathComponent(launcher).path && arguments == ["--classic", file.path])
                } else { Issue.record("A Cursor open lost its classic IDE argument.") }
            } else if case .application(let app, let target) = withoutLocation {
                #expect(app.path == application.path && target.path == file.path)
            } else { Issue.record("An ordinary app open did not preserve its app and file targets.") }
            let directory = try await service.metadata()
            #expect(throws: ExternalEditorError.self) { try ExternalEditorCatalog.plan(editor: id, installation: installation, metadata: directory, location: location) }
        }
        let fallback = try ExternalEditorCatalog.plan(editor: .fileManager, installation: nil, metadata: metadata, location: location)
        if case .defaultApplication(let target) = fallback { #expect(target.path == file.path) }
        else { Issue.record("The default application received an editor-specific launch plan.") }
        #expect(!ExternalEditorDescriptor(id: .xcode).supportsColumn && !ExternalEditorDescriptor(id: .fileManager).supportsLine)
        #expect(throws: ExternalEditorError.self) { try ExternalEditorCatalog.plan(editor: .cursor, installation: nil, metadata: metadata) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "Saved file\n")
    }
}

@Test(.timeLimit(.minutes(1)))
func externalEditorInstallationSeparatesStableInsidersAndHubBundlesAndRejectsEscapingLaunchers() async throws {
    try await withExternalEditorWorkspace { root, _ in
        let insiders = try makeEditorBundle(root: root, name: "Visual Studio Code - Insiders", identifier: "com.microsoft.VSCodeInsiders", launcher: "Contents/Resources/app/bin/code-insiders")
        _ = try ExternalEditorInstallation(id: .vscodeInsiders, applicationURL: insiders)
        #expect(throws: ExternalEditorError.self) { try ExternalEditorInstallation(id: .vscode, applicationURL: insiders) }
        let hub = try makeEditorBundle(root: root, name: "Antigravity", identifier: "com.google.antigravity", launcher: "Contents/Resources/app/bin/agy")
        #expect(throws: ExternalEditorError.self) { try ExternalEditorInstallation(id: .antigravity, applicationURL: hub) }
        let cursor = try makeEditorBundle(root: root, name: "Cursor", identifier: "com.todesktop.230313mzl4w4u92", launcher: "Contents/Resources/app/bin/cursor")
        let outside = root.appendingPathComponent("outside-launcher")
        try Data("#!/bin/sh\nexit 98\n".utf8).write(to: outside); #expect(chmod(outside.path, 0o755) == 0)
        let launcher = cursor.appendingPathComponent("Contents/Resources/app/bin/cursor")
        try FileManager.default.removeItem(at: launcher)
        try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: outside)
        #expect(throws: ExternalEditorError.self) { try ExternalEditorInstallation(id: .cursor, applicationURL: cursor) }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "#!/bin/sh\nexit 98\n")
    }
}

@Test(.timeLimit(.minutes(1)))
func externalEditorDiscoveryUsesOnlyInspectedFixtureBundlesAndDeduplicatesRegisteredApps() async throws {
    try await withExternalEditorWorkspace { root, _ in
        let cursor = try makeEditorBundle(root: root, name: "Cursor", identifier: "com.todesktop.230313mzl4w4u92", launcher: "Contents/Resources/app/bin/cursor")
        _ = try makeEditorBundle(root: root, name: "Visual Studio Code - Insiders", identifier: "com.microsoft.VSCodeInsiders", launcher: "Contents/Resources/app/bin/code-insiders")
        _ = try makeEditorBundle(root: root, name: "IntelliJ IDEA 2026.1.4", identifier: "com.jetbrains.intellij", launcher: "Contents/MacOS/idea")
        _ = try makeEditorBundle(root: root, name: "IntelliJ IDEA nightly", identifier: "com.jetbrains.intellij", launcher: "Contents/MacOS/idea")
        try Data("An unrelated ZFS daemon wrapper that is never run\n".utf8).write(to: root.appendingPathComponent("zed"))
        let result = try ExternalEditorCatalog.discover(applicationDirectories: [root], registeredApplications: [cursor, cursor])
        #expect(result.map(\.id) == [.cursor, .vscodeInsiders, .idea])
        #expect(result.filter { $0.id == .cursor }.count == 1)
    }
}

@Test(.timeLimit(.minutes(1)))
func externalEditorDetachedHandoffRejectsInvalidRequestsBeforeSpawnAndStripsInheritedAgentContext() async throws {
    let input = ["PATH": "/fixture/bin", "LANG": "en_US.UTF-8", "SSH_AUTH_SOCK": "/fixture/socket",
                 "ELECTRON_RUN_AS_NODE": "1", "CODEX_THREAD_ID": "fixture-thread", "GIT_DIR": "/fixture/git",
                 "GIT_WORK_TREE": "/fixture/worktree", "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.worktree", "GIT_CONFIG_VALUE_0": "/fixture/other",
                 "GIT_CONFIG_PARAMETERS": "core.worktree=/fixture/other", "GIT_IMPLICIT_WORK_TREE": "0", "GIT_DISCOVERY_ACROSS_FILESYSTEM": "1",
                 "GIT_SUPER_PREFIX": "fixture/", "GIT_NAMESPACE": "fixture"]
    #expect(DetachedExternalEditorLauncher.sanitizedEnvironment(input) == ["PATH": "/fixture/bin", "LANG": "en_US.UTF-8", "SSH_AUTH_SOCK": "/fixture/socket"])
    let neverExecute = URL(fileURLWithPath: "/coincide-fixture-must-not-execute")
    for arguments in [["bad\0argument"], Array(repeating: "argument", count: 33), [String(repeating: "x", count: 16_385)]] {
        #expect(throws: ExternalEditorError.self) { try DetachedExternalEditorLauncher.launch(executableURL: neverExecute, arguments: arguments) }
    }
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try DetachedExternalEditorLauncher.launch(executableURL: neverExecute, arguments: [])
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
}

@Test(.timeLimit(.minutes(1)))
func externalEditorMetadataRejectsEscapesDanglingLinksSpecialFilesAndMissingTargets() async throws {
    try await withExternalEditorWorkspace { root, service in
        let outside = root.deletingLastPathComponent().appendingPathComponent("coincide-editor-outside-" + UUID().uuidString)
        try Data("Outside bytes\n".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("external").path, withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "missing")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("loop").path, withDestinationPath: "loop")
        #expect(mkfifo(root.appendingPathComponent("fifo").path, 0o600) == 0)
        for path in [outside.path, "../" + outside.lastPathComponent, "external", "dangling", "loop", "fifo", "missing", "a/../missing", "bad\0path"] {
            await #expect(throws: WorkspaceFileError.self) { try await service.metadata(relativePath: path) }
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "Outside bytes\n")
        var value = stat(); #expect(lstat(root.appendingPathComponent("fifo").path, &value) == 0 && value.st_mode & S_IFMT == S_IFIFO)
    }
}

@Test(.timeLimit(.minutes(1)))
func externalEditorMetadataIsCancelledBeforeAccessAndCannotRebindAReplacedRoot() async throws {
    try await withExternalEditorWorkspace { root, service in
        try Data("Original\n".utf8).write(to: root.appendingPathComponent("original.txt"))
        _ = try await service.metadata(relativePath: "original.txt")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.metadata(relativePath: "original.txt")
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let moved = root.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Replacement\n".utf8).write(to: root.appendingPathComponent("original.txt"))
        await #expect(throws: WorkspaceFileError.self) { try await service.metadata(relativePath: "original.txt") }
        #expect(try String(contentsOf: moved.appendingPathComponent("original.txt"), encoding: .utf8) == "Original\n")
        #expect(try String(contentsOf: root.appendingPathComponent("original.txt"), encoding: .utf8) == "Replacement\n")
    }
}
