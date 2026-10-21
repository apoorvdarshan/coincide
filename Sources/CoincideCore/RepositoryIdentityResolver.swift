import Foundation

/// Resolves only local Git metadata. It never fetches, invokes a remote helper, runs hooks, or
/// performs provider discovery. Each call reads current configuration; caching belongs to its owner.
public struct RepositoryIdentityResolver: Sendable {
    public let root: URL
    private let environment: [String: String]?
    private let executable: URL?
    private let timeout: Duration
    public init(root: URL) { self.root = root; environment = nil; executable = nil; timeout = .seconds(10) }
    init(root: URL, environment: [String: String], executable: URL? = nil, timeout: Duration = .seconds(10)) {
        self.root = root; self.environment = environment; self.executable = executable; self.timeout = timeout
    }
    public func resolve() async throws -> RepositoryIdentity? {
        try Task.checkCancellation()
        let operation = Task.detached { try await self.resolveLocally() }
        return try await withTaskCancellationHandler {
            let result = try await operation.value; try Task.checkCancellation(); return result
        } onCancel: { operation.cancel() }
    }
    private func resolveLocally() async throws -> RepositoryIdentity? {
        guard root.isFileURL else { throw CoincideError("Choose a local folder for repository metadata.") }
        let project = root.standardizedFileURL.resolvingSymlinksInPath()
        let top = try await run(["rev-parse", "--show-toplevel"], at: project)
        let repository: URL, bare: Bool
        if top.status == 0 {
            repository = try path(top.output).standardizedFileURL.resolvingSymlinksInPath(); bare = false
        } else {
            var found: URL?
            // Explicit Git directories respect safe.bareRepository=explicit in both bare layouts.
            for candidate in [".", ".git"] {
                let probe = try await run(["--git-dir=" + candidate, "rev-parse", "--is-bare-repository", "--absolute-git-dir"], at: project)
                guard probe.status == 0, probe.output.starts(with: Data("true\n".utf8)) else { continue }
                found = try path(Data(probe.output.dropFirst(5))).standardizedFileURL.resolvingSymlinksInPath(); break
            }
            guard let found else { return nil }; repository = found; bare = true
        }
        let result = try await run((bare ? ["--git-dir=."] : []) + ["remote", "-v"], at: repository)
        guard result.status == 0, let output = String(data: result.output, encoding: .utf8) else { return nil }
        var remotes: [String: RepositoryIdentity.Remote] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3, fields[2] == "(fetch)", fields[0].utf8.count <= 1_024,
                  !fields[0].unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  let remote = RepositoryIdentity.normalizedRemote(String(fields[1])) else { continue }
            remotes[String(fields[0])] = remote
        }
        let alphabetical = remotes.keys.sorted {
            let order = $0.localizedCompare($1)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        guard let name = ["upstream", "origin"].first(where: { remotes[$0] != nil }) ?? alphabetical.first,
              let remote = remotes[name] else { return nil }
        let relative: String?
        if project.path == repository.path { relative = "" }
        else if project.path.hasPrefix(repository.path + "/") { relative = String(project.path.dropFirst(repository.path.count + 1)) }
        else { relative = nil }
        return try .init(remote: remote, remoteName: name, rootPath: repository.path, projectRelativePath: relative, origin: remotes["origin"])
    }
    private func path(_ data: Data) throws -> URL {
        var bytes = data
        if bytes.last == 10 { bytes.removeLast() }
        guard let value = String(data: bytes, encoding: .utf8), value.hasPrefix("/"), !value.contains("\0") else {
            throw CoincideError("Git returned an unsupported repository path.")
        }
        return URL(fileURLWithPath: value)
    }
    private func run(_ arguments: [String], at folder: URL) async throws -> CommandResult {
        try Task.checkCancellation()
        guard let git = executable ?? ProcessChannel.findExecutable("git") else { throw CoincideError("Git is not installed or executable.") }
        var env = environment ?? ProcessChannel.environment()
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_IMPLICIT_WORK_TREE", "GIT_SUPER_PREFIX", "GIT_NAMESPACE", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CURL_VERBOSE"] + env.keys.filter({ $0.hasPrefix("GIT_CONFIG_KEY_") || $0.hasPrefix("GIT_CONFIG_VALUE_") || $0.hasPrefix("GIT_TRACE") }) { env.removeValue(forKey: key) }
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GCM_INTERACTIVE"] = "Never"; env["GIT_ASKPASS"] = "/usr/bin/false"; env["LC_ALL"] = "C"
        // Protocol denial is defensive: these fixed metadata commands do not contact any remote.
        env["GIT_ALLOW_PROTOCOL"] = ""; env["GIT_PROTOCOL_FROM_USER"] = "0"
        let prefix = ["--no-pager", "--no-optional-locks", "-c", "color.ui=false", "-C", folder.path]
        let process = try ProcessChannel(executable: git, arguments: prefix + arguments, cwd: folder, environment: env)
        process.finishInput()
        // An uncancelled reader drains to the real exit event. Cancelling the caller stops the
        // process and waits for that drain, rather than letting AsyncStream end the wait early.
        let reader = Task.detached {
            var output = Data(), errors = Data(), exceeded = false
            for await event in process.events {
                switch event {
                case .stdout(let bytes):
                    if !exceeded, output.count + errors.count + bytes.count <= 262_144 { output.append(bytes) }
                    else { exceeded = true; process.stop() }
                case .stderr(let bytes):
                    if !exceeded, output.count + errors.count + bytes.count <= 262_144 { errors.append(bytes) }
                    else { exceeded = true; process.stop() }
                case .exited(let status):
                    guard !exceeded else { throw CoincideError("Repository metadata exceeded the size limit.") }
                    // Stderr may contain credential-bearing config paths or URLs. Never expose it.
                    return CommandResult(output: output, error: Data(), status: status)
                }
            }
            throw CoincideError("Repository metadata ended without an exit status.")
        }
        return try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: CommandResult.self) { group in
                    group.addTask { try await reader.value }
                    group.addTask {
                        try await Task.sleep(for: timeout); process.stop()
                        throw CoincideError("Reading repository metadata timed out.")
                    }
                    defer { group.cancelAll() }
                    let result = try await group.next()!; try Task.checkCancellation(); return result
                }
            } catch { process.stop(); _ = try? await reader.value; try Task.checkCancellation(); throw error }
        } onCancel: { process.stop() }
    }
}
