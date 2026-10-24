import Foundation
import Testing
@testable import CoincideCore

private func cliRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-cli-shim-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test(.timeLimit(.minutes(1)))
func cliShimScriptQuotesTheAppPathAndEncodesFolderLinksForTheApp() async throws {
    let root = try cliRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let script = CLIShim.script(appPath: "/Applications/It's \"Coincide\".app", bundleIdentifier: "com.apoorvdarshan.coincide")
    #expect(script.contains("COINCIDE_APP='/Applications/It'\"'\"'s \"Coincide\".app'"))
    #expect(script.split(separator: "\n").prefix(3).contains { $0 == "# " + CLIShim.marker })
    let shim = root.appendingPathComponent("coincide")
    try script.write(to: shim, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
    let syntax = await BoundedProcess.run(executable: "/bin/sh", arguments: ["-n", shim.path], environment: [:], timeout: .seconds(10), outputLimit: 4_096)
    #expect(syntax.status == 0)
    let folder = root.appendingPathComponent("My \"Project\" & it's café", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let env = ["PATH": "/usr/bin:/bin", "COINCIDE_PRINT_LINK": "1"]
    let printed = await BoundedProcess.run(executable: shim.path, arguments: [], environment: env, directory: folder.path, timeout: .seconds(10), outputLimit: 16_384)
    let line = String(decoding: printed.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let expected = folder.resolvingSymlinksInPath().path
    #expect(printed.status == 0 && (try? PromptLink.parse(URL(string: line)!).get()) == .openFolder(path: expected), "\(line)")
    let explicit = await BoundedProcess.run(executable: shim.path, arguments: [folder.path], environment: env, timeout: .seconds(10), outputLimit: 16_384)
    #expect(String(decoding: explicit.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == line)
    let missing = await BoundedProcess.run(executable: shim.path, arguments: [root.appendingPathComponent("absent").path], environment: env,
                                           timeout: .seconds(10), outputLimit: 16_384, mergeStandardError: true)
    #expect(missing.status == 1 && String(decoding: missing.output, as: UTF8.self).contains("is not a folder"))
    let help = await BoundedProcess.run(executable: shim.path, arguments: ["--help"], environment: env, timeout: .seconds(10), outputLimit: 4_096)
    #expect(help.status == 0 && String(decoding: help.output, as: UTF8.self).contains("Usage: coincide [folder]"))
}

@Test func cliShimRoutesNewControlsWithoutOpeningFoldersOrChangingArguments() async throws {
    let root = try cliRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("It's Coincide.app")
    let resource = app.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resource, withIntermediateDirectories: true)
    try "import json, sys\nprint(json.dumps(sys.argv[1:]))\n".write(to: resource.appendingPathComponent("coincide"), atomically: true, encoding: .utf8)
    let shim = root.appendingPathComponent("coincide")
    try CLIShim.script(appPath: app.path, bundleIdentifier: "synthetic.test").write(to: shim, atomically: true, encoding: .utf8)
    let commands = ["sort", "export", "compact", "compaction", "compaction-cancel", "integrations", "integration-import", "integration-remove", "integration-use", "sessions", "session-details", "session-stop", "configuration", "configuration-set"]
    for command in commands {
        let arguments = [command, "literal argument $HOME ; 'quoted'", "--flag"]
        let result = await BoundedProcess.run(executable: "/bin/sh", arguments: [shim.path] + arguments,
            environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(10), outputLimit: 4_096)
        #expect(result.status == 0)
        #expect(try JSONDecoder().decode([String].self, from: result.output) == arguments)
    }
}

@Test func cliShimInstallerPrefersPathDirectoriesRefusesForeignFilesAndRemovesOnlyItsOwn() throws {
    let root = try cliRoot(); defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("readonly").path)
        try? FileManager.default.removeItem(at: root)
    }
    let readonly = root.appendingPathComponent("readonly"), foreign = root.appendingPathComponent("foreign"),
        offPath = root.appendingPathComponent("off-path"), onPath = root.appendingPathComponent("on-path"), created = root.appendingPathComponent("created")
    for directory in [readonly, foreign, offPath, onPath] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    try Data("#!/bin/sh\necho someone else\n".utf8).write(to: foreign.appendingPathComponent("coincide"))
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readonly.path)
    let script = CLIShim.script(appPath: "/Applications/Coincide.app", bundleIdentifier: "com.apoorvdarshan.coincide")
    let installer = CLIShimInstaller(directories: [readonly, foreign, offPath, onPath],
                                     pathEntries: [foreign.path, readonly.path, onPath.path + "/"], creatableDirectory: created)
    #expect(installer.state() == .notInstalled)
    let installed = try installer.install(script: script)
    #expect(installed.url == onPath.appendingPathComponent("coincide") && installed.onPath)
    #expect(installed.shadowedBy == foreign.appendingPathComponent("coincide"), "A foreign command earlier on PATH is reported.")
    #expect(installer.state() == .installed(installed.url) && CLIShim.isShim(at: installed.url))
    let attributes = try FileManager.default.attributesOfItem(atPath: installed.url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    // Reinstalling replaces only its own file.
    #expect(try installer.install(script: script).url == installed.url)
    #expect(try installer.remove() == [installed.url])
    #expect(FileManager.default.fileExists(atPath: foreign.appendingPathComponent("coincide").path) && installer.state() == .notInstalled)

    let offPathOnly = CLIShimInstaller(directories: [foreign, offPath], pathEntries: [], creatableDirectory: created)
    let fallback = try offPathOnly.install(script: script)
    #expect(fallback.url == offPath.appendingPathComponent("coincide") && !fallback.onPath)
    try offPathOnly.remove()

    let blocked = CLIShimInstaller(directories: [foreign], pathEntries: [foreign.path], creatableDirectory: nil)
    #expect(throws: CoincideError.self) { try blocked.install(script: script) }
    let creates = CLIShimInstaller(directories: [readonly, created], pathEntries: [], creatableDirectory: created)
    #expect(try creates.install(script: script).url == created.appendingPathComponent("coincide"))
}

