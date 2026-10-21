import CoreServices
import Foundation

/// FSEvents is recursive and advisory. Consumers re-read state; overflow/root changes never
/// masquerade as a complete list of file mutations. One delayed notification bounds bursts.
final class WorkspaceNativeFileWatcher: @unchecked Sendable {
    private final class Callback: @unchecked Sendable {
        let changed: @Sendable (Bool) -> Void
        init(_ changed: @escaping @Sendable (Bool) -> Void) { self.changed = changed }
    }
    private final class State: @unchecked Sendable {
        let queue = DispatchQueue(label: "Coincide.workspace-file-watch", qos: .utility)
        var stream: FSEventStreamRef?
        var callback: Unmanaged<Callback>?
        var pending: DispatchWorkItem?
        var unavailable = false
        var closed = false
        func stop() {
            guard !closed else { return }; closed = true
            pending?.cancel(); pending = nil
            if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
            callback?.release(); callback = nil
        }
        deinit { stop() }
    }
    private let state: State
    init(path: String, changed: @escaping @Sendable (Bool) -> Void) throws {
        let state = State(); self.state = state
        let callback = Callback { [weak state] unavailable in
            guard let state, !state.closed else { return }
            state.unavailable = state.unavailable || unavailable
            guard state.pending == nil else { return }
            let work = DispatchWorkItem { [weak state] in
                guard let state, !state.closed else { return }
                state.pending = nil
                let unavailable = state.unavailable; state.unavailable = false
                changed(unavailable)
            }
            state.pending = work; state.queue.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
        }
        let retained = Unmanaged.passRetained(callback); state.callback = retained
        var context = FSEventStreamContext(version: 0, info: retained.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, { _, info, count, _, flags, _ in
            guard let info else { return }
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            // Every event invalidates the complete view, including dropped/coalesced events.
            // Only root movement/unmount changes availability rather than requesting a rescan.
            let exceptional = UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount)
            var unavailable = false
            for index in 0..<count { unavailable = unavailable || flags[index] & exceptional != 0 }
            callback.changed(unavailable)
        }, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags) else {
            state.stop(); throw WorkspaceFileError(.operationFailed, "The workspace file watcher could not be created.")
        }
        state.stream = stream
        FSEventStreamSetDispatchQueue(stream, state.queue)
        guard FSEventStreamStart(stream) else {
            state.queue.sync { state.stop() }; throw WorkspaceFileError(.operationFailed, "The workspace file watcher could not be started.")
        }
    }
    func close() async {
        let state = state
        await withCheckedContinuation { continuation in
            state.queue.async { state.stop(); continuation.resume() }
        }
    }
    deinit {
        let state = state
        state.queue.async { state.stop() }
    }
}
