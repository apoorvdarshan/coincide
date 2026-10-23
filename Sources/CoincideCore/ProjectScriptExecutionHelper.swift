import Darwin
import Foundation

/// The executable target is deliberately a thin entry point; filesystem checks reuse the editor's anchor.
public enum ProjectScriptHelper {
    public static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 3, arguments[1] == "--run-id", let id = UUID(uuidString: arguments[2]),
              getsid(0) == getpid(), getpgrp() == getpid() else { return 64 }
        do { return try ScriptHelperLoop(id: id).run() } catch { return 70 }
    }
}

private final class ScriptPinnedWorkspace {
    let plan: ProjectScriptExecutionPlan
    let workspace: WorkspaceFileRoot
    let project: WorkspaceFileRoot
    init(_ plan: ProjectScriptExecutionPlan) throws {
        try plan.validate(); self.plan = plan
        workspace = try WorkspaceFileRoot(root: URL(fileURLWithPath: plan.workspacePath))
        project = try WorkspaceFileRoot(root: URL(fileURLWithPath: plan.projectRoot))
        try validate()
    }
    func validate() throws {
        try workspace.validate(); try project.validate()
        guard ProjectScriptExecutionNode(device: workspace.device, inode: workspace.inode) == plan.workspaceIdentity,
              ProjectScriptExecutionNode(device: project.device, inode: project.inode) == plan.projectRootIdentity else {
            throw ProjectScriptExecutionError(.configurationChanged)
        }
        if let action = plan.projectAction {
            // App-owned actions live outside the checkout; the same exact-revision rule applies to their settings file.
            _ = try action.verify(script: plan.script)
        } else {
            let document = try workspace.read(ProjectConfigurationService.fileName, allowMissing: false, maxBytes: ProjectConfigurationService.maximumBytes)
            guard let revision = document.revision, ProjectScriptExecutionRevision(revision) == plan.configurationRevision,
                  let configuration = try? ProjectConfiguration.parse(document.contents), configuration.scripts.indices.contains(plan.scriptIndex),
                  configuration.scripts[plan.scriptIndex] == plan.script else { throw ProjectScriptExecutionError(.configurationChanged) }
        }
        var executable = stat()
        guard lstat(plan.shellPath, &executable) == 0, executable.st_mode & S_IFMT == S_IFREG,
              access(plan.shellPath, X_OK) == 0, ProjectScriptExecutionNode(executable) == plan.shellIdentity else {
            throw ProjectScriptExecutionError(.configurationChanged)
        }
    }
}

