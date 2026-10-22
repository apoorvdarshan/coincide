import Darwin
import Foundation
import MachO

/// Test-only executable. Its immutable signed bytes stay in the test bundle;
/// private codex/gh/claude/pi paths are symlinks, and per-test configuration is data.
@main struct OfflineCLILauncher {
    struct Descriptor: Decodable {
        let version: Int
        let tool: String
        let root: String
        let python: String
        let peer: String
        let state: String
        let wire: String
    }
    struct InvalidFixture: Error {}
    static let peers: [String: Set<String>] = [
        "codex": ["codex_history_ui.py", "codex_steering_ui.py", "codex_models_ui.py"],
        "gh": ["github_pr_ui.py"],
        "claude": ["claude_history_ui.py"],
        "pi": ["pi_history_ui.py"]
    ]
    static func main() {
        do { try execute() }
        catch {
            let message = Array("The offline CLI fixture launcher rejected its configuration or could not execute its isolated Python peer.\n".utf8)
            message.withUnsafeBytes { _ = Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
            Darwin.exit(78)
        }
    }
    static func execute() throws {
        let environment = ProcessInfo.processInfo.environment
        let arguments = Array(CommandLine.arguments.dropFirst())
        let tool: String
        if arguments == ["app-server", "--stdio"] { tool = "codex" }
        else if arguments == ["--version"], URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "pi" { tool = "pi" }
        else if validPiArguments(arguments) { tool = "pi" }
        else if validClaudeArguments(arguments) { tool = "claude" }
        else if let first = arguments.first, ["api", "pr", "--version"].contains(first) { tool = "gh" }
        else { throw InvalidFixture() }
        guard environment["COINCIDE_UI_TESTING"] == "1",
              let rootPath = environment["COINCIDE_UI_TEST_ROOT"], validAbsolutePath(rootPath),
              URL(fileURLWithPath: rootPath).lastPathComponent.hasPrefix("coincide-ui-testing-"),
              let expectedPython = environment["COINCIDE_UI_PYTHON_PATH"], validAbsolutePath(expectedPython) else { throw InvalidFixture() }
        var rootInfo = stat()
        guard lstat(rootPath, &rootInfo) == 0, rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              rootInfo.st_uid == getuid(), rootInfo.st_mode & 0o077 == 0 else { throw InvalidFixture() }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        // Foundation spells /private/var as /var; Python realpath uses the
        // former. Bind the supplied spelling below, but compare directory
        // identity rather than rejecting these aliases of the same owner.
        var resolvedRootInfo = stat()
        guard stat(root.resolvingSymlinksInPath().path, &resolvedRootInfo) == 0,
              resolvedRootInfo.st_dev == rootInfo.st_dev, resolvedRootInfo.st_ino == rootInfo.st_ino else { throw InvalidFixture() }
        let descriptorURL = root.appendingPathComponent(tool + ".offline.json")
        let data = try regularData(descriptorURL.path, maximum: 65_536, privateFile: true)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "tool", "root", "python", "peer", "state", "wire"] else { throw InvalidFixture() }
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: data)
        guard descriptor.version == 1, descriptor.tool == tool, descriptor.root == rootPath,
              descriptor.python == expectedPython, peers[tool]?.contains(descriptor.peer) == true,
              privateChild(descriptor.state, root: rootPath), privateChild(descriptor.wire, root: rootPath),
              descriptor.state != descriptor.wire, FileManager.default.isExecutableFile(atPath: expectedPython) else { throw InvalidFixture() }
        _ = try regularData(descriptor.state, maximum: 4_194_304, privateFile: true)
        var wireInfo = stat()
        if lstat(descriptor.wire, &wireInfo) == 0 {
            guard wireInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), wireInfo.st_uid == getuid() else { throw InvalidFixture() }
        } else if errno != ENOENT { throw InvalidFixture() }

        var executableSize: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &executableSize)
        guard executableSize > 0, executableSize <= 65_536 else { throw InvalidFixture() }
        var executableBuffer = [CChar](repeating: 0, count: Int(executableSize))
        guard _NSGetExecutablePath(&executableBuffer, &executableSize) == 0 else { throw InvalidFixture() }
        let executable = URL(fileURLWithPath: String(cString: executableBuffer)).resolvingSymlinksInPath()
        let resources = executable.deletingLastPathComponent()
        guard executable.lastPathComponent == "CoincideOfflineCLI", resources.lastPathComponent == "Resources",
              resources.deletingLastPathComponent().lastPathComponent == "Contents",
              resources.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "CoincideDesktopUITests.xctest" else { throw InvalidFixture() }
        if tool == "claude" {
            // The native peer can observe only two exact task-owned namespaces.
            for (key, child) in [("CLAUDE_CONFIG_DIR", "private-claude-config"), ("HOME", "private-claude-home")] {
                guard environment[key] == rootPath + "/" + child else { throw InvalidFixture() }
                var info = stat()
                guard lstat(rootPath + "/" + child, &info) == 0,
                      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == getuid(),
                      info.st_mode & 0o077 == 0 else { throw InvalidFixture() }
            }
        }
        if tool == "pi" {
            for (key, child) in [("HOME", "private-pi-home"), ("PI_CODING_AGENT_DIR", "private-pi-agent"),
                                 ("PI_CODING_AGENT_SESSION_DIR", "private-pi-sessions")] {
                guard let value = environment[key], privatePiDirectory(value, expected: rootPath + "/" + child) else { throw InvalidFixture() }
            }
        }
        let peer = resources.appendingPathComponent(descriptor.peer)
        _ = try regularData(peer.path, maximum: 1_048_576, privateFile: false)
        // No shell, search path, fork, or persistent launcher parent. Python
        // replaces this PID and inherits the provider's stdin/stdout/signals.
        let values = [expectedPython, "-I", "-S", peer.path, descriptor.state, descriptor.wire] + arguments
        var pointers = values.map { strdup($0) }
        guard pointers.allSatisfy({ $0 != nil }) else { pointers.forEach { free($0) }; throw InvalidFixture() }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        _ = pointers.withUnsafeMutableBufferPointer { execv(expectedPython, $0.baseAddress!) }
        throw InvalidFixture()
    }
    static let claudeArguments = ["--print", "--input-format", "stream-json", "--output-format", "stream-json",
        "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio",
        "--allow-dangerously-skip-permissions"]
    static func validPiArguments(_ arguments: [String]) -> Bool {
        guard Array(arguments.prefix(2)) == ["--mode", "rpc"] else { return false }
        if arguments.count == 2 { return true }
        guard arguments.count == 4, arguments[2] == "--extension", validAbsolutePath(arguments[3]) else { return false }
        let path = URL(fileURLWithPath: arguments[3])
        return path.lastPathComponent == "permission.ts" && path.deletingLastPathComponent().lastPathComponent.hasPrefix("coincide-pi-")
    }
    static func privatePiDirectory(_ value: String, expected: String) -> Bool {
        func appleSpelling(_ path: String) -> String { path.hasPrefix("/private/var/") ? String(path.dropFirst(8)) : path }
        guard validAbsolutePath(value), appleSpelling(value) == appleSpelling(expected) else { return false }
        var supplied = stat(), bound = stat()
        return lstat(value, &supplied) == 0 && stat(expected, &bound) == 0 &&
            supplied.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) && supplied.st_uid == getuid() && supplied.st_mode & 0o077 == 0 &&
            supplied.st_dev == bound.st_dev && supplied.st_ino == bound.st_ino
    }
    static func validClaudeArguments(_ arguments: [String]) -> Bool {
        guard Array(arguments.prefix(claudeArguments.count)) == claudeArguments else { return false }
        let suffix = Array(arguments.dropFirst(claudeArguments.count))
        func uuid(_ value: String) -> Bool { value.utf8.count == 36 && UUID(uuidString: value) != nil }
        if suffix.isEmpty { return true }
        if suffix.count == 2, suffix[0] == "--session-id" { return uuid(suffix[1]) }
        guard (suffix.count == 2 || suffix.count == 3), suffix[0] == "--resume", uuid(suffix[1]) else { return false }
        if suffix.count == 2 { return true }
        let flag = "--resume-session-at="
        return suffix[2].hasPrefix(flag) && uuid(String(suffix[2].dropFirst(flag.count)))
    }
    static func validAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 32_768 && !path.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
            && path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func privateChild(_ path: String, root: String) -> Bool {
        guard validAbsolutePath(path), path.hasPrefix(root + "/") else { return false }
        let name = String(path.dropFirst(root.count + 1))
        return !name.isEmpty && name.count <= 240 && !name.contains("/") && name != "." && name != ".."
    }
    static func regularData(_ path: String, maximum: Int, privateFile: Bool) throws -> Data {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw InvalidFixture() }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(), info.st_size > 0, info.st_size <= maximum,
              !privateFile || info.st_mode & 0o077 == 0 else { throw InvalidFixture() }
        var result = Data(count: Int(info.st_size))
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw InvalidFixture() }
                offset += count
            }
        }
        return result
    }
}
