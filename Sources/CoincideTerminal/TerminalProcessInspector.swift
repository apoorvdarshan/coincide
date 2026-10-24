import Darwin
import Foundation

/// Whether a terminal's shell is running a command, and that command's name.
public struct TerminalProcessActivity: Equatable, Sendable {
    public let hasRunningSubprocess: Bool
    public let label: String?
    public let canCloseWhenIdle: Bool
    public init(hasRunningSubprocess: Bool, label: String? = nil, canCloseWhenIdle: Bool = false) {
        self.hasRunningSubprocess = hasRunningSubprocess
        self.label = hasRunningSubprocess ? label.flatMap(TerminalProcessInspector.normalizedName) : nil
        self.canCloseWhenIdle = !hasRunningSubprocess && canCloseWhenIdle
    }
    public static let idle = TerminalProcessActivity(hasRunningSubprocess: false, canCloseWhenIdle: true)
}

/// The executable admitted before launch. Interpreter wrappers that cannot be
/// resolved from the captured launch path never qualify for idle destruction.
struct TerminalShellExecutableIdentity: Equatable, Sendable {
    private struct Image: Equatable, Sendable { let device: UInt64, inode: UInt64 }
    private let images: [Image]

    static func capture(shellPath: String) -> Self? {
        if shellPath == "/bin/sh" {
            guard let direct = physicalExecutable(shellPath, protectedSystemImage: true) else { return nil }
            // Older macOS versions run sh directly. Apple's native selector
            // launcher instead execs a closed system target, defaulting to bash
            // only when the selector is absent; PATH and profiles play no part.
            var selector = stat()
            let selected: String
            errno = 0
            if lstat("/private/var/select/sh", &selector) == 0 {
                guard selector.st_mode & S_IFMT == S_IFLNK, selector.st_uid == 0,
                      let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/private/var/select/sh"),
                      ["/bin/bash", "/bin/dash", "/bin/zsh"].contains(target) else { return nil }
                selected = target
            } else {
                guard errno == ENOENT else { return nil }
                selected = "/bin/bash"
            }
            guard let variant = physicalExecutable(selected, protectedSystemImage: true) else { return nil }
            return .init(images: direct == variant ? [direct] : [direct, variant])
        }
        guard let executable = physicalExecutable(shellPath) else { return nil }
        return .init(images: [executable])
    }

    func matches(processID: pid_t) -> Bool {
        guard processID > 0 else { return false }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(processID, &path, UInt32(path.count)) > 0,
              let end = path.firstIndex(of: 0), end > 0 else { return false }
        let executable = String(decoding: path[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard let image = Self.physicalExecutable(executable) else { return false }
        return images.contains(image)
    }

    private static func physicalExecutable(_ path: String, protectedSystemImage: Bool = false) -> Image? {
        guard path.hasPrefix("/"), path.utf8.count < 4 * Int(MAXPATHLEN),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_ino != 0 else { return nil }
        if protectedSystemImage {
            guard info.st_uid == 0, info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { return nil }
        }
        return .init(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino))
    }
}

/// Ephemeral native process incarnation, never persisted or accepted from output.
struct TerminalIdleProcessProof: Equatable, Sendable {
    let pid: pid_t
    let startedSeconds: UInt64, startedMicroseconds: UInt64
}

/// Read-only process-table inspection through libproc. No subprocess is spawned
/// and no process is signalled; results are advisory display state.
public enum TerminalProcessInspector {
    /// Port of T3's deriveSubprocessInspectResult. A foreground job other than the
    /// shell is running; otherwise any child counts, except a same-named fork with
    /// no children of its own (asynchronous prompt themes fork the shell).
    public static func derive(shellPID: pid_t, shellName: String?, foregroundGroup: pid_t?,
                              children: [pid_t: [pid_t]], names: [pid_t: String]) -> TerminalProcessActivity {
        guard shellPID > 0 else { return .init(hasRunningSubprocess: false) }
        if let foregroundGroup, foregroundGroup > 0, foregroundGroup != shellPID {
            return .init(hasRunningSubprocess: true, label: names[foregroundGroup] ?? children[shellPID]?.first.flatMap { names[$0] })
        }
        let shell = shellName.flatMap(normalizedName)
        let child = (children[shellPID] ?? []).first { pid in
            shell == nil || names[pid].flatMap(normalizedName) != shell || !(children[pid] ?? []).isEmpty
        }
        guard let child else {
            return .init(hasRunningSubprocess: false,
                canCloseWhenIdle: foregroundGroup == shellPID && children[shellPID]?.isEmpty == true)
        }
        return .init(hasRunningSubprocess: true, label: names[child])
    }

