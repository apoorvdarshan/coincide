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
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var closed = false
    private(set) var lastError: String?

    init(opener: any PreviewOpening = DefaultBrowserPreviewOpener(), probe: Probe? = nil,
         timeout: Duration = .seconds(60), interval: Duration = .milliseconds(500)) {
        self.opener = opener; self.probe = probe ?? Self.acceptsConnection; self.timeout = timeout; self.interval = interval
    }
    func open(_ previewURL: String, sourceIsCurrent: @MainActor () -> Bool = { true }) throws {
        let target = try PreviewURLPolicy.validate(previewURL)
        guard !closed, !Task.isCancelled, sourceIsCurrent() else { throw CancellationError() }
        guard opener.openPreview(target.url) else { throw CoincideError("Could not open preview.") }
    }
    @discardableResult
    func scheduleAutoOpen(_ script: ProjectScript, session: LocalTerminalSession,
                          sourceIsCurrent: @escaping @MainActor () -> Bool = { true }) -> Task<Void, Never>? {
        scheduleAutoOpen(script, id: session.id, isRunning: { [weak session] in session?.lifecycle == .running }, sourceIsCurrent: sourceIsCurrent)
    }
    @discardableResult
    func scheduleAutoOpen(_ script: ProjectScript, id: UUID, isRunning: @escaping @MainActor () -> Bool,
                          sourceIsCurrent: @escaping @MainActor () -> Bool = { true }) -> Task<Void, Never>? {
        cancel(id)
        guard !closed, script.autoOpenPreview, let value = script.previewURL,
              let target = try? PreviewURLPolicy.validate(value), isRunning(), sourceIsCurrent() else { return nil }
        let probe = probe, timeout = timeout, interval = interval, token = UUID()
        let task = Task { [weak self] in
            defer {
                self?.jobs[token] = nil
                if self?.waits[id]?.token == token { self?.waits[id] = nil }
            }
            let outcome = await Self.waitUntilReady(target, probe: probe, timeout: timeout, interval: interval,
                isCurrent: { isRunning() && sourceIsCurrent() })
            guard let self, !self.closed, !Task.isCancelled, self.waits[id]?.token == token,
                  isRunning(), sourceIsCurrent() else { return }
            switch outcome {
            case .ready: if !self.opener.openPreview(target.url) { self.lastError = String(localized: "Could not open preview.") }
            case .timedOut: self.lastError = String(localized: "Could not open preview: the development server did not respond before the preview wait expired.")
            case .stopped: break
            }
        }
        waits[id] = (token, task); jobs[token] = task
        return task
    }
    private enum WaitOutcome { case ready, timedOut, stopped }
    private static func waitUntilReady(_ target: PreviewTarget, probe: Probe, timeout: Duration, interval: Duration,
                                       isCurrent: @MainActor () -> Bool) async -> WaitOutcome {
        let deadline = ContinuousClock.now + timeout
        while true {
            guard !Task.isCancelled, isCurrent() else { return .stopped }
            if !target.isLoopback { return .ready }
            if await probe(target) { return Task.isCancelled || !isCurrent() ? .stopped : .ready }
            guard ContinuousClock.now < deadline else { return .timedOut }
            do { try await Task.sleep(for: interval) } catch { return .stopped }
        }
    }
    func cancel(_ id: UUID) { waits.removeValue(forKey: id)?.task.cancel() }
    var pendingCount: Int { waits.count }
    func cancelAll() {
        closed = true
        for task in jobs.values { task.cancel() }
        waits.removeAll()
    }
    func shutdown() async {
        cancelAll()
        while !jobs.isEmpty { for job in Array(jobs.values) { await job.value }; await Task.yield() }
    }

    /// Numeric loopback only: no DNS/network lookup and no HTTP request. The
    /// owned worker cooperates with cancellation between bounded poll intervals.
    nonisolated static func acceptsConnection(_ target: PreviewTarget) async -> Bool {
        guard target.isLoopback else { return false }
        let task = Task.detached {
            let hosts = target.host == "::1" ? ["::1"] : (target.host == "127.0.0.1" || target.host == "0.0.0.0") ? ["127.0.0.1"] : ["127.0.0.1", "::1"]
            for host in hosts {
                guard !Task.isCancelled else { return false }
                var hints = addrinfo(ai_flags: AI_NUMERICHOST | AI_NUMERICSERV, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                                     ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var list: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, String(target.port), &hints, &list) == 0 else { continue }
                defer { freeaddrinfo(list) }
                var cursor = list
                while let entry = cursor {
                    defer { cursor = entry.pointee.ai_next }
                    guard !Task.isCancelled else { return false }
                    let fd = socket(entry.pointee.ai_family, entry.pointee.ai_socktype, entry.pointee.ai_protocol)
                    guard fd >= 0 else { continue }; defer { Darwin.close(fd) }
                    var noSignal: Int32 = 1
                    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                    if connect(fd, entry.pointee.ai_addr, entry.pointee.ai_addrlen) == 0 { return true }
                    guard errno == EINPROGRESS else { continue }
                    let deadline = ContinuousClock.now + .seconds(1)
                    while ContinuousClock.now < deadline, !Task.isCancelled {
                        var watched = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        let ready = poll(&watched, 1, 50)
                        if ready < 0, errno == EINTR { continue }
                        if ready == 0 { continue }; guard ready == 1 else { break }
                        var failure: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length) == 0, failure == 0 { return true }
                        break
                    }
                }
            }
            return false
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
