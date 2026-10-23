import Darwin
import Foundation

/// A bounded capture of selected login-shell variables. Finder and Dock launches
/// inherit launchd's minimal environment, so CLIs installed through version
/// managers and variables set in shell startup files are otherwise invisible to
/// providers, terminals and Git. Only allowlisted names are retained; startup-file
/// output before and after the nonce sentinels is ignored. Each spawned process
/// reads the published snapshot when it launches, so running sessions keep theirs.
public enum LoginShellEnvironment {
    /// PATH and these names are read from the shell (T3 LOGIN_SHELL_ENV_NAMES, macOS subset).
    public static let capturedNames = ["PATH", "LANG", "LC_ALL", "LC_CTYPE", "SSH_AUTH_SOCK", "HOMEBREW_PREFIX", "HOMEBREW_CELLAR",
                                       "HOMEBREW_REPOSITORY", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "SSL_CERT_FILE", "SSL_CERT_DIR",
                                       "NODE_EXTRA_CA_CERTS", "__MISE_DIFF"]
    /// Present only when the inherited environment lacks them.
    static let fillNames = ["HOMEBREW_PREFIX", "HOMEBREW_CELLAR", "HOMEBREW_REPOSITORY", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
                            "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS"]
    static let localeNames = ["LANG", "LC_ALL", "LC_CTYPE"]
    /// GUI launches have no locale; agents would otherwise run in the C locale.
    static let fallbackCType = "en_US.UTF-8"
    public static let shellTimeout = Duration.seconds(5)
    public static let launchctlTimeout = Duration.seconds(2)
    public static let outputLimit = 1 << 20

    public struct Snapshot: Sendable, Equatable {
        public enum Source: Sendable, Equatable {
            case loginShell(String)
            case launchctl
            case none
        }
        public let source: Source
        public let values: [String: String]
        /// Why the login-shell probe did not provide PATH, when it did not.
        public let failure: String?
        public let capturedAt: Date
        public init(source: Source, values: [String: String], failure: String? = nil, capturedAt: Date = Date()) {
            self.source = source; self.values = values.filter { LoginShellEnvironment.capturedNames.contains($0.key) }
            self.failure = failure; self.capturedAt = capturedAt
        }
        public var pathEntryCount: Int { values["PATH"].map { $0.split(separator: ":").filter { !$0.isEmpty }.count } ?? 0 }

        /// Shell PATH entries first, then the inherited launchd PATH, then fixed fallbacks.
        public func applied(to inherited: [String: String], extraPaths: [String]) -> [String: String] {
            var env = inherited
            if let path = LoginShellEnvironment.mergePaths([values["PATH"], inherited["PATH"], extraPaths.joined(separator: ":")]) { env["PATH"] = path }
            if Self.isEmpty(env["SSH_AUTH_SOCK"]), let value = values["SSH_AUTH_SOCK"], !value.isEmpty { env["SSH_AUTH_SOCK"] = value }
            // mise records the PATH entries it added; it must travel with the shell's PATH.
            if let value = values["__MISE_DIFF"], !value.isEmpty { env["__MISE_DIFF"] = value }
            for name in LoginShellEnvironment.fillNames where Self.isEmpty(env[name]) {
                if let value = values[name], !value.isEmpty { env[name] = value }
            }
            // Locale variables form one precedence group: hydrate only when none is inherited.
            if LoginShellEnvironment.localeNames.allSatisfy({ Self.isEmpty(env[$0]) }) {
                for name in LoginShellEnvironment.localeNames { if let value = values[name], !value.isEmpty { env[name] = value } }
                if LoginShellEnvironment.localeNames.allSatisfy({ Self.isEmpty(env[$0]) }) { env["LC_CTYPE"] = LoginShellEnvironment.fallbackCType }
            }
            return env
        }
        private static func isEmpty(_ value: String?) -> Bool { value?.trimmingCharacters(in: .whitespaces).isEmpty ?? true }
    }

    // MARK: Published snapshot

    private static let lock = NSLock()
    nonisolated(unsafe) private static var published: Snapshot?
    public static var current: Snapshot? { lock.withLock { published } }
    /// Only later launches observe a new snapshot; existing children keep their environment.
    public static func publish(_ snapshot: Snapshot?) { lock.withLock { published = snapshot } }

    // MARK: Pure helpers

    /// `$SHELL`, the account's login shell, then `/bin/zsh`, without duplicates.
    public static func candidates(shellVariable: String?, userShell: String?) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for value in [shellVariable, userShell, "/bin/zsh"] {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.hasPrefix("/"),
                  !trimmed.contains("\0"), seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    public static func accountShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let value = String(cString: shell)
        return value.isEmpty ? nil : value
    }

    /// External printf/env keep the command valid in sh, zsh, bash, fish and nu.
    public static func captureCommand(start: String, end: String) -> String {
        "/usr/bin/printf '\\n%s\\n' '\(start)'; /usr/bin/env -0; /usr/bin/printf '\\n%s\\n' '\(end)'"
    }

