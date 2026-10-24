import CryptoKit
import Darwin
import Foundation

// These errors never carry URLs, server bodies or private staging paths. Public
// provider wrappers translate them into their own fixed presentation errors.
enum PinnedArchiveError: String, Error, Sendable {
    case invalidRelease, invalidDestination, network, redirectDenied, responseRejected
    case sizeMismatch, checksumMismatch, archiveInvalid, io, cancelled, timedOut
}
enum PinnedArchiveRedirectPolicy: Sendable { case none, githubReleaseAsset }
struct PinnedArchiveDownload: Sendable {
    let url: URL
    let archiveBytes: Int64
    let sha256: String
    let accept: String
    let redirects: PinnedArchiveRedirectPolicy
}
enum PinnedArchiveDownloader {
    static func download(spec: PinnedArchiveDownload, to destination: URL, progress: @escaping @Sendable (Int64) -> Void,
                         configuration: URLSessionConfiguration?, deadline: Duration) async throws {
        guard let components = URLComponents(url: spec.url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              spec.archiveBytes > 0, spec.archiveBytes <= 1_073_741_824, spec.sha256.count == 64,
              spec.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              deadline > .zero, deadline <= .seconds(45 * 60) else { throw PinnedArchiveError.invalidRelease }
        if case .githubReleaseAsset = spec.redirects {
            guard components.host == "github.com", components.port == nil || components.port == 443 else { throw PinnedArchiveError.invalidRelease }
        }
        guard !Task.isCancelled else { throw PinnedArchiveError.cancelled }
        let directory = try PinnedArchiveDirectory(destination.deletingLastPathComponent())
        let file = try PinnedArchiveOutput(directory: directory, name: destination.lastPathComponent, mode: 0o600)
        let owner = PinnedArchiveDownloadOwner(spec: spec, file: file, configuration: configuration, deadline: deadline, progress: progress)
        do {
            try await owner.run()
            guard !Task.isCancelled else { throw PinnedArchiveError.cancelled }
        } catch {
            file.removeIfOwned()
            throw error as? PinnedArchiveError ?? PinnedArchiveError.network
        }
    }
}

private final class PinnedArchiveDownloadOwner: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let spec: PinnedArchiveDownload
    private let file: PinnedArchiveOutput
    private let deadline: Duration
    private let progress: @Sendable (Int64) -> Void
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var timer: Task<Void, Never>?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var reason: PinnedArchiveError?
    private var result: Result<Void, PinnedArchiveError>?
    private var count: Int64 = 0
    private var digestAccumulator = SHA256()
    private var responseAccepted = false
    private var redirectCount = 0
    private var lastProgress = ContinuousClock.now
    init(spec: PinnedArchiveDownload, file: PinnedArchiveOutput, configuration supplied: URLSessionConfiguration?,
         deadline: Duration, progress: @escaping @Sendable (Int64) -> Void) {
        self.spec = spec; self.file = file; self.deadline = deadline; self.progress = progress
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = supplied?.protocolClasses
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.httpAdditionalHeaders = [:]; configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45 * 60; configuration.timeoutIntervalForResource = 45 * 60
        configuration.waitsForConnectivity = false
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.name = "Coincide.PinnedArchive.Download"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }
    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                lock.lock(); continuation = waiter
                if let reason {
                    lock.unlock(); finishWithoutTask(reason); return
                }
                var request = URLRequest(url: spec.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45 * 60)
                request.httpShouldHandleCookies = false; request.setValue(spec.accept, forHTTPHeaderField: "Accept")
                let task = session.dataTask(with: request); self.task = task
                timer = Task { [weak self, deadline] in
                    do { try await Task.sleep(for: deadline) } catch { return }
                    self?.cancel(.timedOut)
                }
                lock.unlock(); progress(0); task.resume()
            }
        } onCancel: { self.cancel(.cancelled) }
    }
    private func cancel(_ error: PinnedArchiveError) {
        let task = lock.withLock { () -> URLSessionDataTask? in
            guard result == nil else { return nil }; if reason == nil { reason = error }; return self.task
        }
        task?.cancel()
    }
    private func finishWithoutTask(_ error: PinnedArchiveError) {
        lock.withLock { result = .failure(error) }; session.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            cancel(.responseRejected); completionHandler(.cancel); return
        }
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if encoding == nil || encoding == "identity", let length = response.value(forHTTPHeaderField: "Content-Length") {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), Int64(length) == spec.archiveBytes else {
                cancel(.sizeMismatch); completionHandler(.cancel); return
            }
        }
        responseAccepted = true; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard lock.withLock({ reason == nil }), responseAccepted else { return }
        do {
            guard Int64(data.count) <= spec.archiveBytes - count else { throw PinnedArchiveError.sizeMismatch }
            try file.write(data); count += Int64(data.count); digestAccumulator.update(data: data)
            let now = ContinuousClock.now
            if now - lastProgress >= .milliseconds(250) || count == spec.archiveBytes { lastProgress = now; progress(count) }
        } catch { cancel(error as? PinnedArchiveError ?? .io) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard case .githubReleaseAsset = spec.redirects, redirectCount < 3, let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme == "https",
              components.port == nil || components.port == 443, components.user == nil, components.password == nil, components.fragment == nil,
              components.host == "github.com" || components.host == "release-assets.githubusercontent.com",
              components.path.hasPrefix("/"), !components.path.contains("\\"), !components.path.contains("\0"),
              !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            cancel(.redirectDenied); completionHandler(nil); return
        }
        if components.host == "github.com", components.query != nil || components.path != spec.url.path {
            cancel(.redirectDenied); completionHandler(nil); return
        }
        // A CDN's signed query is opaque and lives only in URLSession memory.
        // Reconstruct the request so no credentials/cookies/header state can
        // cross the redirect. Never retain or describe the redirected URL.
        redirectCount += 1
        var redirected = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45 * 60)
        redirected.httpShouldHandleCookies = false; redirected.setValue(spec.accept, forHTTPHeaderField: "Accept")
        completionHandler(redirected)
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
                if let error { throw (error as? URLError)?.code == .timedOut ? PinnedArchiveError.timedOut : PinnedArchiveError.network }
                guard responseAccepted, count == spec.archiveBytes else { throw PinnedArchiveError.sizeMismatch }
                let digest = digestAccumulator.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == spec.sha256 else { throw PinnedArchiveError.checksumMismatch }
                try file.finish(mode: 0o600)
            } catch { failure = error as? PinnedArchiveError ?? .io }
        }
        lock.withLock {
            if let failure = reason ?? failure { result = .failure(failure) }
            else { result = .success(()) }
            self.task = nil
        }
        session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        let state = lock.withLock { () -> (CheckedContinuation<Void, any Error>?, Result<Void, PinnedArchiveError>) in
            let waiter = continuation; continuation = nil
            return (waiter, result ?? .failure(reason ?? .network))
        }
        state.0?.resume(with: state.1.mapError { $0 as any Error })
    }
}

