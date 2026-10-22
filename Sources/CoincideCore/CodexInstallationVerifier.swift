import Darwin
import Foundation

/// No initialize, login, model discovery or turn is sent by installation checks.
public enum CodexInstallationVerifier {
    public static func verify(release: CodexManagedRelease, executable: CodexInstallationExecutable, scratch: URL) async throws {
        let version = try await version(executable.executable, scratch: scratch, timeout: .seconds(90))
        guard version == release.version else { throw CodexInstallationError(.verificationFailed) }
    }
    public static func inspect(executable: CodexInstallationExecutable, scratch: URL) async throws -> String {
        try requireCodeModeHostOrLauncher(executable.executable)
        let version = try await version(executable.executable, scratch: scratch, timeout: .seconds(5))
        _ = try await command(executable.executable, arguments: ["app-server", "--help"], scratch: scratch, timeout: .seconds(5))
        return version
    }
    private static func requireCodeModeHostOrLauncher(_ invoked: URL) throws {
        let resolved = invoked.standardizedFileURL.resolvingSymlinksInPath()
        if ["volta-shim", "mise", "aqua-proxy"].contains(resolved.lastPathComponent) { return }
        let fd = Darwin.open(resolved.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CodexInstallationError(.verificationFailed) }; defer { Darwin.close(fd) }
        var info = stat(), header = [UInt8](repeating: 0, count: 2)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CodexInstallationError(.verificationFailed) }
        if Darwin.read(fd, &header, 2) == 2, header == [35, 33] { return }
        let host = resolved.deletingLastPathComponent().appendingPathComponent("codex-code-mode-host")
        guard lstat(host.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_mode & 0o111 != 0 else { throw CodexInstallationError(.verificationFailed) }
    }
    private static func version(_ executable: URL, scratch: URL, timeout: Duration) async throws -> String {
        let data = try await command(executable, arguments: ["--version"], scratch: scratch, timeout: timeout)
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.range(of: #"^codex-cli [0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.-]+)?$"#, options: .regularExpression) != nil else { throw CodexInstallationError(.verificationFailed) }
        return String(text.dropFirst("codex-cli ".count))
    }
    private static func command(_ executable: URL, arguments: [String], scratch: URL, timeout: Duration) async throws -> Data {
        try Task.checkCancellation()
        let home = scratch.appendingPathComponent("home-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        var environment = ProcessChannel.environment()
        for key in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "ACCESS_TOKEN", "CHATGPT_ACCESS_TOKEN", "CODEX_THREAD_ID"] { environment.removeValue(forKey: key) }
        environment["CODEX_HOME"] = home.path
        let channel: ProcessChannel
        do { channel = try .init(executable: executable, arguments: arguments, cwd: scratch, environment: environment, eventBufferLimit: 32) }
        catch { throw CodexInstallationError(.verificationFailed) }
        do {
            let result = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask {
                        var output = Data(), count = 0
                        for await event in channel.events {
                            try Task.checkCancellation()
                            guard !channel.outputOverflowed else { throw CodexInstallationError(.verificationFailed) }
                            switch event {
                            case .stdout(let bytes): count += bytes.count; output.append(bytes)
                            case .stderr(let bytes): count += bytes.count
                            case .exited(let status): guard status == 0 else { throw CodexInstallationError(.verificationFailed) }; return output
                            }
                            guard count <= 131_072 else { throw CodexInstallationError(.verificationFailed) }
                        }
                        throw CodexInstallationError(.verificationFailed)
                    }
                    group.addTask { try await Task.sleep(for: timeout); throw CodexInstallationError(.verificationFailed) }
                    defer { group.cancelAll() }
                    channel.finishInput()
                    guard let result = try await group.next() else { throw CodexInstallationError(.verificationFailed) }; return result
                }
            } onCancel: { channel.stop() }
            _ = await channel.stopAndDrain(); try Task.checkCancellation(); return result
        } catch {
            _ = await channel.stopAndDrain()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw CodexInstallationError(.verificationFailed)
        }
    }
}
