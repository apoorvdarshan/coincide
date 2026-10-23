import Darwin
import Foundation

struct GitHubPullRequestCommand: Sendable {
    let environment: [String: String]?
    let executable: URL?
    let timeout: Duration
    /// A token saved in Settings; nil for injected test environments.
    var credentials: GitHubCredentialOverrides? = nil

    func run(_ arguments: [String], directory: GitWorktreeDirectory, host: String, input: Data? = nil,
             maximumOutput: Int = 2_097_152) async throws -> GitWorktreeCommandResult {
        try Task.checkCancellation(); try directory.validate()
        guard let gh = executable else { throw GitHubPullRequestError(.missingCLI) }
        let inputFD = try input.map(Self.inputFile)
        defer { if let inputFD { Darwin.close(inputFD) } }
        var childEnvironment = Self.sanitizedEnvironment(environment ?? ProcessChannel.environment(), host: host)
        credentials?.apply(to: &childEnvironment, host: host)
        let launchEnvironment = childEnvironment
        let process: GitWorktreeProcess
        do {
            process = try ProcessChannel.withChildLaunch {
                try .init(executable: gh, arguments: arguments, cwdFD: directory.fd,
                    environment: launchEnvironment,
                    maxBytes: maximumOutput, trustedInputFD: inputFD)
            }
        } catch { throw GitHubPullRequestError(.commandFailed) }
        let reader = Task.detached { await process.result() }
        return try await withTaskCancellationHandler {
            do {
                let result = try await withThrowingTaskGroup(of: GitWorktreeCommandResult.self) { group in
                    group.addTask { await reader.value }
                    group.addTask { try await Task.sleep(for: timeout); process.stop(); throw GitHubPullRequestError(.timedOut) }
                    defer { group.cancelAll() }; return try await group.next()!
                }
                try Task.checkCancellation(); try directory.validate()
                guard !result.overflow else { throw GitHubPullRequestError(.outputLimit) }
                return result
            } catch {
                process.stop(); _ = await reader.value
                try Task.checkCancellation(); throw error
            }
        } onCancel: { process.stop() }
    }

    static func sanitizedEnvironment(_ original: [String: String], host: String) -> [String: String] {
        var env = original
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_IMPLICIT_WORK_TREE", "GIT_SUPER_PREFIX", "GIT_NAMESPACE", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CURL_VERBOSE", "GH_REPO", "GH_PATH", "GH_DEBUG", "DEBUG", "GH_FORCE_TTY", "CLICOLOR_FORCE"] + env.keys.filter({ $0.hasPrefix("GIT_CONFIG_KEY_") || $0.hasPrefix("GIT_CONFIG_VALUE_") || $0.hasPrefix("GIT_TRACE") }) { env.removeValue(forKey: key) }
        // Enterprise environment tokens belong only to the explicitly named host.
        // gh itself restricts GH_TOKEN/GITHUB_TOKEN to github.com and *.ghe.com.
        if original["GH_HOST"]?.lowercased() != host.lowercased() {
            env.removeValue(forKey: "GH_ENTERPRISE_TOKEN"); env.removeValue(forKey: "GITHUB_ENTERPRISE_TOKEN")
        }
        env["GH_HOST"] = host; env["GH_PROMPT_DISABLED"] = "1"; env["GH_PAGER"] = "/bin/cat"
        env["GH_EDITOR"] = "/usr/bin/false"; env["GIT_EDITOR"] = "/usr/bin/false"; env["GH_BROWSER"] = "/usr/bin/false"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"; env["GH_NO_EXTENSION_UPDATE_NOTIFIER"] = "1"; env["GH_SPINNER_DISABLED"] = "1"
        env["GH_TELEMETRY"] = "false"; env["NO_COLOR"] = "1"; env["CLICOLOR"] = "0"; env["LC_ALL"] = "C"
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GCM_INTERACTIVE"] = "Never"; env["GIT_ASKPASS"] = "/usr/bin/false"
        env["SSH_ASKPASS"] = "/usr/bin/false"; env["SSH_ASKPASS_REQUIRE"] = "never"
        env["GIT_ALLOW_PROTOCOL"] = ""; env["GIT_PROTOCOL_FROM_USER"] = "0"
        return env
    }

    private static func inputFile(_ input: Data) throws -> Int32 {
        guard input.count <= 1_048_576 else { throw GitHubPullRequestError(.invalidRequest) }
        var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pr-body-XXXXXX").path.utf8CString)
        let fd = try ProcessChannel.withChildLaunch {
            let created = mkstemp(&template)
            guard created >= 0 else { throw GitHubPullRequestError(.commandFailed) }
            _ = template.withUnsafeBufferPointer { unlink($0.baseAddress!) }
            guard fcntl(created, F_SETFD, FD_CLOEXEC) == 0, fchmod(created, 0o600) == 0 else {
                Darwin.close(created); throw GitHubPullRequestError(.commandFailed)
            }
            return created
        }
        var success = false
        defer { if !success { Darwin.close(fd) } }
        try input.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw GitHubPullRequestError(.commandFailed) }; offset += count
            }
        }
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw GitHubPullRequestError(.commandFailed) }
        success = true; return fd
    }
}