private final class ScriptHelperLoop {
    let id: UUID
    var decoder = ScriptWire.Decoder(maximum: ScriptWire.maximumFrame)
    var status = Data(), output = Data(), input = Data()
    var pinned: ScriptPinnedWorkspace?
    var shell: pid_t = 0, master: Int32 = -1, commandEnded = false
    var stopping: ContinuousClock.Instant?
    var ptyEnded = false
    init(id: UUID) throws {
        self.id = id
        for fd in [ScriptWire.controlFD, ScriptWire.statusFD, ScriptWire.outputFD] {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else { throw ProjectScriptExecutionError(.protocolViolation) }
            try ScriptWire.setNonblocking(fd)
        }
        // The helper remains the session/group owner when a foreground command exits.
        // All these ignored dispositions are reset explicitly in the spawned shell.
        for value in [SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGTSTP, SIGTTIN, SIGTTOU] { _ = signal(value, SIG_IGN) }
        try emit("ready")
    }
    deinit { if master >= 0 { Darwin.close(master) } }
    func emit(_ kind: String, code: Int32? = nil, failure: String? = nil) throws {
        var message = ScriptWire.Message(kind, id: id); message.code = code; message.failure = failure
        let frame = try ScriptWire.frame(message, maximum: ScriptWire.maximumStatus)
        guard status.count + frame.count <= 65_536 else { throw ProjectScriptExecutionError(.protocolViolation) }
        status.append(frame)
    }
    func run() throws -> Int32 {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            if shell > 0 && !commandEnded {
                var value: Int32 = 0
                let observed = waitpid(shell, &value, WNOHANG)
                if observed == shell {
                    commandEnded = true
                    if value & 0x7f == 0 { try? emit("exited", code: (value >> 8) & 0xff) }
                    else { try? emit("signaled", code: value & 0x7f) }
                } else if observed < 0 && errno != EINTR {
                    try? emit("error", failure: "launchFailed"); beginStop()
                }
            }
            if let stopping {
                // EOF alone cannot prove drain: background jobs may have closed their stdio.
                if let members = try? ScriptWire.groupMembers(getpgrp(), excluding: getpid()), members.isEmpty {
                    flush(&status, to: ScriptWire.statusFD)
                    flush(&output, to: ScriptWire.outputFD)
                    return 0
                }
                if ContinuousClock.now - stopping >= .seconds(1) {
                    // This helper is still the group leader; its death is expected at escalation.
                    _ = kill(-getpgrp(), SIGKILL)
                    return 71
                }
            }
            flush(&status, to: ScriptWire.statusFD)
            flush(&output, to: ScriptWire.outputFD)
            if master >= 0, !input.isEmpty { flush(&input, to: master) }
            let ptyEvents = (master >= 0 && !ptyEnded && output.count < 131_072 ? Int16(POLLIN | POLLHUP) : 0) | (input.isEmpty ? 0 : Int16(POLLOUT))
            var watched = [pollfd(fd: stopping == nil ? ScriptWire.controlFD : -1, events: Int16(POLLIN | POLLHUP), revents: 0),
                pollfd(fd: ScriptWire.statusFD, events: status.isEmpty ? 0 : Int16(POLLOUT), revents: 0),
                pollfd(fd: ScriptWire.outputFD, events: output.isEmpty ? 0 : Int16(POLLOUT), revents: 0),
                pollfd(fd: ptyEvents == 0 ? -1 : master, events: ptyEvents, revents: 0)]
            let ready = poll(&watched, nfds_t(watched.count), 25)
            if ready < 0 { if errno == EINTR { continue }; beginStop(); continue }
            if watched[0].revents != 0 && stopping == nil {
                let count = Darwin.read(ScriptWire.controlFD, &buffer, buffer.count)
                if count > 0 {
                    do { for message in try decoder.append(Data(buffer.prefix(count))) { try handle(message) } }
                    catch {
                        let failure = (error as? ProjectScriptExecutionError)?.failure == .configurationChanged ? "configurationChanged" : "protocolViolation"
                        try? emit("error", failure: failure); beginStop()
                    }
                } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { beginStop() }
            }
            if master >= 0, watched[3].revents & Int16(POLLIN | POLLHUP) != 0, !ptyEnded, output.count < 131_072 {
                let count = Darwin.read(master, &buffer, min(buffer.count, 131_072 - output.count))
                if count > 0 { output.append(contentsOf: buffer.prefix(count)) }
                else if count == 0 || (count < 0 && errno == EIO) { ptyEnded = true }
                else if count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { beginStop() }
            }
            if watched[1].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 || watched[2].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { beginStop() }
        }
    }
    private func flush(_ bytes: inout Data, to fd: Int32) {
        guard !bytes.isEmpty else { return }
        let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, min($0.count, 16_384)) }
        if count > 0 { bytes.removeFirst(count) }
        else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { beginStop() }
    }
    private func beginStop() {
        guard stopping == nil else { return }
        stopping = .now
        // The helper ignores these; its shell and other group members use default dispositions.
        _ = kill(-getpgrp(), SIGHUP); _ = kill(-getpgrp(), SIGTERM)
    }
    private func handle(_ message: ScriptWire.Message) throws {
        guard message.runID == id else { throw ProjectScriptExecutionError(.protocolViolation) }
        guard stopping == nil else { return }
        switch message.kind {
        case "prepare":
            guard pinned == nil, shell == 0, let plan = message.plan, plan.id == id,
                  message.input == nil, message.columns == nil, message.rows == nil else { throw ProjectScriptExecutionError(.protocolViolation) }
            do { pinned = try ScriptPinnedWorkspace(plan) }
            catch { throw ProjectScriptExecutionError(.configurationChanged) }
            try emit("prepared")
        case "start":
            guard let pinned, shell == 0, message.plan == nil, message.input == nil else { throw ProjectScriptExecutionError(.protocolViolation) }
            try launch(pinned); try emit("started")
        case "input":
            guard shell > 0, let bytes = message.input, !bytes.isEmpty, bytes.count <= ScriptWire.maximumInput,
                  input.count + bytes.count <= 1_048_576 else { throw ProjectScriptExecutionError(.protocolViolation) }
            input.append(bytes)
        case "resize":
            guard shell > 0, let columns = message.columns, let rows = message.rows,
                  (1...1_000).contains(columns), (1...1_000).contains(rows) else { throw ProjectScriptExecutionError(.protocolViolation) }
            var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
            guard ioctl(master, TIOCSWINSZ, &size) == 0 else { throw ProjectScriptExecutionError(.launchFailed) }
        case "stop": beginStop()
        default: throw ProjectScriptExecutionError(.protocolViolation)
        }
    }
    private func launch(_ pinned: ScriptPinnedWorkspace) throws {
        var slave: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw ProjectScriptExecutionError(.launchFailed) }
        defer { Darwin.close(slave) }
        try ScriptWire.setNonblocking(master)
        guard fcntl(slave, F_SETFD, fcntl(slave, F_GETFD) | FD_CLOEXEC) == 0,
              ioctl(slave, TIOCSCTTY, 0) == 0, tcsetpgrp(slave, getpgrp()) == 0 else { throw ProjectScriptExecutionError(.launchFailed) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        let actionCode = posix_spawn_file_actions_init(&actions), attributeCode = posix_spawnattr_init(&attributes)
        guard actionCode == 0, attributeCode == 0 else {
            if actionCode == 0 { posix_spawn_file_actions_destroy(&actions) }
            if attributeCode == 0 { posix_spawnattr_destroy(&attributes) }
            throw ProjectScriptExecutionError(.launchFailed)
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t(), defaults = sigset_t(); sigemptyset(&mask); sigemptyset(&defaults)
        for value in [SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGTSTP, SIGTTIN, SIGTTOU] { sigaddset(&defaults, value) }
        let codes = [posix_spawn_file_actions_addfchdir_np(&actions, pinned.workspace.fd),
            posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO),
            posix_spawnattr_setsigmask(&attributes, &mask), posix_spawnattr_setsigdefault(&attributes, &defaults),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))]
        guard codes.allSatisfy({ $0 == 0 }) else { throw ProjectScriptExecutionError(.launchFailed) }
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "T3CODE_PROJECT_ROOT"); env.removeValue(forKey: "T3CODE_WORKTREE_PATH")
        let plan = pinned.plan
        let invocation = try ProjectScriptInvocation(script: plan.script, projectRoot: URL(fileURLWithPath: plan.projectRoot),
            worktreePath: plan.projectRootIdentity == plan.workspaceIdentity ? nil : URL(fileURLWithPath: plan.workspacePath))
        env.merge(invocation.environment) { _, new in new }
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = ""; env["NO_COLOR"] = "1"; env["FORCE_COLOR"] = "0"
        env["PWD"] = plan.workspacePath; env["SHELL"] = plan.shellPath
        let argumentStrings: [String] = [plan.shellPath, "-c", plan.script.command]
        let environmentStrings: [String] = env.sorted(by: { $0.key < $1.key }).map { $0.key + "=" + $0.value }
        let argv: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { value in value.withCString { strdup($0) } } + [nil]
        let environment: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { value in value.withCString { strdup($0) } } + [nil]
        defer { for value in argv + environment { free(value) } }
        // Nothing suspends between the complete anchored revision check and descriptor-based spawn.
        do { try pinned.validate() } catch { throw ProjectScriptExecutionError(.configurationChanged) }
        let code = argv.withUnsafeBufferPointer { args in environment.withUnsafeBufferPointer { values in
            posix_spawn(&shell, plan.shellPath, &actions, &attributes, UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: values.baseAddress!))
        } }
        guard code == 0 else { shell = 0; throw ProjectScriptExecutionError(.launchFailed) }
    }
}