    public static func sentinels(nonce: UUID = UUID()) -> (start: String, end: String) {
        let token = nonce.uuidString.replacingOccurrences(of: "-", with: "")
        return ("__COINCIDE_ENV_\(token)_START__", "__COINCIDE_ENV_\(token)_END__")
    }

    /// Reads only the NUL-separated block between the sentinels and keeps allowlisted names.
    /// Returns nil when either sentinel is missing.
    public static func parse(_ output: Data, start: String, end: String, names: Set<String> = Set(capturedNames)) -> [String: String]? {
        let startMarker = Data((start + "\n").utf8), endMarker = Data(("\n" + end).utf8)
        guard let startRange = output.range(of: startMarker),
              let endRange = output.range(of: endMarker, in: startRange.upperBound..<output.endIndex) else { return nil }
        var values: [String: String] = [:]
        for entry in output[startRange.upperBound..<endRange.lowerBound].split(separator: 0) {
            guard let separator = entry.firstIndex(of: UInt8(ascii: "=")), separator > entry.startIndex,
                  let name = String(data: entry[entry.startIndex..<separator], encoding: .utf8), names.contains(name),
                  let value = String(data: entry[entry.index(after: separator)...], encoding: .utf8) else { continue }
            values[name] = value
        }
        return values
    }

    /// Order-preserving, de-duplicated colon list without empty entries.
    public static func mergePaths(_ values: [String?]) -> String? {
        var seen = Set<String>(), entries: [String] = []
        for value in values {
            for entry in (value ?? "").split(separator: ":") {
                let trimmed = entry.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.contains("\0"), seen.insert(trimmed).inserted else { continue }
                entries.append(trimmed)
            }
        }
        return entries.isEmpty ? nil : entries.joined(separator: ":")
    }

    // MARK: Capture

    public struct Configuration: Sendable {
        public var candidates: [String]
        public var inherited: [String: String]
        public var shellTimeout: Duration
        public var launchctlTimeout: Duration
        public var outputLimit: Int
        public var launchctl: String
        public init(candidates: [String], inherited: [String: String], shellTimeout: Duration = LoginShellEnvironment.shellTimeout,
                    launchctlTimeout: Duration = LoginShellEnvironment.launchctlTimeout, outputLimit: Int = LoginShellEnvironment.outputLimit,
                    launchctl: String = "/bin/launchctl") {
            self.candidates = candidates; self.inherited = inherited; self.shellTimeout = shellTimeout
            self.launchctlTimeout = launchctlTimeout; self.outputLimit = outputLimit; self.launchctl = launchctl
        }
        public static func system() -> Self {
            let inherited = ProcessInfo.processInfo.environment
            return .init(candidates: LoginShellEnvironment.candidates(shellVariable: inherited["SHELL"], userShell: LoginShellEnvironment.accountShell()),
                         inherited: inherited)
        }
    }

    /// Never throws and never exceeds its timeouts. A timed-out shell is not followed
    /// by further shells: they would most likely hang on the same startup files.
    public static func capture(_ configuration: Configuration = .system()) async -> Snapshot {
        var failures: [String] = []
        var merged: [String: String] = [:]
        for shell in configuration.candidates {
            guard FileManager.default.isExecutableFile(atPath: shell) else { failures.append("\(shell) is not executable."); continue }
            let markers = sentinels()
            let result = await BoundedProcess.run(executable: shell, arguments: ["-ilc", captureCommand(start: markers.start, end: markers.end)],
                                                  environment: configuration.inherited, timeout: configuration.shellTimeout,
                                                  outputLimit: configuration.outputLimit)
            let name = URL(fileURLWithPath: shell).lastPathComponent
            if let values = parse(result.output, start: markers.start, end: markers.end) {
                merged.merge(values) { current, _ in current }
                if let path = values["PATH"], !path.isEmpty {
                    return .init(source: .loginShell(shell), values: merged)
                }
                failures.append("\(name) did not report PATH.")
            } else if result.timedOut { failures.append("\(name) did not finish within \(seconds(configuration.shellTimeout)) seconds."); break }
            else if result.overflowed { failures.append("\(name) printed more than \(configuration.outputLimit / 1024) KB.") }
            else if let error = result.launchError { failures.append("\(name) could not start (system error \(error)).") }
            else { failures.append("\(name) exited with status \(result.status ?? -1) before reporting its environment.") }
        }
        let failure = failures.isEmpty ? "No login shell is available." : failures.joined(separator: " ")
        let launchctl = await BoundedProcess.run(executable: configuration.launchctl, arguments: ["getenv", "PATH"], environment: configuration.inherited,
                                                 timeout: configuration.launchctlTimeout, outputLimit: 64 * 1024)
        if launchctl.status == 0, !launchctl.timedOut, !launchctl.overflowed,
           let path = String(data: launchctl.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            merged["PATH"] = path
            return .init(source: .launchctl, values: merged, failure: failure)
        }
        merged.removeValue(forKey: "PATH")
        return .init(source: .none, values: merged, failure: failure)
    }

