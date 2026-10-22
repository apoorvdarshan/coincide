import CryptoKit
import Foundation
import Testing
@testable import CoincideCore

@Suite struct CodexArchiveDownloaderTests {
    @Test func officialAssetRedirectRebuildsAnUnauthenticatedRequestAndVerifiesBytes() async throws {
        let fixture = try CodexArchiveHTTPFixture(); defer { fixture.remove() }
        let bytes = Data("synthetic gzip archive".utf8), release = try fixture.release(bytes)
        let configuration = fixture.configuration
        configuration.httpAdditionalHeaders = ["Cookie": "private-cookie", "Authorization": "private-credential"]
        let operation = Task { try await fixture.download(release, configuration: configuration) }
        let first = try await fixture.started(0)
        #expect(first.request.url == release.url)
        first.redirect(to: fixture.cdnURL, injectingHeaders: true)
        let cdn = try await fixture.started(1)
        #expect(cdn.request.httpMethod == "GET")
        #expect(cdn.request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(cdn.request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(cdn.request.value(forHTTPHeaderField: "X-Private") == nil)
        #expect(!cdn.request.httpShouldHandleCookies)
        cdn.respond(); for byte in bytes { cdn.send(Data([byte])) }; cdn.finish()
        try await operation.value
        #expect(try Data(contentsOf: fixture.archive) == bytes)
        #expect(fixture.startCount == 2)
    }

    @Test func foreignInsecureCredentialAndUnexpectedGitHubRedirectsAreDenied() async throws {
        for destination in ["https://other.invalid/archive", "http://release-assets.githubusercontent.com/archive", "https://user:password@release-assets.githubusercontent.com/archive",
                            "https://release-assets.githubusercontent.com:444/archive", "https://github.com/other/repository", "https://github.com/openai/codex?token=private"] {
            let fixture = try CodexArchiveHTTPFixture(); defer { fixture.remove() }
            let release = try fixture.release(Data([1]))
            let operation = Task { try await fixture.download(release) }
            let first = try await fixture.started(0); first.redirect(to: URL(string: destination)!)
            await #expect(throws: CodexArchiveError.redirectDenied) { try await operation.value }
            #expect(fixture.startCount == 1 && !FileManager.default.fileExists(atPath: fixture.archive.path))
        }
    }

    @Test func redirectLimitIsExactAndNeverReplaysARequest() async throws {
        let fixture = try CodexArchiveHTTPFixture(); defer { fixture.remove() }
        let release = try fixture.release(Data([1]))
        let operation = Task { try await fixture.download(release) }
        for index in 0..<4 {
            let peer = try await fixture.started(index)
            peer.redirect(to: fixture.cdnURL.appendingPathComponent(String(index)))
        }
        await #expect(throws: CodexArchiveError.redirectDenied) { try await operation.value }
        #expect(fixture.startCount == 4 && !FileManager.default.fileExists(atPath: fixture.archive.path))
    }

    @Test func cancellationAfterRedirectStopsTheExactCurrentTaskAndRemovesItsPartial() async throws {
        let fixture = try CodexArchiveHTTPFixture(); defer { fixture.remove() }
        let release = try fixture.release(Data([1, 2, 3]))
        let operation = Task { try await fixture.download(release) }
        let first = try await fixture.started(0); first.redirect(to: fixture.cdnURL)
        let peer = try await fixture.started(1); peer.respond(); peer.send(Data([1]))
        operation.cancel()
        await #expect(throws: CodexArchiveError.cancelled) { try await operation.value }
        try await fixture.wait { peer.isStopped }
        #expect(fixture.startCount == 2 && !FileManager.default.fileExists(atPath: fixture.archive.path))
    }

    @Test func sharedEngineBoundsAndSafeErrorsRetainTheCodexPublicContract() async throws {
        for overflow in [false, true] {
            let fixture = try CodexArchiveHTTPFixture(); defer { fixture.remove() }
            let release = try fixture.release(Data([1, 2]))
            let operation = Task { try await fixture.download(release) }
            let peer = try await fixture.started(0)
            if overflow { peer.respond(); peer.send(Data([1, 2, 3])) }
            else { peer.fail(NSError(domain: "private-native-error", code: 7, userInfo: [NSLocalizedDescriptionKey: "private-body signed-query credential"])) }
            do { try await operation.value; Issue.record("The synthetic download unexpectedly succeeded.") }
            catch {
                #expect(error as? CodexArchiveError == (overflow ? .sizeMismatch : .network))
                #expect(!String(reflecting: error).contains("private"))
                #expect(!error.localizedDescription.contains("Antigravity"))
            }
            #expect(fixture.startCount == 1 && !FileManager.default.fileExists(atPath: fixture.archive.path))
        }
    }
}

