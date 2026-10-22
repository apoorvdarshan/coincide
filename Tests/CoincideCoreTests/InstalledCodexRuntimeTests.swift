import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Explicit opt-in: download the exact complete public package into private
/// scratch, verify its version, initialize stdio, then drain. No login, account,
/// model discovery, thread creation, prompt, or provider-token request is sent.
@Test(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_VERIFY_CODEX_INSTALLATION"] == "1"))
func installedManagedCodexCompletePackageVerifiesAndInitializesWithoutAuthentication() async throws {
    let release = try #require(CodexManagedRelease.current)
    #expect(release.version == "0.156.1")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-installed-codex-" + UUID().uuidString, isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let service = CodexInstallation(rootURL: root.appendingPathComponent("managed", isDirectory: true), release: release)
    var session: CodexSession?, heldLease: CodexInstallationLease?
    do {
        let operationID = try service.start()
        for await state in service.updates() where state.operationID == operationID {
            if !state.phase.isWorking { break }
        }
        try await service.cancel(operationID: operationID)
        let state = service.state()
        #expect(state.phase == .succeeded, "Pinned runtime verification: \(state.message ?? state.phase.rawValue)")
        guard state.phase == .succeeded else { throw CoincideError("The pinned Codex runtime did not verify.") }
        #expect(state.downloadedBytes == release.archiveBytes)
        #expect(state.installedVersion == release.version && state.source == .managed)

        let home = root.appendingPathComponent("private-home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        for directory in [home, workspace, temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        // Force this fresh home to file-only credential storage, so a handshake
        // cannot consult an existing system-keyring CLI account. Analytics also
        // remain disabled; this test needs only the local stdio initialization.
        try Data("cli_auth_credentials_store = \"file\"\n[analytics]\nenabled = false\n".utf8)
            .write(to: home.appendingPathComponent("config.toml"), options: .withoutOverwriting)
        let configuration = CodexRuntimeConfiguration(instanceID: UUID(), selection: .managed, homeDirectory: home.path)
        let lease = try service.acquire(configuration: configuration); heldLease = lease
        #expect(lease.releaseID == release.sha256)
        #expect(lease.resolved.version == release.version && lease.resolved.source == .managed)
        let package = try #require(lease.resolved.managedDirectory)
        #expect(lease.resolved.executable == package.appendingPathComponent("bin/" + release.executableName))
        let paths = try installedCodexPackageInventory(package)
        let resources = [
            "codex-resources/voice/bin/codex-voice-host",
            "codex-resources/voice/lib/libglib-2.0.0.dylib",
            "codex-resources/voice/plugins/libgstapp.dylib",
            "codex-resources/voice/licenses/LGPL-2.1.txt",
            "codex-resources/voice/NOTICE.md", "codex-resources/voice/manifest.json",
            "codex-resources/voice/runtime.json", "codex-resources/voice/sources.json",
            "codex-resources/zsh/bin/zsh"
        ]
        #expect(Set(release.requiredExecutablePaths + ["codex-package.json"] + resources).isSubset(of: paths.files))
        if release.target == "aarch64-apple-darwin" {
            // Independently observed from the exact pinned archive, excluding
            // Coincide's two installation receipts; do not infer other targets.
            #expect(paths.files.count == 42 && paths.directories.count == 10)
        }
        for path in release.requiredExecutablePaths + [resources[0], resources.last!] {
            var node = stat()
            #expect(lstat(package.appendingPathComponent(path).path, &node) == 0)
            #expect(node.st_mode & S_IFMT == S_IFREG && node.st_size > 0 && node.st_mode & 0o111 != 0)
        }
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: package.appendingPathComponent("codex-package.json")))
        #expect(manifest["layoutVersion"] == .number(1) && manifest["version"] == .string(release.version))
        #expect(manifest["target"] == .string(release.target) && manifest["variant"] == .string("codex"))
        #expect(manifest["entrypoint"] == .string("bin/" + release.executableName))
        #expect(manifest["resourcesDir"] == .string("codex-resources") && manifest["pathDir"] == .string("codex-path"))

        // An allowlist keeps all provider credentials, launch overrides and
        // user config locations out of this explicitly isolated child.
        let inherited = ProcessChannel.environment()
        var environment: [String: String] = [:]
        for name in ["PATH", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "SHELL", "__CF_USER_TEXT_ENCODING"] { environment[name] = inherited[name] }
        environment["HOME"] = home.path; environment["CODEX_HOME"] = home.path; environment["TMPDIR"] = temporary.path + "/"
        environment["XDG_CONFIG_HOME"] = home.path; environment["XDG_DATA_HOME"] = home.path; environment["XDG_STATE_HOME"] = home.path
        let connected = try CodexSession(executable: lease.resolved.executable, cwd: workspace, environment: environment,
                                         installationLease: lease, runtimeConfiguration: configuration)
        session = connected
        try await connected.connect() // initialize + initialized only.
        #expect(throws: CodexInstallationError(.busy)) { try service.remove() }
        await connected.close() // Production actor joins its process/readers before releasing the binary lease.
        session = nil; heldLease = nil
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
        try service.remove(); await service.shutdown()
        #expect(!FileManager.default.fileExists(atPath: service.rootURL.path))
        try FileManager.default.removeItem(at: root)
    } catch {
        await session?.close(); heldLease?.release()
        if let operationID = service.state().operationID { try? await service.cancel(operationID: operationID) }
        try? service.remove(); await service.shutdown()
        // Preserve a root whose installer ownership could not be established.
        if !FileManager.default.fileExists(atPath: service.rootURL.path) { try? FileManager.default.removeItem(at: root) }
        throw error
    }
}

private func installedCodexPackageInventory(_ package: URL) throws -> (files: Set<String>, directories: Set<String>) {
    let enumerator = try #require(FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]))
    let parent = package.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    var files = Set<String>(), directories = Set<String>(), count = 0
    for case let url as URL in enumerator {
        count += 1; guard count <= 10_002 else { throw CoincideError("The pinned Codex package inventory exceeded its bound.") }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw CoincideError("The pinned Codex package contains an unexpected symbolic link.") }
        let child = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard child.count > parent.count, child.starts(with: parent) else { throw CoincideError("The pinned Codex package member changed location.") }
        let path = child.dropFirst(parent.count).joined(separator: "/")
        if [CodexPackageInventory.filename, CodexPackageInventory.completion].contains(path) { continue }
        if values.isDirectory == true { directories.insert(path) }
        else {
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else { throw CoincideError("The pinned Codex package contains an unexpected or empty member.") }
            files.insert(path)
        }
    }
    return (files, directories)
}
