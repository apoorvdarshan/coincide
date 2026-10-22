import CryptoKit
import Darwin
import Foundation

/// Runtime-only secret. Native profile settings and workspace records never contain it.
public final class AntigravityRuntimeCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String
    public init(apiKey: String) throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              apiKey.utf8.count <= 65_536, !apiKey.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw AntigravityWireError(.invalidConfiguration) }
        value = apiKey
    }
    public var description: String { "AntigravityRuntimeCredential(<redacted>)" }
    public var debugDescription: String { description }
}

public struct AntigravityExecutablePair: Sendable {
    public let executable: URL
    public let harness: URL
}

enum AntigravityProcessEvent: Sendable { case stdout(Data), stderr(Data), exited(Int32) }

/// Cancellation can retire a queued frame, but cannot truncate one already
/// claimed by the native writer. Every later frame remains behind that claim.
final class AntigravityWriteTicket: @unchecked Sendable {
    private enum State { case queued, writing, cancelled, finished }
    private let lock = NSLock()
    private var state = State.queued
    func cancel() { lock.withLock { if case .queued = state { state = .cancelled } } }
    func begin() -> Bool {
        lock.withLock { guard case .queued = state else { return false }; state = .writing; return true }
    }
    func finish() { lock.withLock { state = .finished } }
}

