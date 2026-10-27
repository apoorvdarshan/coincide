import Foundation

/// One short-lived Antigravity process outside a thread: for checking a downloaded release, Google
/// sign-in and sign-out. It gets its own temporary folder (the agent unpacks about a gigabyte into it),
/// collects the lines it prints outside JSON-RPC, and cleans up after the process has ended.
@MainActor
final class AntigravityAgentProcess {
    let client: ACPClient
    /// Lines printed outside JSON-RPC on stdout, and every stderr line.
    var onOutputLine: ((String) -> Void)?
    private(set) var stderrTail = ""
    private(set) var hasExited = false

    private let transport: ACPTransport
    private let temporaryDirectory: URL?
    private var lease: ACPLaunchLease?
    private var stderrLine = ""
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false
    private var cleanedUp = false

    init(
        executable: URL, workingDirectory: URL, environment: [String: String], transport factory: ACPTransportFactory? = nil,
        lease: ACPLaunchLease? = nil
    ) {
        var environment = environment
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("Coincide-antigravity", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        if (try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)) != nil {
            environment["TMPDIR"] = temporary.path + "/"
            temporaryDirectory = temporary
        } else {
            temporaryDirectory = nil
        }
        let make =
            factory ?? { executable, arguments, directory, environment in
                ACPProcessTransport(executable: executable, arguments: arguments, workingDirectory: directory, environment: environment)
            }
        transport = make(executable, [], workingDirectory, environment)
        let connection = ACPConnection(write: { [weak transport] line in transport?.write(line) })
        client = ACPClient(connection: connection)
        self.lease = lease
        // Nothing here works in a session; refuse whatever the agent asks.
        client.onPermissionRequest = { [weak client] _, incoming in client?.respondToPermission(incoming, optionID: nil) }
        client.onElicitation = { [weak client] _, incoming in client?.respondToElicitation(incoming, action: "cancel") }
        connection.onUnparsedLine = { [weak self] line in self?.outputLine(line) }
        transport.onLine = { [weak connection] line in connection?.receive(line) }
        transport.onStderr = { [weak self] text in self?.recordStderr(text) }
        transport.onExit = { [weak self] status, tail in self?.exited(status: status, tail: tail) }
    }

    func start() throws {
        do {
            try transport.start()
        } catch {
            stop()
            throw AntigravitySignInError(String(localized: "Couldn’t start Antigravity: \(error.localizedDescription)"))
        }
    }

    /// Stops the process (and everything it started). Pending requests fail at once.
    func stop() {
        guard !stopped else { return }
        stopped = true
        client.connection.close(with: AgentError.notRunning)
        transport.terminate()
        // A process that never reports its exit still gets its files cleaned up.
        Task {
            try? await Task.sleep(for: .seconds(10))
            self.cleanUp()
        }
        if hasExited { cleanUp() }
    }

    /// Waits until the process has exited, at most `timeout` seconds.
    func waitForExit(timeout: TimeInterval) async {
        guard !hasExited else { return }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.resumeWaiters()
        }
        await withCheckedContinuation { exitWaiters.append($0) }
        timer.cancel()
    }

    private func exited(status: Int32, tail: String) {
        hasExited = true
        if !tail.isEmpty { stderrTail = String((stderrTail + tail).suffix(4_096)) }
        client.connection.close(
            with: AgentError.providerError(String(localized: "Antigravity exited unexpectedly (status \(status)).")))
        if stopped { cleanUp() }
        resumeWaiters()
    }

    private func resumeWaiters() {
        let waiters = exitWaiters
        exitWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func cleanUp() {
        guard !cleanedUp else { return }
        cleanedUp = true
        lease?.release()
        lease = nil
        if let temporaryDirectory {
            DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: temporaryDirectory) }
        }
    }

    private func recordStderr(_ text: String) {
        stderrTail = String((stderrTail + text).suffix(4_096))
        let lines = (stderrLine + text).split(separator: "\n", omittingEmptySubsequences: false)
        stderrLine = String((lines.last ?? "").suffix(AntigravityAuthorization.maxLength + 256))
        lines.dropLast().forEach { outputLine(String($0)) }
    }

    private func outputLine(_ line: String) {
        onOutputLine?(line.hasSuffix("\r") ? String(line.dropLast()) : line)
    }
}

/// Starts a freshly unpacked release once, with a throwaway profile, and checks that it is the
/// Google Antigravity release Coincide pinned and supports what Coincide needs (T3 Code's validation).
@MainActor
enum AntigravityValidation {
    static func check(_ release: AntigravityExecutable, version: String) async throws {
        let failed = AntigravityInstallError(
            "verify", String(localized: "The downloaded Antigravity runtime couldn’t start on this Mac."))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("coincide-antigravity-validate-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw failed
        }
        let profile = AntigravityProfile(geminiHome: directory.appendingPathComponent("profile", isDirectory: true))
        let base = await ShellEnvironment.shared.environment()
        do {
            try await profile.prepare(environment: base)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw failed
        }
        let process = AntigravityAgentProcess(
            executable: release.executable, workingDirectory: directory, environment: profile.environment(base, harness: release.harness))
        defer {
            process.stop()
            Task {
                await process.waitForExit(timeout: 5)
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let initialized: ACPInitializeResult
        do {
            try process.start()
            initialized = try await withTaskCancellationHandler {
                try await process.client.initialize(
                    capabilities: ACPClientCapabilities(), clientInfo: ACPSession.clientInfo, timeout: 90)
            } onCancel: {
                Task { @MainActor in process.stop() }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if process.stderrTail.range(of: #"\b(AF_INET6|enforce_kernel_ipv6_support)\b"#, options: .regularExpression) != nil {
                throw AntigravityInstallError(
                    "verify", String(localized: "Antigravity needs IPv6 networking. Turn IPv6 on for this Mac’s network, then try again."))
            }
            throw failed
        }
        guard Self.isExpected(initialized, version: version) else {
            throw AntigravityInstallError(
                "verify", String(localized: "The downloaded runtime didn’t identify as the expected Google Antigravity release."))
        }
    }

    /// What T3 Code requires of the release it installs.
    nonisolated static func isExpected(_ initialized: ACPInitializeResult, version: String) -> Bool {
        initialized.agentInfo?.name == "antigravity-acp" && initialized.agentInfo?.version == version
            // Antigravity may report protocol 2 with the v1 shape.
            && (initialized.protocolVersion == 1 || initialized.protocolVersion == 2)
            && initialized.loadSession && initialized.resumeSession && initialized.canLogout
            && initialized.authMethods.contains { $0.id == AntigravityFlavor.authMethodID }
    }
}