    /// Samples the live process table for one shell. Returns nil when the shell is gone.
    public static func inspect(shellPID: pid_t) -> TerminalProcessActivity? {
        guard shellPID > 0, let info = bsdInfo(shellPID) else { return nil }
        guard let direct = childPIDs(of: shellPID) else { return .init(hasRunningSubprocess: false) }
        var children: [pid_t: [pid_t]] = [shellPID: direct], names: [pid_t: String] = [:]
        let shellName = name(of: shellPID)
        for pid in direct {
            names[pid] = name(of: pid)
            if names[pid] == shellName { children[pid] = childPIDs(of: pid) }
        }
        let foreground = info.e_tpgid > 0 ? pid_t(info.e_tpgid) : nil
        if let foreground, foreground != shellPID, names[foreground] == nil { names[foreground] = name(of: foreground) }
        return derive(shellPID: shellPID, shellName: shellName, foregroundGroup: foreground, children: children, names: names)
    }

    static func idleProof(shellPID: pid_t, expectedExecutable: TerminalShellExecutableIdentity?) -> TerminalIdleProcessProof? {
        guard shellPID > 0, let before = bsdInfo(shellPID), before.e_tpgid == shellPID,
              let expectedExecutable, expectedExecutable.matches(processID: shellPID),
              let children = childPIDs(of: shellPID), children.isEmpty else { return nil }
        // Descendants can outlive their intermediate parent and keep the owned
        // PTY session. A direct-child-only check cannot establish an idle shell.
        errno = 0
        let required = proc_listallpids(nil, 0)
        guard required > 0, required < 65_504 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(required) + 32)
        errno = 0
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0, Int(count) < pids.count, errno == 0 else { return nil }
        for pid in pids where pid > 0 && pid != shellPID {
            errno = 0
            let session = getsid(pid)
            if session == shellPID || (session < 0 && errno != ESRCH) { return nil }
        }
        guard let after = bsdInfo(shellPID), after.e_tpgid == shellPID,
              before.pbi_start_tvsec == after.pbi_start_tvsec, before.pbi_start_tvusec == after.pbi_start_tvusec,
              expectedExecutable.matches(processID: shellPID) else { return nil }
        return .init(pid: shellPID, startedSeconds: after.pbi_start_tvsec, startedMicroseconds: after.pbi_start_tvusec)
    }

    /// The working directory of the terminal's foreground job, or of the shell.
    public static func currentDirectory(shellPID: pid_t) -> String? {
        // Between fork and exec the shell still runs this process's image and
        // working directory; that is not the terminal's directory yet.
        guard shellPID > 0, executablePath(shellPID) != executablePath(getpid()) else { return nil }
        if let info = bsdInfo(shellPID), info.e_tpgid > 0, pid_t(info.e_tpgid) != shellPID,
           let directory = workingDirectory(of: pid_t(info.e_tpgid)) { return directory }
        return workingDirectory(of: shellPID)
    }

    static func normalizedName(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("-") { value.removeFirst() }
        if (value.hasPrefix("[") && value.hasSuffix("]")) || (value.hasPrefix("(") && value.hasSuffix(")")) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        let token = value.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? value
        let base = token.split(separator: "/").last.map(String.init) ?? token
        let clean = String(String.UnicodeScalarView(base.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(120))
        return clean.isEmpty ? nil : clean
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }
    private static func childPIDs(of pid: pid_t) -> [pid_t]? {
        var buffer = [pid_t](repeating: 0, count: 256)
        errno = 0
        let count = buffer.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard count >= 0, errno == 0, Int(count) < buffer.count else { return nil }
        return buffer.prefix(min(Int(count), buffer.count)).filter { $0 > 0 }.sorted()
    }
    private static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return normalizedName(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
    private static func executablePath(_ pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, let end = path.firstIndex(of: 0), end > 0 else { return nil }
        return String(decoding: path[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.hasPrefix("/") ? path : nil
    }
}
