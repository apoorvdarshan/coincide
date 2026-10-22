import CryptoKit
import Darwin
import Foundation

public enum AntigravityArchiveError: String, LocalizedError, Sendable, Equatable {
    case invalidRelease, invalidDestination, network, redirectDenied, responseRejected
    case sizeMismatch, checksumMismatch, archiveInvalid, io, cancelled, timedOut
    public var errorDescription: String? {
        switch self {
        case .invalidRelease: "The pinned Antigravity release is invalid."
        case .invalidDestination: "The owned Antigravity staging location is unavailable or changed."
        case .network: "The Antigravity download could not complete. Nothing was installed."
        case .redirectDenied: "The Antigravity download redirected unexpectedly. Nothing was installed."
        case .responseRejected: "The Antigravity download returned an unexpected response."
        case .sizeMismatch: "The Antigravity archive did not match its pinned size."
        case .checksumMismatch: "The Antigravity archive failed its SHA-256 check."
        case .archiveInvalid: "The Antigravity archive contains invalid, unsafe or unexpected members."
        case .io: "The Antigravity staging files could not be written or verified."
        case .cancelled: "The Antigravity installation was cancelled."
        case .timedOut: "The Antigravity download exceeded its time limit."
        }
    }
}

public enum AntigravityArchiveDownloader {
    public static func download(release: AntigravityManagedRelease, to destination: URL,
                                progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await download(release: release, to: destination, progress: progress, configuration: nil, deadline: .seconds(45 * 60))
    }
    // Fixtures may inject URLProtocol, never weaken the production HTTPS/origin rules.
    static func download(release: AntigravityManagedRelease, to destination: URL, progress: @escaping @Sendable (Int64) -> Void,
                         configuration: URLSessionConfiguration?, deadline: Duration) async throws {
        do { try release.validate() } catch { throw AntigravityArchiveError.invalidRelease }
        guard let components = URLComponents(url: release.url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              deadline > .zero, deadline <= .seconds(45 * 60) else { throw AntigravityArchiveError.invalidRelease }
        guard !Task.isCancelled else { throw AntigravityArchiveError.cancelled }
        let directory = try AntigravityArchiveDirectory(destination.deletingLastPathComponent())
        let file = try AntigravityArchiveOutput(directory: directory, name: destination.lastPathComponent, mode: 0o600)
        let owner = AntigravityDownloadOwner(release: release, file: file, configuration: configuration, deadline: deadline, progress: progress)
        do {
            try await owner.run()
            guard !Task.isCancelled else { throw AntigravityArchiveError.cancelled }
        } catch {
            file.removeIfOwned()
            throw error as? AntigravityArchiveError ?? AntigravityArchiveError.network
        }
    }
}

private final class AntigravityDownloadOwner: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let release: AntigravityManagedRelease
    private let file: AntigravityArchiveOutput
    private let deadline: Duration
    private let progress: @Sendable (Int64) -> Void
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var timer: Task<Void, Never>?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var reason: AntigravityArchiveError?
    private var result: Result<Void, AntigravityArchiveError>?
    private var count: Int64 = 0
    private var digestAccumulator = SHA256()
    private var responseAccepted = false
    private var lastProgress = ContinuousClock.now
    init(release: AntigravityManagedRelease, file: AntigravityArchiveOutput, configuration supplied: URLSessionConfiguration?,
         deadline: Duration, progress: @escaping @Sendable (Int64) -> Void) {
        self.release = release; self.file = file; self.deadline = deadline; self.progress = progress
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = supplied?.protocolClasses
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.httpAdditionalHeaders = [:]; configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45 * 60; configuration.timeoutIntervalForResource = 45 * 60
        configuration.waitsForConnectivity = false
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.name = "Coincide.Antigravity.Download"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }
    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                lock.lock(); continuation = waiter
                if let reason {
                    lock.unlock(); finishWithoutTask(reason); return
                }
                var request = URLRequest(url: release.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45 * 60)
                request.httpShouldHandleCookies = false; request.setValue("application/zip", forHTTPHeaderField: "Accept")
                let task = session.dataTask(with: request); self.task = task
                timer = Task { [weak self, deadline] in
                    do { try await Task.sleep(for: deadline) } catch { return }
                    self?.cancel(.timedOut)
                }
                lock.unlock(); progress(0); task.resume()
            }
        } onCancel: { self.cancel(.cancelled) }
    }
    private func cancel(_ error: AntigravityArchiveError) {
        let task = lock.withLock { () -> URLSessionDataTask? in
            guard result == nil else { return nil }; if reason == nil { reason = error }; return self.task
        }
        task?.cancel()
    }
    private func finishWithoutTask(_ error: AntigravityArchiveError) {
        lock.withLock { result = .failure(error) }; session.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            cancel(.responseRejected); completionHandler(.cancel); return
        }
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if encoding == nil || encoding == "identity", let length = response.value(forHTTPHeaderField: "Content-Length") {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), Int64(length) == release.archiveBytes else {
                cancel(.sizeMismatch); completionHandler(.cancel); return
            }
        }
        responseAccepted = true; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard lock.withLock({ reason == nil }), responseAccepted else { return }
        do {
            guard Int64(data.count) <= release.archiveBytes - count else { throw AntigravityArchiveError.sizeMismatch }
            try file.write(data); count += Int64(data.count); digestAccumulator.update(data: data)
            let now = ContinuousClock.now
            if now - lastProgress >= .milliseconds(250) || count == release.archiveBytes { lastProgress = now; progress(count) }
        } catch { cancel(error as? AntigravityArchiveError ?? .io) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        cancel(.redirectDenied); completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { cancel(.responseRejected); completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        timer?.cancel()
        var failure = lock.withLock { reason }
        if failure == nil {
            do {
                if let error { throw (error as? URLError)?.code == .timedOut ? AntigravityArchiveError.timedOut : AntigravityArchiveError.network }
                guard responseAccepted, count == release.archiveBytes else { throw AntigravityArchiveError.sizeMismatch }
                let digest = digestAccumulator.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == release.sha256 else { throw AntigravityArchiveError.checksumMismatch }
                try file.finish(mode: 0o600)
            } catch { failure = error as? AntigravityArchiveError ?? .io }
        }
        lock.withLock {
            if let failure = reason ?? failure { result = .failure(failure) }
            else { result = .success(()) }
            self.task = nil
        }
        session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        let state = lock.withLock { () -> (CheckedContinuation<Void, any Error>?, Result<Void, AntigravityArchiveError>) in
            let waiter = continuation; continuation = nil
            return (waiter, result ?? .failure(reason ?? .network))
        }
        state.0?.resume(with: state.1.mapError { $0 as any Error })
    }
}

