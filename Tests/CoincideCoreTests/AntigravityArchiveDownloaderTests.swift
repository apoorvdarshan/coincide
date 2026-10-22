import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CoincideCore

@Suite struct AntigravityArchiveDownloaderTests {
    @Test func decodedBytesAreStreamedHashedAndWrittenPrivately() async throws {
        let fixture = AntigravityArchiveHTTPFixture(); defer { fixture.remove() }
        let scratch = try AntigravityDownloadScratch(); defer { scratch.remove() }
        let bytes = Data("synthetic archive 🌍".utf8), progress = AntigravityDownloadProgress()
        let release = try fixture.release(bytes)
        let configuration = fixture.configuration
        configuration.httpAdditionalHeaders = ["Authorization": "private-unrelated", "Cookie": "private-cookie"]
        let operation = Task { try await AntigravityArchiveDownloader.download(release: release, to: scratch.archive, progress: progress.append,
                                                                             configuration: configuration, deadline: .seconds(3)) }
        let peer = try await fixture.started()
        #expect(peer.request.url == release.url)
        #expect(peer.request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(peer.request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(!peer.request.httpShouldHandleCookies)
        peer.respond(headers: ["Content-Length": String(bytes.count)])
        for byte in bytes { peer.send(Data([byte])) }
        peer.finish()
        try await operation.value
        #expect(try Data(contentsOf: scratch.archive) == bytes)
        var node = stat(); #expect(lstat(scratch.archive.path, &node) == 0)
        #expect(node.st_mode & 0o777 == 0o600)
        #expect(progress.values.first == 0 && progress.values.last == Int64(bytes.count))
        #expect(fixture.startCount == 1)
    }

    @Test func compressedContentLengthIsNotMistakenForDecodedLength() async throws {
        let fixture = AntigravityArchiveHTTPFixture(); defer { fixture.remove() }
        let scratch = try AntigravityDownloadScratch(); defer { scratch.remove() }
        let bytes = Data(repeating: 65, count: 128), release = try fixture.release(bytes)
        let operation = Task { try await fixture.download(release, to: scratch.archive) }
        let peer = try await fixture.started()
        // URLSession delegates receive decoded bytes. This synthetic protocol
        // supplies those bytes, with a deliberately different encoded length.
        peer.respond(headers: ["Content-Encoding": "gzip", "Content-Length": "17"])
        peer.send(bytes); peer.finish()
        try await operation.value
        #expect(try Data(contentsOf: scratch.archive) == bytes)
    }

    @Test func declaredSizeAndIncrementalOverflowCancelBeforeEOF() async throws {
        for declared in [false, true] {
            let fixture = AntigravityArchiveHTTPFixture(); defer { fixture.remove() }
            let scratch = try AntigravityDownloadScratch(); defer { scratch.remove() }
            let release = try fixture.release(Data([1, 2, 3, 4]))
            let operation = Task { try await fixture.download(release, to: scratch.archive) }
            let peer = try await fixture.started()
            peer.respond(headers: declared ? ["Content-Length": "5"] : [:])
            if !declared { peer.send(Data([1, 2])); peer.send(Data([3, 4, 5])) }
            await #expect(throws: AntigravityArchiveError.sizeMismatch) { try await operation.value }
            try await fixture.stopped()
            #expect(!FileManager.default.fileExists(atPath: scratch.archive.path))
            #expect(fixture.startCount == 1 && fixture.stopCount == 1)
        }
    }

    @Test func shortAndWrongHashResponsesRemoveOnlyTheirPartialArchive() async throws {
        for wrongHash in [false, true] {
            let fixture = AntigravityArchiveHTTPFixture(); defer { fixture.remove() }
            let scratch = try AntigravityDownloadScratch(); defer { scratch.remove() }
            let release = try fixture.release(Data([1, 2, 3, 4]))
            let operation = Task { try await fixture.download(release, to: scratch.archive) }
            let peer = try await fixture.started(); peer.respond()
            peer.send(wrongHash ? Data([4, 3, 2, 1]) : Data([1, 2])); peer.finish()
            let expected: AntigravityArchiveError = wrongHash ? .checksumMismatch : .sizeMismatch
            await #expect(throws: expected) { try await operation.value }
            #expect(!FileManager.default.fileExists(atPath: scratch.archive.path))
            #expect(try Data(contentsOf: scratch.sentinel) == Data("retain".utf8))
        }
    }

