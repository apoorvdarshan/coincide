import Darwin
import Foundation

/// Whether a terminal's shell is running a command, and that command's name.
public struct TerminalProcessActivity: Equatable, Sendable {
    public let hasRunningSubprocess: Bool
    public let label: String?
    public init(hasRunningSubprocess: Bool, label: String? = nil) {
        self.hasRunningSubprocess = hasRunningSubprocess
        self.label = hasRunningSubprocess ? label.flatMap(TerminalProcessInspector.normalizedName) : nil
    }
    public static let idle = TerminalProcessActivity(hasRunningSubprocess: false)
}

/// Read-only process-table inspection through libproc. No subprocess is spawned
/// and no process is signalled; results are advisory display state.
public enum TerminalProcessInspector {
    /// Port of T3's deriveSubprocessInspectResult. A foreground job other than the
    /// shell is running; otherwise any child counts, except a same-named fork with
    /// no children of its own (asynchronous prompt themes fork the shell).
    public static func derive(shellPID: pid_t, shellName: String?, foregroundGroup: pid_t?,
                              children: [pid_t: [pid_t]], names: [pid_t: String]) -> TerminalProcessActivity {
        guard shellPID > 0 else { return .idle }
        if let foregroundGroup, foregroundGroup > 0, foregroundGroup != shellPID {
            return .init(hasRunningSubprocess: true, label: names[foregroundGroup] ?? children[shellPID]?.first.flatMap { names[$0] })
        }
        let shell = shellName.flatMap(normalizedName)
        let child = (children[shellPID] ?? []).first { pid in
            shell == nil || names[pid].flatMap(normalizedName) != shell || !(children[pid] ?? []).isEmpty
        }
        guard let child else { return .idle }
        return .init(hasRunningSubprocess: true, label: names[child])
    }

    /// Samples the live process table for one shell. Returns nil when the shell is gone.
    public static func inspect(shellPID: pid_t) -> TerminalProcessActivity? {
        guard shellPID > 0, let info = bsdInfo(shellPID) else { return nil }
        let direct = childPIDs(of: shellPID)
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

    /// The working directory of the terminal's foreground job, or of the shell.
    public static func currentDirectory(shellPID: pid_t) -> String? {
        guard shellPID > 0 else { return nil }
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
    private static func childPIDs(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return buffer.prefix(min(Int(count), buffer.count)).filter { $0 > 0 }.sorted()
    }
    private static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return normalizedName(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.hasPrefix("/") ? path : nil
    }
}
