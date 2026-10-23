import AppKit
import CoincideCore
import CoincideTerminal
import Darwin
import Foundation

/// Destination for script previews. Stage 1 opens the default browser; an in-app preview panel
/// can adopt this protocol later without changing script or terminal callers.
@MainActor protocol PreviewOpening: AnyObject {
    func openPreview(_ url: URL) -> Bool
}

@MainActor final class DefaultBrowserPreviewOpener: PreviewOpening {
    func openPreview(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}

/// Opens a script's `previewUrl`. Automatic opening waits until a loopback port accepts a TCP
/// connection (up to 60 seconds) and is cancelled when its terminal stops first.
@MainActor final class ScriptPreviewLauncher {
    typealias Probe = @Sendable (PreviewTarget) async -> Bool
    private let opener: any PreviewOpening
    private let probe: Probe
    private let timeout: Duration
    private let interval: Duration
    private var waits: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private(set) var lastError: String?

    init(opener: any PreviewOpening = DefaultBrowserPreviewOpener(), probe: @escaping Probe = ScriptPreviewLauncher.acceptsConnection,
         timeout: Duration = .seconds(60), interval: Duration = .milliseconds(500)) {
        self.opener = opener; self.probe = probe; self.timeout = timeout; self.interval = interval
    }
    func open(_ previewURL: String) throws {
        let target = try PreviewURLPolicy.validate(previewURL)
        guard opener.openPreview(target.url) else { throw CoincideError("Could not open preview.") }
    }
    /// Returns the wait task so callers and tests can observe completion; nil when nothing is scheduled.
    @discardableResult func scheduleAutoOpen(_ script: ProjectScript, session: LocalTerminalSession) -> Task<Void, Never>? {
        scheduleAutoOpen(script, id: session.id) { [weak session] in session?.lifecycle == .running }
    }
    @discardableResult func scheduleAutoOpen(_ script: ProjectScript, id: UUID, isRunning: @escaping @MainActor () -> Bool) -> Task<Void, Never>? {
        guard script.autoOpenPreview, let value = script.previewURL, let target = try? PreviewURLPolicy.validate(value) else { return nil }
        waits.removeValue(forKey: id)?.task.cancel()
        let probe = probe, timeout = timeout, interval = interval, token = UUID()
        let task = Task { [weak self] in
            let outcome = await Self.waitUntilReady(target, probe: probe, timeout: timeout, interval: interval, isRunning: isRunning)
            guard let self else { return }
            if self.waits[id]?.token == token { self.waits.removeValue(forKey: id) }
            switch outcome {
            case .ready: if !self.opener.openPreview(target.url) { self.lastError = String(localized: "Could not open preview.") }
            case .timedOut: self.lastError = String(localized: "Could not open preview: \(target.url.absoluteString) did not respond within 60 seconds.")
            case .stopped: break
            }
        }
        waits[id] = (token, task)
        return task
    }
    private enum WaitOutcome { case ready, timedOut, stopped }
    private static func waitUntilReady(_ target: PreviewTarget, probe: Probe, timeout: Duration, interval: Duration,
                                       isRunning: @MainActor () -> Bool) async -> WaitOutcome {
        let deadline = ContinuousClock.now + timeout
        while true {
            guard !Task.isCancelled, isRunning() else { return .stopped }
            // Remote hosts are not probed; only a local development server is awaited.
            if !target.isLoopback { return .ready }
            if await probe(target) { return Task.isCancelled || !isRunning() ? .stopped : .ready }
            guard ContinuousClock.now < deadline else { return .timedOut }
            do { try await Task.sleep(for: interval) } catch { return .stopped }
        }
    }
    func cancel(_ id: UUID) { waits.removeValue(forKey: id)?.task.cancel() }
    var pendingCount: Int { waits.count }
    func shutdown() { for wait in waits.values { wait.task.cancel() }; waits.removeAll() }

    /// A bounded nonblocking TCP connect to the preview host and port.
    nonisolated static func acceptsConnection(_ target: PreviewTarget) async -> Bool {
        await Task.detached {
            var hints = addrinfo(ai_flags: AI_NUMERICSERV, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                                 ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var list: UnsafeMutablePointer<addrinfo>?
            let host = target.host == "0.0.0.0" ? "127.0.0.1" : target.host
            guard getaddrinfo(host, String(target.port), &hints, &list) == 0, let first = list else { return false }
            defer { freeaddrinfo(list) }
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let entry = cursor {
                defer { cursor = entry.pointee.ai_next }
                let fd = socket(entry.pointee.ai_family, entry.pointee.ai_socktype, entry.pointee.ai_protocol)
                guard fd >= 0 else { continue }
                defer { Darwin.close(fd) }
                var noSignal: Int32 = 1
                _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                if connect(fd, entry.pointee.ai_addr, entry.pointee.ai_addrlen) == 0 { return true }
                guard errno == EINPROGRESS else { continue }
                var watched = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&watched, 1, 1_000) == 1 else { continue }
                var failure: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length) == 0, failure == 0 { return true }
            }
            return false
        }.value
    }
}