/// Retains the exact staging directory and refuses name replacement. No path
/// from an archive is used for directory traversal or broad recursive cleanup.
final class AntigravityArchiveDirectory: @unchecked Sendable {
    let fd: Int32
    let url: URL
    private let identity: stat
    init(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw AntigravityArchiveError.invalidDestination }
        self.url = url
        let opened = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw AntigravityArchiveError.invalidDestination }
        var node = stat()
        guard fstat(opened, &node) == 0, node.st_mode & S_IFMT == S_IFDIR, node.st_uid == geteuid() else { Darwin.close(opened); throw AntigravityArchiveError.invalidDestination }
        fd = opened; identity = node
    }
    func validate() throws {
        var current = stat(), named = stat()
        guard fstat(fd, &current) == 0, lstat(url.path, &named) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
              named.st_dev == current.st_dev, named.st_ino == current.st_ino, named.st_mode & S_IFMT == S_IFDIR else { throw AntigravityArchiveError.invalidDestination }
    }
    deinit { Darwin.close(fd) }
}
final class AntigravityArchiveOutput: @unchecked Sendable {
    let directory: AntigravityArchiveDirectory
    let name: String
    let fd: Int32
    private let identity: stat
    init(directory: AntigravityArchiveDirectory, name: String, mode: mode_t) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw AntigravityArchiveError.invalidDestination }
        try directory.validate(); self.directory = directory; self.name = name
        let opened = openat(directory.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode)
        guard opened >= 0 else { throw AntigravityArchiveError.io }
        var node = stat()
        guard fstat(opened, &node) == 0, node.st_mode & S_IFMT == S_IFREG, node.st_nlink == 1 else { Darwin.close(opened); throw AntigravityArchiveError.io }
        fd = opened; identity = node
    }
    func validate() throws {
        try directory.validate(); var current = stat(), named = stat()
        guard fstat(fd, &current) == 0, fstatat(directory.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino, current.st_nlink == 1,
              named.st_dev == current.st_dev, named.st_ino == current.st_ino, named.st_mode & S_IFMT == S_IFREG else { throw AntigravityArchiveError.invalidDestination }
    }
    func write(_ data: Data) throws {
        try validate()
        try data.withUnsafeBytes { bytes in
            var position = 0
            while position < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: position), min(65_536, bytes.count - position))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw AntigravityArchiveError.io }; position += count
            }
        }
    }
    func finish(mode: mode_t) throws { try validate(); guard fchmod(fd, mode) == 0, fsync(fd) == 0, fsync(directory.fd) == 0 else { throw AntigravityArchiveError.io }; try validate() }
    func removeIfOwned() {
        var node = stat()
        if fstatat(directory.fd, name, &node, AT_SYMLINK_NOFOLLOW) == 0,
           node.st_dev == identity.st_dev, node.st_ino == identity.st_ino, node.st_mode & S_IFMT == S_IFREG { _ = unlinkat(directory.fd, name, 0) }
    }
    deinit { Darwin.close(fd) }
}
