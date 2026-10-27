import AppKit
import CoincideKit
import Darwin

/// Where a terminal's shell starts and what it inherits.
enum TerminalLaunch {
    /// The user's login shell from the directory service, falling back to `$SHELL` and zsh.
    static let shellPath: String = {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let path = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/bin/zsh"
    }()

    /// The folder a new terminal of the thread starts in: its worktree or project folder, or the
    /// nearest folder that still exists. `missing` is the preferred folder when it could not be used.
    static func directory(for threadID: UUID) -> (url: URL, missing: URL?) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let store = AppStore.shared
        guard let preferred = store.workingDirectory(for: threadID) else { return (home, nil) }
        if isDirectory(preferred) { return (preferred, nil) }
        if let thread = store.thread(threadID), let project = store.project(thread.projectID), isDirectory(project.url) {
            return (project.url, preferred)
        }
        return (home, preferred)
    }

    /// The login-shell environment with SwiftTerm's terminal identity, minus the variables that
    /// describe whatever terminal or multiplexer Coincide itself was launched from.
    static func environment(from base: [String: String], directory: URL) -> [String] {
        var environment = base.filter { key, _ in
            !inheritedTerminalKeys.contains(key) && !inheritedTerminalPrefixes.contains { key.hasPrefix($0) }
        }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Coincide"
        environment["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        environment["SHELL"] = shellPath
        environment["PWD"] = directory.path
        if environment["LANG"] == nil, environment["LC_ALL"] == nil, environment["LC_CTYPE"] == nil {
            environment["LANG"] = defaultLanguage
        }
        return environment.map { "\($0.key)=\($0.value)" }
    }

    /// Runs `body`, which forks the shell, with SIGPIPE at its default action. Ignored signals
    /// survive exec, and a shell that ignores SIGPIPE breaks pipelines such as `yes | head`.
    static func withDefaultPipeSignal(_ body: () -> Void) {
        var defaultAction = sigaction()
        var previous = sigaction()
        sigaction(SIGPIPE, &defaultAction, &previous)
        body()
        sigaction(SIGPIPE, &previous, nil)
    }

    private static let inheritedTerminalKeys: Set<String> = [
        "TERM_SESSION_ID", "TERMINFO", "LC_TERMINAL", "LC_TERMINAL_VERSION", "COLORFGBG", "TMUX", "TMUX_PANE", "STY",
        "WINDOW", "SHLVL", "OLDPWD", "_",
    ]
    private static let inheritedTerminalPrefixes = [
        "COINCIDE_", "ITERM_", "KITTY_", "GHOSTTY_", "WEZTERM_", "ALACRITTY_", "VSCODE_", "WARP_", "ZELLIJ",
    ]

    /// GUI apps often start without a locale; without a UTF-8 one, shells and editors mangle non-ASCII text.
    private static var defaultLanguage: String {
        if let language = Locale.current.language.languageCode?.identifier, let region = Locale.current.region?.identifier {
            let name = "\(language)_\(region).UTF-8"
            if FileManager.default.fileExists(atPath: "/usr/share/locale/\(name)") { return name }
        }
        return "en_US.UTF-8"
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// Reads and signals a terminal's processes through the kernel.
enum TerminalProcess {
    /// Name of the job in the foreground of the terminal, or nil while the shell itself is.
    nonisolated static func foregroundCommand(shell: pid_t, terminal descriptor: Int32) -> String? {
        guard shell > 0, descriptor >= 0 else { return nil }
        let group = tcgetpgrp(descriptor)
        guard group > 0, group != shell else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(group, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return name.isEmpty ? nil : name
    }

    nonisolated static func currentDirectory(of pid: pid_t) -> URL? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Hangs up the shell and its foreground job the way closing a terminal window does.
    nonisolated static func hangUp(shell: pid_t, terminal descriptor: Int32) {
        if descriptor >= 0 {
            let group = tcgetpgrp(descriptor)
            if group > 0, group != shell { killpg(group, SIGHUP) }
        }
        if shell > 0 { kill(shell, SIGHUP) }
    }

    /// Waits for a shell that was asked to quit, killing it if it is still alive after `grace`,
    /// so no zombie is left behind.
    nonisolated static func reap(_ pid: pid_t, grace: TimeInterval = 1) {
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            let deadline = Date().addingTimeInterval(grace)
            while Date() < deadline {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || (result == -1 && errno != EINTR) { return }
                usleep(50_000)
            }
            kill(pid, SIGKILL)
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
    }

    /// The exit code in a `waitpid` status, or nil when the process was killed by a signal.
    nonisolated static func exitCode(fromWaitStatus status: Int32) -> Int32? {
        status & 0x7f == 0 ? (status >> 8) & 0xff : nil
    }
}

/// Opens what the user Command-clicks in a terminal. Program output can make a link whose target differs
/// from its text (OSC 8), so links open as transcript links do (see `SafeLinks`): web and mail links
/// directly, other schemes once the user agrees, and paths in an editor or Finder, never their default app.
enum TerminalLinks {
    static func open(_ link: String, relativeTo directory: URL, from window: NSWindow?) {
        guard let url = url(for: link, relativeTo: directory) else {
            NSSound.beep()
            return
        }
        if url.isFileURL {
            SafeLinks.openFile(url, from: window)
        } else {
            SafeLinks.openExternal(url, from: window)
        }
    }

    /// Resolves a URL, or a file path that may be relative to the shell's directory and may end in
    /// a `:line` or `:line:column` location.
    nonisolated static func url(for link: String, relativeTo directory: URL) -> URL? {
        let text = link.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            text.contains("://") || schemesWithoutAuthority.contains(scheme)
        {
            return url
        }
        var candidates = [text]
        if let location = text.range(of: #":[0-9]+(:[0-9]+)?$"#, options: .regularExpression) {
            candidates.append(String(text[..<location.lowerBound]))
        }
        for candidate in candidates {
            let expanded = (candidate as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded) : directory.appendingPathComponent(expanded).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private nonisolated static let schemesWithoutAuthority: Set<String> = ["mailto", "tel", "news", "magnet", "file"]
}