    @Test func rejectionRedirectAndUnderlyingErrorsNeverExposeRemoteDetails() async throws {
        for failure in 0..<3 {
            let fixture = AntigravityArchiveHTTPFixture(); defer { fixture.remove() }
            let scratch = try AntigravityDownloadScratch(); defer { scratch.remove() }
            let release = try fixture.release(Data([1]))
            let operation = Task { try await fixture.download(release, to: scratch.archive) }
            let peer = try await fixture.started()
            let expected: AntigravityArchiveError
            if failure == 0 { expected = .responseRejected; peer.respond(status: 401); peer.send(Data("private-body".utf8)) }
            else if failure == 1 { expected = .redirectDenied; peer.redirect(to: URL(string: "https://private-other.invalid/private-token")!) }
            else {
                expected = .network
                peer.fail(NSError(domain: "private-error", code: 7, userInfo: [NSLocalizedDescriptionKey: "private-body https://name:secret@private.invalid"]))
            }
            do { try await operation.value; Issue.record("An invalid synthetic response was accepted.") }
            catch {
                #expect(error as? AntigravityArchiveError == expected)
                #expect(!String(reflecting: error).contains("private-"))
                #expect(!error.localizedDescription.contains("secret"))
            }
            #expect(!FileManager.default.fileExists(atPath: scratch.archive.path))
            #expect(fixture.startCount == 1)
        }
    }

    @Test func cancellationAndDeadlineDrainTheirExactTaskWithoutReplay() async throws {
        for cancellation in [false, true] {
            let fixture = AntigravityArchiveHTTPFixture(); defer { fixture.remove() }
            let scratch = try AntigravityDownloadScratch(); defer { scratch.remove() }
            let release = try fixture.release(Data([1, 2]))
            let operation = Task { try await fixture.download(release, to: scratch.archive, deadline: cancellation ? .seconds(3) : .milliseconds(150)) }
            let peer = try await fixture.started(); peer.respond(); peer.send(Data([1]))
            if cancellation { operation.cancel() }
            await #expect(throws: cancellation ? AntigravityArchiveError.cancelled : .timedOut) { try await operation.value }
            try await fixture.stopped()
            #expect(fixture.startCount == 1 && fixture.stopCount == 1)
            #expect(!FileManager.default.fileExists(atPath: scratch.archive.path))
        }
    }

    @Test func alreadyCancelledWorkDoesNotCreateAnArchiveOrRequest() async throws {
        let fixture = AntigravityArchiveHTTPFixture(); defer { fixture.remove() }
        let scratch = try AntigravityDownloadScratch(); defer { scratch.remove() }
        let release = try fixture.release(Data([1]))
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await fixture.download(release, to: scratch.archive)
        }
        await #expect(throws: AntigravityArchiveError.cancelled) { try await operation.value }
        #expect(fixture.startCount == 0 && !FileManager.default.fileExists(atPath: scratch.archive.path))
    }

    @Test func exclusiveCreationPreservesAnExistingFileAndSymlinkTarget() async throws {
        for symlink in [false, true] {
            let fixture = AntigravityArchiveHTTPFixture(); defer { fixture.remove() }
            let scratch = try AntigravityDownloadScratch(); defer { scratch.remove() }
            if symlink { try FileManager.default.createSymbolicLink(at: scratch.archive, withDestinationURL: scratch.sentinel) }
            else { try Data("existing".utf8).write(to: scratch.archive) }
            let release = try fixture.release(Data([1]))
            await #expect(throws: AntigravityArchiveError.io) { try await fixture.download(release, to: scratch.archive) }
            #expect(fixture.startCount == 0)
            #expect(try Data(contentsOf: scratch.sentinel) == Data("retain".utf8))
            if !symlink { #expect(try Data(contentsOf: scratch.archive) == Data("existing".utf8)) }
        }
    }

    @Test func replacementDuringStreamingIsDetectedAndForeignReplacementIsRetained() async throws {
        let fixture = AntigravityArchiveHTTPFixture(); defer { fixture.remove() }
        let scratch = try AntigravityDownloadScratch(); defer { scratch.remove() }
        let release = try fixture.release(Data([1, 2, 3]))
        let operation = Task { try await fixture.download(release, to: scratch.archive) }
        let peer = try await fixture.started(); peer.respond(); peer.send(Data([1]))
        try await fixture.wait {
            var node = stat(); return lstat(scratch.archive.path, &node) == 0 && node.st_size == 1
        }
        try FileManager.default.removeItem(at: scratch.archive)
        try Data("foreign".utf8).write(to: scratch.archive)
        peer.send(Data([2])); peer.finish()
        await #expect(throws: AntigravityArchiveError.invalidDestination) { try await operation.value }
        #expect(try Data(contentsOf: scratch.archive) == Data("foreign".utf8))
    }
}

