import Foundation

public enum CodexArchiveError: String, LocalizedError, Sendable, Equatable {
    case invalidRelease, invalidDestination, network, redirectDenied, responseRejected
    case sizeMismatch, checksumMismatch, archiveInvalid, io, cancelled, timedOut
    public var errorDescription: String? {
        switch self {
        case .invalidRelease: "The pinned Codex release is invalid."
        case .invalidDestination: "The owned Codex staging location is unavailable or changed."
        case .network: "The Codex download could not complete. Nothing was installed."
        case .redirectDenied: "The Codex download redirected to an unexpected location."
        case .responseRejected: "The Codex download returned an unexpected response."
        case .sizeMismatch: "The Codex archive did not match its pinned size."
        case .checksumMismatch: "The Codex archive failed its SHA-256 check."
        case .archiveInvalid: "The Codex archive contains invalid, unsafe or unexpected members."
        case .io: "The Codex staging files could not be written or verified."
        case .cancelled: "The Codex installation was cancelled."
        case .timedOut: "The Codex download exceeded its time limit."
        }
    }
    static func sanitized(_ error: any Error, fallback: Self) -> Self {
        if let error = error as? Self { return error }
        if let error = error as? PinnedArchiveError { return Self(rawValue: error.rawValue) ?? fallback }
        return error is CancellationError ? .cancelled : fallback
    }
}

public enum CodexArchiveDownloader {
    public static func download(release: CodexManagedRelease, to destination: URL,
                                progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await download(release: release, to: destination, progress: progress, configuration: nil, deadline: .seconds(45 * 60))
    }
    static func download(release: CodexManagedRelease, to destination: URL, progress: @escaping @Sendable (Int64) -> Void,
                         configuration: URLSessionConfiguration?, deadline: Duration) async throws {
        do { try release.validate() } catch { throw CodexArchiveError.invalidRelease }
        let spec = PinnedArchiveDownload(url: release.url, archiveBytes: release.archiveBytes, sha256: release.sha256,
                                         accept: "application/octet-stream", redirects: .githubReleaseAsset)
        do { try await PinnedArchiveDownloader.download(spec: spec, to: destination, progress: progress, configuration: configuration, deadline: deadline) }
        catch { throw CodexArchiveError.sanitized(error, fallback: .network) }
    }
}