/// Retains the exact staging directory and refuses name replacement. No path
/// from an archive is used for directory traversal or broad recursive cleanup.
final class PinnedArchiveDirectory: @unchecked Sendable {
    let fd: Int32
    let url: URL
    private let identity: stat
    private let parent: PinnedArchiveDirectory?
    init(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw PinnedArchiveError.invalidDestination }
        self.url = url; parent = nil
        let opened = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw PinnedArchiveError.invalidDestination }
        var node = stat()
        guard fstat(opened, &node) == 0, node.st_mode & S_IFMT == S_IFDIR, node.st_uid == geteuid() else { Darwin.close(opened); throw PinnedArchiveError.invalidDestination }
        fd = opened; identity = node
    }
    private init(_ name: String, parent: PinnedArchiveDirectory) throws {
        try Self.name(name); try parent.validate()
        self.parent = parent; url = parent.url.appendingPathComponent(name, isDirectory: true)
        let opened = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw PinnedArchiveError.invalidDestination }
        var node = stat()
        guard fstat(opened, &node) == 0, node.st_mode & S_IFMT == S_IFDIR, node.st_uid == geteuid() else {
            Darwin.close(opened); throw PinnedArchiveError.invalidDestination
        }
        fd = opened; identity = node
    }
    func create(_ name: String) throws -> PinnedArchiveDirectory {
        try Self.name(name); try validate()
        guard mkdirat(fd, name, 0o700) == 0 else { throw PinnedArchiveError.io }
        return try PinnedArchiveDirectory(name, parent: self)
    }
    private static func name(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw PinnedArchiveError.invalidDestination }
    }
    func validate() throws {
        try parent?.validate()
        var current = stat(), named = stat()
        guard fstat(fd, &current) == 0, lstat(url.path, &named) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
              named.st_dev == current.st_dev, named.st_ino == current.st_ino, named.st_mode & S_IFMT == S_IFDIR else { throw PinnedArchiveError.invalidDestination }
    }
    func finish() throws { try validate(); guard fchmod(fd, 0o755) == 0, fsync(fd) == 0 else { throw PinnedArchiveError.io }; try validate() }
    func removeIfOwned() {
        guard let parent else { return }
        var named = stat()
        if fstatat(parent.fd, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
           named.st_dev == identity.st_dev, named.st_ino == identity.st_ino, named.st_mode & S_IFMT == S_IFDIR {
            _ = unlinkat(parent.fd, url.lastPathComponent, AT_REMOVEDIR)
        }
    }
    deinit { Darwin.close(fd) }
}
final class PinnedArchiveOutput: @unchecked Sendable {
    let directory: PinnedArchiveDirectory
    let name: String
    let fd: Int32
    private let identity: stat
    init(directory: PinnedArchiveDirectory, name: String, mode: mode_t) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw PinnedArchiveError.invalidDestination }
        try directory.validate(); self.directory = directory; self.name = name
        let opened = openat(directory.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode)
        guard opened >= 0 else { throw PinnedArchiveError.io }
        var node = stat()
        guard fstat(opened, &node) == 0, node.st_mode & S_IFMT == S_IFREG, node.st_nlink == 1 else { Darwin.close(opened); throw PinnedArchiveError.io }
        fd = opened; identity = node
    }
    func validate() throws {
        try directory.validate(); var current = stat(), named = stat()
        guard fstat(fd, &current) == 0, fstatat(directory.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino, current.st_nlink == 1,
              named.st_dev == current.st_dev, named.st_ino == current.st_ino, named.st_mode & S_IFMT == S_IFREG else { throw PinnedArchiveError.invalidDestination }
    }
    func write(_ data: Data) throws {
        try validate()
        try data.withUnsafeBytes { bytes in
            var position = 0
            while position < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: position), min(65_536, bytes.count - position))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw PinnedArchiveError.io }; position += count
            }
        }
    }
    func finish(mode: mode_t) throws { try validate(); guard fchmod(fd, mode) == 0, fsync(fd) == 0, fsync(directory.fd) == 0 else { throw PinnedArchiveError.io }; try validate() }
    func removeIfOwned() {
        var node = stat()
        if fstatat(directory.fd, name, &node, AT_SYMLINK_NOFOLLOW) == 0,
           node.st_dev == identity.st_dev, node.st_ino == identity.st_ino, node.st_mode & S_IFMT == S_IFREG { _ = unlinkat(directory.fd, name, 0) }
    }
    deinit { Darwin.close(fd) }
}