private final class AntigravityDownloadProgress: @unchecked Sendable {
    private let lock = NSLock(); private var storage: [Int64] = []
    func append(_ value: Int64) { lock.withLock { storage.append(value) } }
    var values: [Int64] { lock.withLock { storage } }
}
private struct AntigravityDownloadScratch: Sendable {
    let root: URL
    var archive: URL { root.appendingPathComponent("release.zip") }
    var sentinel: URL { root.appendingPathComponent("sentinel") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-archive-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("retain".utf8).write(to: sentinel)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
private enum AntigravityDownloadFixtureError: Error { case deadline }
private final class AntigravityArchiveHTTPFixture: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: AntigravityArchiveHTTPFixture] = [:]
    private let lock = NSLock(); private var channels: [AntigravityArchiveHTTPProtocol] = []; private var stops = 0
    let host = "archive-\(UUID().uuidString.lowercased()).invalid"
    init() { Self.registryLock.withLock { Self.registry[host] = self } }
    func remove() {
        _ = Self.registryLock.withLock { Self.registry.removeValue(forKey: host) }
        lock.withLock { channels.removeAll() }
    }
    static func find(_ host: String?) -> AntigravityArchiveHTTPFixture? { registryLock.withLock { host.flatMap { registry[$0] } } }
    var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AntigravityArchiveHTTPProtocol.self]; return config
    }
    var startCount: Int { lock.withLock { channels.count } }
    var stopCount: Int { lock.withLock { stops } }
    func started() async throws -> AntigravityArchiveHTTPProtocol {
        try await wait { self.startCount > 0 }; return lock.withLock { channels[0] }
    }
    func stopped() async throws { try await wait { self.stopCount == 1 } }
    func wait(_ predicate: @Sendable () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw AntigravityDownloadFixtureError.deadline
    }
    func didStart(_ channel: AntigravityArchiveHTTPProtocol) { lock.withLock { channels.append(channel) } }
    func didStop() { lock.withLock { stops += 1 } }
    func release(_ bytes: Data) throws -> AntigravityManagedRelease {
        try .init(version: "synthetic", platform: "darwin", architecture: "arm64", url: URL(string: "https://\(host)/pinned.zip")!, archiveBytes: Int64(bytes.count),
                  sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), serverName: "agy_acp_server.par", serverBytes: 1,
                  harnessName: "localharness_external", harnessBytes: 1)
    }
    func download(_ release: AntigravityManagedRelease, to destination: URL, deadline: Duration = .seconds(3)) async throws {
        try await AntigravityArchiveDownloader.download(release: release, to: destination, progress: { _ in }, configuration: configuration, deadline: deadline)
    }
}
private final class AntigravityArchiveHTTPProtocol: URLProtocol, @unchecked Sendable {
    private let fixtureLock = NSRecursiveLock(); private var stopped = false
    private var owner: AntigravityArchiveHTTPFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = AntigravityArchiveHTTPFixture.find(request.url?.host) else { fail(URLError(.unsupportedURL)); return }
        fixtureLock.withLock { owner = fixture }; fixture.didStart(self)
    }
    override func stopLoading() {
        fixtureLock.withLock { guard !stopped else { return }; stopped = true; owner?.didStop() }
    }
    func respond(status: Int = 200, headers: [String: String] = [:]) {
        fixtureLock.withLock {
            guard !stopped, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers.merging(["Content-Type": "application/zip"]) { old, _ in old }) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
    }
    func send(_ bytes: Data) { fixtureLock.withLock { if !stopped { client?.urlProtocol(self, didLoad: bytes) } } }
    func finish() { fixtureLock.withLock { if !stopped { client?.urlProtocolDidFinishLoading(self) } } }
    func fail(_ error: Error) { fixtureLock.withLock { if !stopped { client?.urlProtocol(self, didFailWithError: error) } } }
    func redirect(to destination: URL) {
        fixtureLock.withLock {
            guard !stopped, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString]) else { return }
            var redirected = request; redirected.url = destination
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
        }
    }
}