private enum CodexArchiveHTTPFixtureError: Error { case deadline }
private final class CodexArchiveHTTPFixture: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: CodexArchiveHTTPFixture] = [:]
    private let lock = NSLock(); private var peers: [CodexArchiveHTTPProtocol] = []
    let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    let root: URL
    var archive: URL { root.appendingPathComponent("release.tar.gz") }
    var cdnURL: URL { URL(string: "https://release-assets.githubusercontent.com/\(token)/archive?sig=synthetic-only")! }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-codex-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        Self.registryLock.withLock { Self.registry[token] = self }
    }
    func remove() {
        _ = Self.registryLock.withLock { Self.registry.removeValue(forKey: token) }; lock.withLock { peers.removeAll() }
        try? FileManager.default.removeItem(at: root)
    }
    static func find(_ url: URL?) -> CodexArchiveHTTPFixture? {
        guard let path = url?.path else { return nil }; return registryLock.withLock { registry.first { path.contains($0.key) }?.value }
    }
    var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CodexArchiveHTTPProtocol.self]; return config
    }
    var startCount: Int { lock.withLock { peers.count } }
    func didStart(_ peer: CodexArchiveHTTPProtocol) { lock.withLock { peers.append(peer) } }
    func started(_ index: Int) async throws -> CodexArchiveHTTPProtocol {
        try await wait { self.startCount > index }; return lock.withLock { peers[index] }
    }
    func wait(_ predicate: @Sendable () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }; throw CodexArchiveHTTPFixtureError.deadline
    }
    func release(_ bytes: Data) throws -> CodexManagedRelease {
        let version = "0.156.1-test." + token, target = "aarch64-apple-darwin"
        return try .init(version: version, target: target,
                         url: URL(string: "https://github.com/openai/codex/releases/download/rust-v\(version)/codex-package-\(target).tar.gz")!, archiveBytes: Int64(bytes.count),
                         sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    func download(_ release: CodexManagedRelease, configuration: URLSessionConfiguration? = nil) async throws {
        try await CodexArchiveDownloader.download(release: release, to: archive, progress: { _ in }, configuration: configuration ?? self.configuration, deadline: .seconds(3))
    }
}
private final class CodexArchiveHTTPProtocol: URLProtocol, @unchecked Sendable {
    private let fixtureLock = NSRecursiveLock(); private var stopped = false
    private var owner: CodexArchiveHTTPFixture?
    var isStopped: Bool { fixtureLock.withLock { stopped } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = CodexArchiveHTTPFixture.find(request.url) else { fail(URLError(.unsupportedURL)); return }
        fixtureLock.withLock { owner = fixture }; fixture.didStart(self)
    }
    override func stopLoading() { fixtureLock.withLock { stopped = true } }
    func respond() {
        fixtureLock.withLock {
            guard !stopped, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
    }
    func send(_ bytes: Data) { fixtureLock.withLock { if !stopped { client?.urlProtocol(self, didLoad: bytes) } } }
    func finish() { fixtureLock.withLock { if !stopped { client?.urlProtocolDidFinishLoading(self) } } }
    func fail(_ error: Error) { fixtureLock.withLock { if !stopped { client?.urlProtocol(self, didFailWithError: error) } } }
    func redirect(to destination: URL, injectingHeaders: Bool = false) {
        fixtureLock.withLock {
            guard !stopped, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString]) else { return }
            var next = request; next.url = destination
            if injectingHeaders { next.httpMethod = "POST"; next.setValue("private", forHTTPHeaderField: "Authorization"); next.setValue("private", forHTTPHeaderField: "Cookie"); next.setValue("private", forHTTPHeaderField: "X-Private") }
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        }
    }
}