@Test func cliShimInstallerPreservesDanglingLinksLinkedCommandsAndLinkedDirectories() throws {
    let root = try cliRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("bin"), outside = root.appendingPathComponent("unrelated")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let command = directory.appendingPathComponent("coincide")
    let script = CLIShim.script(appPath: "/Applications/Coincide.app", bundleIdentifier: "com.apoorvdarshan.coincide")
    let installer = CLIShimInstaller(directories: [directory], pathEntries: [directory.path], creatableDirectory: nil)
    try FileManager.default.createSymbolicLink(at: command, withDestinationURL: outside)
    #expect(!CLIShim.isShim(at: command) && installer.state() == .notInstalled)
    #expect(throws: CoincideError.self) { try installer.install(script: script) }
    #expect(try installer.remove().isEmpty)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: command.path) == outside.path)
    #expect(!FileManager.default.fileExists(atPath: outside.path))
    try FileManager.default.removeItem(at: command)

    try Data(script.utf8).write(to: outside)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
    try FileManager.default.createSymbolicLink(at: command, withDestinationURL: outside)
    #expect(throws: CoincideError.self) { try installer.install(script: script) }
    #expect(try installer.remove().isEmpty)
    #expect(try Data(contentsOf: outside) == Data(script.utf8))
    try FileManager.default.removeItem(at: command)

    try FileManager.default.linkItem(at: outside, to: command)
    #expect(!CLIShim.isShim(at: command))
    #expect(throws: CoincideError.self) { try installer.install(script: script) }
    let hardLinkRemoved = try installer.remove(), hardLinkOriginal = try Data(contentsOf: outside)
    #expect(hardLinkRemoved.isEmpty && hardLinkOriginal == Data(script.utf8))
    try FileManager.default.removeItem(at: command)

    let installed = try installer.install(script: script)
    let alias = root.appendingPathComponent("linked-bin")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
    let linked = CLIShimInstaller(directories: [alias], pathEntries: [alias.path], creatableDirectory: nil)
    #expect(linked.state() == .notInstalled)
    #expect(throws: CoincideError.self) { try linked.install(script: script) }
    #expect(try linked.remove().isEmpty)
    let keptOutside = try Data(contentsOf: outside)
    #expect(CLIShim.isShim(at: installed.url) && keptOutside == Data(script.utf8))
}

@Test func cliShimReinstallUpdatesOnlyItsOwnedInodeAndRejectsUnboundedUnmarkedInput() throws {
    let root = try cliRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let installer = CLIShimInstaller(directories: [root], pathEntries: [root.path], creatableDirectory: nil)
    let original = CLIShim.script(appPath: "/Applications/Original.app", bundleIdentifier: "com.example.original")
    let changed = CLIShim.script(appPath: "/Applications/Changed App.app", bundleIdentifier: "com.example.changed")
    let installed = try installer.install(script: original)
    let before = try FileManager.default.attributesOfItem(atPath: installed.url.path)[.systemFileNumber] as? NSNumber
    #expect(try installer.install(script: changed).url == installed.url)
    let after = try FileManager.default.attributesOfItem(atPath: installed.url.path)[.systemFileNumber] as? NSNumber
    let replacedBytes = try Data(contentsOf: installed.url)
    #expect(before == after && replacedBytes == Data(changed.utf8))
    #expect(installer.foreignCommandOnPath() == nil)
    #expect(throws: CoincideError.self) { try installer.install(script: "#!/bin/sh\necho unrelated\n") }
    #expect(throws: CoincideError.self) { try installer.install(script: changed + String(repeating: "x", count: CLIShim.maximumShimBytes)) }
    #expect(try Data(contentsOf: installed.url) == Data(changed.utf8))
    #expect(try installer.remove() == [installed.url])
}