/// A captured native server/harness pair, isolated profile, and fresh POSIX session.
/// Teardown signals only this owned process group; detached escapees are not claimed.
public final class AntigravityRuntime: @unchecked Sendable {
    public let profileDirectory: URL
    public let temporaryDirectory: URL
    /// Base containing antigravity-acp/conversations and antigravity-acp/brain;
    /// shared only by this captured instance, independently of auth generation.
    public let sessionStateDirectory: URL
    public let executablePair: AntigravityExecutablePair
    public var processIdentifier: Int32 { process.pid }
    public static var defaultStateRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Coincide/Providers/Antigravity", isDirectory: true)
    }
    let events: AsyncStream<AntigravityProcessEvent>
    let browserMarker: String
    var outputOverflowed: Bool { process.overflowed }
    var pendingWriteCount: Int { process.pendingWriteCount }
    private let process: AntigravityOwnedProcess
    private let lock = NSLock()
    private var closeTask: Task<Void, Never>?

    /// Deterministic location only. Deleting a staged profile additionally needs
    /// the authentication coordinator's exclusive generation lease and drain.
    public static func profileDirectory(configuration: AntigravityConfiguration, stateRoot: URL) throws -> URL {
        do { try configuration.validate() } catch { throw AntigravityWireError(.invalidConfiguration) }
        guard stateRoot.isFileURL else { throw AntigravityWireError(.invalidConfiguration) }
        let key = SHA256.hash(data: Data(configuration.instanceID.uuidString.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        return stateRoot.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true).appendingPathComponent(configuration.authGeneration.uuidString.lowercased(), isDirectory: true)
    }
    public static func sessionStateDirectory(configuration: AntigravityConfiguration, stateRoot: URL) throws -> URL {
        let profile = try profileDirectory(configuration: configuration, stateRoot: stateRoot)
        let instanceKey = profile.deletingLastPathComponent().lastPathComponent
        return stateRoot.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("instances", isDirectory: true)
            .appendingPathComponent(instanceKey, isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
    }

    public static func resolvePair(configuration: AntigravityConfiguration) throws -> AntigravityExecutablePair {
        do { try configuration.validate() } catch { throw AntigravityWireError(.invalidConfiguration) }
        guard let selected = ProcessChannel.findExecutable(configuration.executable) else { throw AntigravityWireError(.unavailable) }
        let executable = selected.standardizedFileURL.resolvingSymlinksInPath()
        let harnessSelection: URL
        if let configured = configuration.harnessPath {
            harnessSelection = configured.hasPrefix("/") ? URL(fileURLWithPath: configured) : selected.deletingLastPathComponent().appendingPathComponent(configured)
        } else { harnessSelection = selected.deletingLastPathComponent().appendingPathComponent("localharness_external") }
        let harness = harnessSelection.standardizedFileURL.resolvingSymlinksInPath()
        for path in [executable, harness] {
            guard path.isFileURL, path.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path.path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { throw AntigravityWireError(.unavailable) }
        }
        guard executable != harness else { throw AntigravityWireError(.invalidConfiguration) }
        return .init(executable: executable, harness: harness)
    }

    public init(executable: URL, configuration: AntigravityConfiguration, cwd: URL, stateRoot: URL,
                credential: AntigravityRuntimeCredential? = nil, environment: [String: String]? = nil,
                shutdownGrace: Duration = .seconds(2)) throws {
        guard shutdownGrace > .zero, shutdownGrace <= .seconds(10), cwd.isFileURL, stateRoot.isFileURL else { throw AntigravityWireError(.invalidConfiguration) }
        let pair = try Self.resolvePair(configuration: configuration)
        guard pair.executable == executable.standardizedFileURL.resolvingSymlinksInPath() else { throw AntigravityWireError(.invalidConfiguration) }
        let manager = FileManager.default
        let stateRoot = stateRoot.standardizedFileURL.resolvingSymlinksInPath()
        profileDirectory = try Self.profileDirectory(configuration: configuration, stateRoot: stateRoot)
        sessionStateDirectory = try Self.sessionStateDirectory(configuration: configuration, stateRoot: stateRoot)
        temporaryDirectory = stateRoot.appendingPathComponent("tmp", isDirectory: true).appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        executablePair = pair
        browserMarker = "__COINCIDE_ANTIGRAVITY_AUTH_URL_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "__"
        var ownsTemporary = false
        do {
            try manager.createDirectory(at: stateRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Self.ownedDirectory(stateRoot)
            let key = profileDirectory.deletingLastPathComponent().lastPathComponent
            for components in [["profiles", key, profileDirectory.lastPathComponent, "antigravity-acp"],
                               ["instances", key, "sessions", "antigravity-acp"], ["tmp", temporaryDirectory.lastPathComponent]] {
                var directory = stateRoot
                for component in components { directory.appendPathComponent(component, isDirectory: true); try Self.ownedDirectory(directory) }
            }
            ownsTemporary = true
            for name in ["conversations", "brain"] {
                let target = sessionStateDirectory.appendingPathComponent("antigravity-acp/" + name, isDirectory: true)
                try Self.ownedDirectory(target)
                let link = profileDirectory.appendingPathComponent("antigravity-acp/" + name)
                if symlink(target.path, link.path) != 0, errno != EEXIST { throw AntigravityWireError(.invalidConfiguration) }
                var info = stat()
                guard lstat(link.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK, info.st_uid == geteuid() else { throw AntigravityWireError(.invalidConfiguration) }
                var bytes = [UInt8](repeating: 0, count: 16_385)
                let count = readlink(link.path, &bytes, bytes.count)
                guard count >= 0, count < bytes.count, String(bytes: bytes.prefix(count), encoding: .utf8) == target.path else { throw AntigravityWireError(.invalidConfiguration) }
            }
            var settings: [String: JSONValue] = ["auth": .object(["type": .string(configuration.authMethod.rawValue)])]
            if configuration.authMethod == .oauthBusiness || configuration.authMethod == .agentPlatform {
                var gcp: [String: JSONValue] = [:]
                if let project = configuration.gcpProject, !project.isEmpty { gcp["project"] = .string(project) }
                if let location = configuration.gcpLocation, !location.isEmpty { gcp["location"] = .string(location) }
                if !gcp.isEmpty { settings["gcp"] = .object(gcp) }
            }
            let settingsURL = profileDirectory.appendingPathComponent("antigravity-acp/settings.json")
            try JSONEncoder().encode(JSONValue.object(settings)).write(to: settingsURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
            let helper = temporaryDirectory.appendingPathComponent("browser-capture")
            guard !helper.path.contains(":"), !helper.path.contains("%s"), !helper.path.contains("\n"), !helper.path.contains("\r") else { throw AntigravityWireError(.invalidConfiguration) }
            // No Node/Python dependency and no OS browser fallback. Ignoring PIPE
            // makes even a cancelled/closed capture pipe return success to webbrowser.
            let script = """
            #!/bin/sh
            trap '' PIPE
            case "$1" in
              *'"'*|*'\\'*|*'
            '*|*'\r'*) exit 0 ;;
            esac
            printf '\(browserMarker)"%s"\\n' "$1" 1>&2 2>/dev/null
            exit 0
            """
            try Data(script.utf8).write(to: helper, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            let removed: Set<String> = ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_LOCATION", "GOOGLE_CLOUD_QUOTA_PROJECT", "GOOGLE_GENAI_USE_VERTEXAI", "GCLOUD_PROJECT", "CLOUDSDK_CORE_PROJECT", "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE", "AGY_ACP_CCPA_PROJECT", "AGY_ACP_ENABLE_OAUTH", "GEMINI_HOME", "AGY_ACP_FORCE_FILE_STORAGE", "ANTIGRAVITY_HARNESS_PATH", "BROWSER", "PYTHONUNBUFFERED", "ELECTRON_RUN_AS_NODE", "TMPDIR", "TEMP", "TMP"]
            var childEnvironment = (environment ?? ProcessChannel.environment()).filter { !removed.contains($0.key.uppercased()) }
            switch configuration.authMethod {
            case .geminiAPIKey:
                guard let credential else { throw AntigravityWireError(.signInRequired) }
                childEnvironment["GEMINI_API_KEY"] = credential.value
            case .agentPlatform:
                if let credential { childEnvironment["GOOGLE_API_KEY"] = credential.value }
                else { guard configuration.gcpProject?.isEmpty == false, configuration.gcpLocation?.isEmpty == false else { throw AntigravityWireError(.signInRequired) } }
            case .oauthPersonal: break
            case .oauthBusiness:
                guard configuration.gcpProject?.isEmpty == false, configuration.gcpLocation?.isEmpty == false else { throw AntigravityWireError(.invalidConfiguration) }
            }
            childEnvironment["GEMINI_HOME"] = profileDirectory.path
            childEnvironment["AGY_ACP_FORCE_FILE_STORAGE"] = "1"
            childEnvironment["ANTIGRAVITY_HARNESS_PATH"] = pair.harness.path
            childEnvironment["BROWSER"] = "'" + helper.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "' %s"
            childEnvironment["PYTHONUNBUFFERED"] = "1"
            childEnvironment["TMPDIR"] = temporaryDirectory.path
            guard childEnvironment.allSatisfy({ !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else { throw AntigravityWireError(.invalidConfiguration) }
            process = try AntigravityOwnedProcess(executable: pair.executable, cwd: cwd, environment: childEnvironment, grace: shutdownGrace)
            events = process.events
        } catch {
            if ownsTemporary { try? manager.removeItem(at: temporaryDirectory) }
            throw error as? AntigravityWireError ?? AntigravityWireError(.unavailable)
        }
    }
    func write(_ data: Data, ticket: AntigravityWriteTicket = AntigravityWriteTicket()) async throws { try await process.write(data, ticket: ticket) }
    private static func ownedDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST { throw AntigravityWireError(.invalidConfiguration) }
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AntigravityWireError(.invalidConfiguration) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFDIR,
              fchmod(fd, 0o700) == 0 else { throw AntigravityWireError(.invalidConfiguration) }
    }
    func stop() { process.stop() }
    public func close() async {
        let task = lock.withLock { () -> Task<Void, Never> in
            if let closeTask { return closeTask }
            let process = process, temporary = temporaryDirectory
            let task = Task { process.stop(); await process.wait(); try? FileManager.default.removeItem(at: temporary) }
            closeTask = task; return task
        }
        await task.value
    }
    deinit { process.stop() }
}

private final class AntigravityOwnedProcess: @unchecked Sendable {
    let events: AsyncStream<AntigravityProcessEvent>
    let pid: pid_t
    private let inputFD: Int32
    private let lock = NSLock()
    private let readers = AntigravityReadState()
    private let writer = DispatchQueue(label: "Coincide.antigravity-input", qos: .userInitiated)
    private let writerDrain = DispatchGroup()
    private let grace: Duration
    private var inputClosed = false
    private var stopping = false
    private var signalAllowed = true
    private var finished = false
    private var didOverflow = false
    private var writes = 0
    private var waits: [CheckedContinuation<Void, Never>] = []
    var overflowed: Bool { lock.withLock { didOverflow } }
    var pendingWriteCount: Int { lock.withLock { writes } }

    init(executable: URL, cwd: URL, environment: [String: String], grace: Duration) throws {
        self.grace = grace
        let (stream, continuation) = AsyncStream<AntigravityProcessEvent>.makeStream(bufferingPolicy: .bufferingOldest(64)); events = stream
        let launch = try ProcessChannel.withChildLaunch { () throws -> (pid_t, Int32, Int32, Int32) in
            var descriptors: [Int32] = []
            do {
                for _ in 0..<3 {
                    var pair: [Int32] = [-1, -1]
                    guard pipe(&pair) == 0 else { throw AntigravityWireError(.unavailable) }
                    let start = descriptors.count
                    descriptors.append(contentsOf: pair)
                    for index in start..<descriptors.count {
                        let original = descriptors[index]
                        let fd = original <= STDERR_FILENO ? fcntl(original, F_DUPFD_CLOEXEC, STDERR_FILENO + 1) : original
                        guard fd >= 0 else { throw AntigravityWireError(.unavailable) }
                        if fd != original { Darwin.close(original); descriptors[index] = fd }
                        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw AntigravityWireError(.unavailable) }
                    }
                }
                guard fcntl(descriptors[1], F_SETFL, fcntl(descriptors[1], F_GETFL) | O_NONBLOCK) == 0,
                      fcntl(descriptors[1], F_SETNOSIGPIPE, 1) == 0 else { throw AntigravityWireError(.unavailable) }
                let cwdFD = Darwin.open(cwd.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard cwdFD >= 0 else { throw AntigravityWireError(.unavailable) }
                defer { Darwin.close(cwdFD) }
                var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
                let a = posix_spawn_file_actions_init(&actions), b = posix_spawnattr_init(&attributes)
                guard a == 0, b == 0 else {
                    if a == 0 { posix_spawn_file_actions_destroy(&actions) }; if b == 0 { posix_spawnattr_destroy(&attributes) }
                    throw AntigravityWireError(.unavailable)
                }
                defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
                var codes = [posix_spawn_file_actions_addfchdir_np(&actions, cwdFD),
                    posix_spawn_file_actions_adddup2(&actions, descriptors[0], STDIN_FILENO),
                    posix_spawn_file_actions_adddup2(&actions, descriptors[3], STDOUT_FILENO),
                    posix_spawn_file_actions_adddup2(&actions, descriptors[5], STDERR_FILENO)]
                for fd in descriptors { codes.append(posix_spawn_file_actions_addclose(&actions, fd)) }
                var mask = sigset_t(); sigemptyset(&mask)
                var defaults = sigset_t(); sigemptyset(&defaults)
                for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP] { sigaddset(&defaults, signal) }
                codes += [posix_spawnattr_setsigmask(&attributes, &mask), posix_spawnattr_setsigdefault(&attributes, &defaults),
                    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))]
                guard codes.allSatisfy({ $0 == 0 }) else { throw AntigravityWireError(.unavailable) }
                let argv = [strdup(executable.path), nil]
                let env = environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) } + [nil]
                defer { for pointer in argv + env { free(pointer) } }
                var child: pid_t = 0
                let result = argv.withUnsafeBufferPointer { args in env.withUnsafeBufferPointer { values in
                    posix_spawn(&child, executable.path, &actions, &attributes, UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: values.baseAddress!))
                } }
                guard result == 0 else { throw AntigravityWireError(.unavailable) }
                for index in [0, 3, 5] { Darwin.close(descriptors[index]) }
                return (child, descriptors[1], descriptors[2], descriptors[4])
            } catch { for fd in descriptors { Darwin.close(fd) }; throw error }
        }
        pid = launch.0; inputFD = launch.1
        let drained = DispatchGroup(), state = readers
        for (fd, stderr) in [(launch.2, false), (launch.3, true)] {
            drained.enter()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                Self.drain(fd, state: state) { bytes in
                    guard let self, !self.overflowed else { return }
                    if case .dropped = continuation.yield(stderr ? .stderr(bytes) : .stdout(bytes)) {
                        self.lock.withLock { self.didOverflow = true }; self.stop()
                    }
                }
                drained.leave()
            }
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            var info = siginfo_t(), result: Int32
            repeat { result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) } while result == -1 && errno == EINTR
            if result == -1 { lock.withLock { signalAllowed = false }; state.stop() }
            else { stop() } // A naturally exited leader must not orphan its harness.
            drained.wait()
            lock.lock()
            // Keep the waitable leader until the final group signal, preventing
            // process-group ID reuse from targeting a later unrelated owner.
            if signalAllowed { _ = kill(-pid, SIGKILL) }
            var raw: Int32 = 0, reaped: pid_t = -1
            if result == 0 { repeat { reaped = waitpid(pid, &raw, 0) } while reaped == -1 && errno == EINTR }
            signalAllowed = false; finished = true
            let pending = waits; waits = []; lock.unlock()
            let code: Int32 = reaped == -1 ? 255 : ((raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f))
            if case .dropped = continuation.yield(.exited(code)) { lock.withLock { didOverflow = true } }
            continuation.finish()
            for waiter in pending { waiter.resume() }
        }
    }
    func write(_ data: Data, ticket: AntigravityWriteTicket) async throws {
        try await withTaskCancellationHandler {
            do { try Task.checkCancellation() } catch { ticket.cancel(); throw AntigravityWireError(.cancelled) }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let accepted = lock.withLock { () -> Bool in
                    guard !inputClosed, !finished else { return false }; writes += 1; writerDrain.enter(); return true
                }
                guard accepted else { continuation.resume(throwing: AntigravityWireError(.closed)); return }
                writer.async {
                    defer { ticket.finish(); self.lock.withLock { self.writes -= 1 }; self.writerDrain.leave() }
                    do {
                        // This is the final queued-not-started check. Checking at
                        // the actor/tail alone misses cancellation in this queue.
                        guard ticket.begin() else { throw AntigravityWireError(.cancelled) }
                        try data.withUnsafeBytes { bytes in
                            var offset = 0
                            while offset < bytes.count {
                                self.lock.lock()
                                guard !self.inputClosed, !self.finished else { self.lock.unlock(); throw AntigravityWireError(.closed) }
                                let count = Darwin.write(self.inputFD, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset)), error = errno
                                self.lock.unlock()
                                if count > 0 { offset += count; continue }
                                if count == -1 && error == EINTR { continue }
                                if count == -1 && (error == EAGAIN || error == EWOULDBLOCK) {
                                    var fd = pollfd(fd: self.inputFD, events: Int16(POLLOUT), revents: 0); _ = poll(&fd, 1, 50); continue
                                }
                                throw AntigravityWireError(.closed)
                            }
                        }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error as? AntigravityWireError ?? AntigravityWireError(.closed)) }
                }
            }
        } onCancel: { ticket.cancel() }
    }
    func stop() {
        let schedule = lock.withLock { () -> Bool in
            if !inputClosed { inputClosed = true; Darwin.close(inputFD) }
            guard !finished, !stopping, signalAllowed else { return false }
            stopping = true; _ = kill(-pid, SIGTERM); return true
        }
        guard schedule else { return }
        let seconds = Double(grace.components.seconds) + Double(grace.components.attoseconds) / 1e18
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [self] in
            lock.withLock { if signalAllowed { _ = kill(-pid, SIGKILL) } }
            readers.stop()
        }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in if finished { return true }; waits.append(continuation); return false }
            if ready { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            writerDrain.notify(queue: .global(qos: .utility)) { continuation.resume() }
        }
    }
    private static func drain(_ fd: Int32, state: AntigravityReadState, emit: (Data) -> Void) {
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while !state.stopped {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { emit(Data(bytes.prefix(count))) }
            else if count == -1 && errno == EINTR { continue }
            else if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                var ready = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0); _ = poll(&ready, 1, 50)
            } else { return }
        }
    }
}
private final class AntigravityReadState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var stopped: Bool { lock.withLock { value } }
    func stop() { lock.withLock { value = true } }
}
