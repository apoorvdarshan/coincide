import Darwin
import Dispatch
import Foundation

/// An explicit external handoff. The launched app owns its lifetime, including after Coincide
/// closes. There is deliberately no stop, timeout, process-group signal, or shutdown API.
public enum DetachedExternalEditorLauncher {
    public static func launch(executableURL: URL, arguments: [String]) throws {
        try Task.checkCancellation()
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
              !executableURL.path.contains("\0"), arguments.count <= 32,
              arguments.allSatisfy({ !$0.contains("\0") && $0.utf16.count <= 16_384 }) else {
            throw ExternalEditorError(.invalidTarget, "The external editor launch request is invalid.")
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw failure() }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw failure() }
        defer { posix_spawnattr_destroy(&attributes) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0) == 0 else { throw failure() }
        }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { throw failure() }
        let argv = ([executableURL.path] + arguments).map { strdup($0) }
        let environment = sanitizedEnvironment(ProcessChannel.environment()).sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) }
        defer { for value in argv + environment { free(value) } }
        guard argv.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else { throw failure() }
        var child: pid_t = 0
        // Do not check cancellation after this syscall succeeds: a completed handoff is not
        // undone by cancelling the task which requested it.
        let result = (argv + [nil]).withUnsafeBufferPointer { args in
            (environment + [nil]).withUnsafeBufferPointer { env in
                posix_spawn(&child, executableURL.path, &actions, &attributes,
                            UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        guard result == 0 else { throw failure() }
        ExternalEditorChildReaper.shared.observe(child)
    }
    static func sanitizedEnvironment(_ input: [String: String]) -> [String: String] {
        let context: Set<String> = ["ELECTRON_RUN_AS_NODE", "CODEX_THREAD_ID", "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CEILING_DIRECTORIES", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS", "GIT_IMPLICIT_WORK_TREE", "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_SUPER_PREFIX", "GIT_NAMESPACE"]
        return input.filter { !context.contains($0.key) && !$0.key.hasPrefix("GIT_CONFIG_KEY_") && !$0.key.hasPrefix("GIT_CONFIG_VALUE_") }
    }
    private static func failure() -> ExternalEditorError { .init(.launchFailed, "The external editor could not be launched. Refresh the installed editors and try again.") }
}

/// Exit notifications avoid reserving one blocking thread for each independently running GUI.
/// waitpid only reaps our child; it never signals a PID, even if another reaper won ownership.
private final class ExternalEditorChildReaper: @unchecked Sendable {
    static let shared = ExternalEditorChildReaper()
    private let lock = NSLock()
    private var sources: [pid_t: any DispatchSourceProcess] = [:]
    func observe(_ child: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { [self] in
            var status: Int32 = 0, result: pid_t
            repeat { result = waitpid(child, &status, 0) } while result < 0 && errno == EINTR
            lock.lock(); let owned = sources.removeValue(forKey: child); lock.unlock()
            owned?.cancel()
        }
        lock.lock(); sources[child] = source; lock.unlock()
        source.activate()
    }
}
