import CoincideCore
import Darwin
import Foundation

/// Shell resolution with T3's fallback order: the requested shell, `$SHELL`,
/// the account's login shell, then /bin/zsh, /bin/bash and /bin/sh. Only
/// existing executable regular files are returned, without duplicates.
public enum TerminalShell {
    public static func candidates(requested: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                                  accountShell: String? = TerminalShell.accountShell) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for candidate in [requested, environment["SHELL"], accountShell, "/bin/zsh", "/bin/bash", "/bin/sh"] {
            guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty,
                  !candidate.contains("\0"), let url = ProcessChannel.findExecutable(candidate) else { continue }
            var info = stat()
            guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, seen.insert(url.path).inserted else { continue }
            result.append(url.path)
        }
        return result
    }

    public static var accountShell: String? {
        getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}
