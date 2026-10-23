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