    private static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// A short-lived child in its own session and process group with stdin from /dev/null,
/// stdout captured up to a byte limit and stderr discarded. On timeout or overflow the
/// whole group is killed while its unreaped leader still reserves the group ID.
public enum BoundedProcess {
    public struct Result: Sendable, Equatable {
        public var output = Data()
        public var status: Int32?
        public var timedOut = false
        public var overflowed = false
        public var launchError: Int32?
    }

    /// `mergeStandardError` captures stderr with stdout; otherwise stderr is discarded.
    public static func run(executable: String, arguments: [String], environment: [String: String], directory: String? = nil,
                           timeout: Duration, outputLimit: Int, mergeStandardError: Bool = false) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSynchronously(executable: executable, arguments: arguments, environment: environment,
                                                                directory: directory, timeout: timeout, outputLimit: outputLimit,
                                                                mergeStandardError: mergeStandardError))
            }
        }
    }

    static func runSynchronously(executable: String, arguments: [String], environment: [String: String], directory: String?,
                                 timeout: Duration, outputLimit: Int, mergeStandardError: Bool = false) -> Result {
        var result = Result()
        var pipeFDs = [Int32](repeating: -1, count: 2)
        guard pipe(&pipeFDs) == 0 else { result.launchError = errno; return result }
        // GUI launches may have closed standard descriptors; keep ours above stderr.
        for index in pipeFDs.indices {
            let elevated = fcntl(pipeFDs[index], F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard elevated >= 0 else { for fd in pipeFDs { close(fd) }; result.launchError = errno; return result }
            close(pipeFDs[index]); pipeFDs[index] = elevated
        }
        let readFD = pipeFDs[0], writeFD = pipeFDs[1]
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { close(readFD); close(writeFD); result.launchError = EINVAL; return result }
        guard posix_spawnattr_init(&attributes) == 0 else {
            posix_spawn_file_actions_destroy(&actions); close(readFD); close(writeFD); result.launchError = EINVAL; return result
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        var setup = [posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                     posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO),
                     mergeStandardError ? posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO)
                        : posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
                     posix_spawn_file_actions_addclose(&actions, readFD), posix_spawn_file_actions_addclose(&actions, writeFD)]
        if let directory { setup.append(posix_spawn_file_actions_addchdir_np(&actions, directory)) }
        var mask = sigset_t(); sigemptyset(&mask); setup.append(posix_spawnattr_setsigmask(&attributes, &mask))
        var defaults = sigset_t(); sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGTTIN, SIGTTOU] { sigaddset(&defaults, signal) }
        setup.append(posix_spawnattr_setsigdefault(&attributes, &defaults))
        // A new session has no controlling terminal, so an interactive shell cannot stop on job control.
        setup.append(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        guard setup.allSatisfy({ $0 == 0 }) else { close(readFD); close(writeFD); result.launchError = EINVAL; return result }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        var pid: pid_t = 0
        let spawnError = argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { env in
            posix_spawn(&pid, executable, &actions, &attributes, UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
        } }
        close(writeFD)
        guard spawnError == 0 else { close(readFD); result.launchError = spawnError; return result }
        defer { close(readFD) }
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        let deadline = ContinuousClock.now + timeout
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var finished = false, leaderExited = false
        func leaderHasExited() -> Bool {
            var info = siginfo_t()
            // WNOWAIT keeps the zombie leader, and with it the group ID, reserved until we reap it.
            while true {
                let value = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if value == -1 && errno == EINTR { continue }
                return value == 0 && info.si_pid == pid
            }
        }
        func drainAvailable() -> Bool { // false at EOF or overflow
            while true {
                let count = Darwin.read(readFD, &buffer, buffer.count)
                if count > 0 {
                    result.output.append(contentsOf: buffer.prefix(count))
                    if result.output.count > outputLimit { result.overflowed = true; result.output = Data(); return false }
                    continue
                }
                if count == -1 && errno == EINTR { continue }
                if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) { return true }
                return false
            }
        }
        while !finished {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { result.timedOut = true; break }
            let milliseconds = Int32(min(50, max(1, remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000)))
            var descriptor = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, milliseconds)
            // An unexpected poll failure is handled like a timeout: the group is killed, never waited on.
            if ready == -1 && errno != EINTR { result.timedOut = true; break }
            if ready > 0, !drainAvailable() {
                if result.overflowed { break }
                finished = true // EOF: every writer closed stdout.
            }
            // Everything the shell wrote precedes its exit. A background job that kept the pipe
            // open is not waited for once the leader has exited and its bytes are drained.
            if !finished, leaderHasExited() { _ = drainAvailable(); if result.overflowed { break }; finished = true; leaderExited = true }
        }
        if finished, !leaderExited {
            while !leaderHasExited() {
                guard ContinuousClock.now < deadline else { result.timedOut = true; break }
                usleep(5_000)
            }
        }
        if result.timedOut || result.overflowed {
            _ = kill(-pid, SIGKILL)
            result.output = result.overflowed ? Data() : result.output
        }
        var raw: Int32 = 0, reaped: pid_t
        repeat { reaped = waitpid(pid, &raw, 0) } while reaped == -1 && errno == EINTR
        if reaped == pid, !result.timedOut, !result.overflowed {
            result.status = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
        }
        return result
    }
}
