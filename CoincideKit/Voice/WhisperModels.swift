import CryptoKit
import Foundation
import Observation

/// A Whisper model the user can download for dictation on this Mac: Argmax's Core ML conversions for WhisperKit
/// (huggingface.co/argmaxinc/whisperkit-coreml) and OpenAI's tokenizer, each pinned to a commit, so the files and their
/// checksums never change under the app. Nothing is bundled; nothing downloads until the user asks.
public struct WhisperModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    /// The folder the model is kept in, named as WhisperKit names it.
    public let folder: String
    public let sources: [ModelSource]
    /// The size of every file together, from the pinned manifests. A download whose manifest disagrees stops.
    public let expectedBytes: Int64

    public nonisolated static let defaultID = "base"

    /// Sizes checked against the Hugging Face API at the pinned commits (October 2026).
    public nonisolated static let catalog: [WhisperModel] = [
        WhisperModel(
            id: "tiny", name: "Tiny", detail: String(localized: "Fastest, least accurate"), folder: "openai_whisper-tiny",
            tokenizer: .openAITokenizer("openai/whisper-tiny", revision: "169d4a4341b33bc18d8881c4b69c2e104e1cc0af"),
            expectedBytes: 79_398_546),
        WhisperModel(
            id: "base", name: "Base", detail: String(localized: "Fast, good for clear speech"), folder: "openai_whisper-base",
            tokenizer: .openAITokenizer("openai/whisper-base", revision: "e37978b90ca9030d5170a5c07aadb050351a65bb"),
            expectedBytes: 149_482_602),
        WhisperModel(
            id: "small", name: "Small", detail: String(localized: "Slower, more accurate"), folder: "openai_whisper-small",
            tokenizer: .openAITokenizer("openai/whisper-small", revision: "973afd24965f72e36ca33b3055d56a652f456b4d"),
            expectedBytes: 489_250_614),
        WhisperModel(
            id: "large-v3-turbo", name: "Large v3 Turbo",
            detail: String(localized: "Most accurate; best on Apple silicon with 16 GB or more"),
            folder: "openai_whisper-large-v3-v20240930_turbo_632MB",
            tokenizer: .openAITokenizer("openai/whisper-large-v3", revision: "06f233fe06e710322aca913c1bc4249a0d71fce1"),
            expectedBytes: 648_432_373),
    ]

    /// Argmax's model repository, at the commit the catalog was checked against.
    nonisolated static let coreMLRepo = "argmaxinc/whisperkit-coreml"
    nonisolated static let coreMLRevision = "0f63a7800b00dd0226abd051b906c246e1907482"

    nonisolated init(
        id: String, name: String, detail: String, folder: String, tokenizer: ModelSource, expectedBytes: Int64
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.folder = folder
        sources = [ModelSource(repo: Self.coreMLRepo, revision: Self.coreMLRevision, prefix: folder), tokenizer]
        self.expectedBytes = expectedBytes
    }

    public nonisolated init(id: String, name: String, detail: String, folder: String, sources: [ModelSource], expectedBytes: Int64) {
        self.id = id
        self.name = name
        self.detail = detail
        self.folder = folder
        self.sources = sources
        self.expectedBytes = expectedBytes
    }

    public nonisolated static func model(id: String) -> WhisperModel? { catalog.first { $0.id == id } }

    /// "149 MB".
    public nonisolated var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file)
    }
}

/// Files of one Hugging Face repository at one commit: those under `prefix`, or just `files` at its root.
public struct ModelSource: Hashable, Sendable {
    public let repo: String
    public let revision: String
    /// A folder of the repository whose files are taken, kept as they are below it; "" with `files`.
    public let prefix: String
    /// Only these files, at the repository's root.
    public let files: [String]?

    public nonisolated init(repo: String, revision: String, prefix: String = "", files: [String]? = nil) {
        self.repo = repo
        self.revision = revision
        self.prefix = prefix
        self.files = files
    }

    /// The tokenizer files WhisperKit reads from the model's folder, so it never fetches them itself.
    nonisolated static func openAITokenizer(_ repo: String, revision: String) -> ModelSource {
        ModelSource(repo: repo, revision: revision, files: ["tokenizer.json", "tokenizer_config.json"])
    }
}

/// One file to download, where it goes in the model's folder, and how to check it.
public struct ModelFile: Hashable, Sendable {
    public let path: String
    public let url: URL
    public let size: Int64
    public let checksum: ModelChecksum

    public nonisolated init(path: String, url: URL, size: Int64, checksum: ModelChecksum) {
        self.path = path
        self.url = url
        self.size = size
        self.checksum = checksum
    }
}

public enum ModelChecksum: Hashable, Sendable {
    /// Large (Git LFS) files: the SHA-256 of the contents.
    case sha256(String)
    /// Small files kept in Git: the SHA-1 of the Git blob ("blob <size>\0" and the contents).
    case gitBlobSHA1(String)

    /// Whether `url`'s contents match. Reads in pieces, so large models never sit in memory.
    public nonisolated func matches(fileAt url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        switch self {
        case .sha256(let expected):
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(data: chunk) }
            return Self.hex(hash.finalize()) == expected.lowercased()
        case .gitBlobSHA1(let expected):
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            var hash = Insecure.SHA1()
            hash.update(data: Data("blob \(size)\0".utf8))
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(data: chunk) }
            return Self.hex(hash.finalize()) == expected.lowercased()
        }
    }

    private nonisolated static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Lists and fetches model files; Hugging Face in the app, a stub in tests.
public protocol ModelDownloading: Sendable {
    /// The files of `source` at its pinned commit, with their sizes and checksums.
    func manifest(for source: ModelSource) async throws -> [ModelFile]
    /// Downloads `file` to `destination`, reporting the bytes received so far.
    func download(_ file: ModelFile, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
}

public enum WhisperModelError: LocalizedError, Equatable, Sendable {
    case manifestMismatch
    case checksumMismatch(String)
    case sizeMismatch(String)
    case failed(String)

    public nonisolated var errorDescription: String? {
        switch self {
        case .manifestMismatch: String(localized: "The model’s files aren’t what Coincide expected, so it wasn’t installed.")
        case .checksumMismatch(let file): String(localized: "\(file) didn’t match its checksum, so the model wasn’t installed.")
        case .sizeMismatch(let file): String(localized: "\(file) wasn’t the expected size, so the model wasn’t installed.")
        case .failed(let message): message
        }
    }
}

/// Downloads from Hugging Face over HTTPS: the file list from its API at the pinned commit, files from `resolve/`.
public struct HuggingFaceDownloader: ModelDownloading {
    let session: URLSession

    public nonisolated init(session: URLSession = .shared) {
        self.session = session
    }

    public nonisolated func manifest(for source: ModelSource) async throws -> [ModelFile] {
        var components = URLComponents(string: "https://huggingface.co/api/models/\(source.repo)/tree/\(source.revision)")!
        if !source.prefix.isEmpty {
            components.path += "/" + source.prefix
            components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        }
        let (data, response) = try await session.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw WhisperModelError.failed(String(localized: "Couldn’t read the model’s file list from Hugging Face.")) }
        return try Self.files(in: entries, source: source)
    }

    /// The files of a Hugging Face tree listing that `source` takes.
    nonisolated static func files(in entries: [[String: Any]], source: ModelSource) throws -> [ModelFile] {
        var files: [ModelFile] = []
        for entry in entries where entry["type"] as? String == "file" {
            guard let path = entry["path"] as? String, let size = (entry["size"] as? NSNumber)?.int64Value else { continue }
            let relative: String
            if let only = source.files {
                guard only.contains(path) else { continue }
                relative = path
            } else {
                guard path.hasPrefix(source.prefix + "/") else { continue }
                relative = String(path.dropFirst(source.prefix.count + 1))
            }
            // A path that climbs out of the model's folder is never written.
            guard !relative.isEmpty, !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }), !relative.hasPrefix("/")
            else { throw WhisperModelError.manifestMismatch }
            let checksum: ModelChecksum
            if let lfs = entry["lfs"] as? [String: Any], let oid = lfs["oid"] as? String {
                checksum = .sha256(oid)
            } else if let oid = entry["oid"] as? String {
                checksum = .gitBlobSHA1(oid)
            } else {
                throw WhisperModelError.manifestMismatch
            }
            let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            guard let url = URL(string: "https://huggingface.co/\(source.repo)/resolve/\(source.revision)/\(escaped)") else { continue }
            files.append(ModelFile(path: relative, url: url, size: size, checksum: checksum))
        }
        if let only = source.files, Set(files.map(\.path)) != Set(only) { throw WhisperModelError.manifestMismatch }
        return files
    }

    public nonisolated func download(_ file: ModelFile, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let (location, response) = try await session.download(for: URLRequest(url: file.url), delegate: DownloadProgress(progress))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: location)
            throw WhisperModelError.failed(String(localized: "Hugging Face didn’t send \(file.path)."))
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: location, to: destination)
        progress(file.size)
    }
}

/// Reports a download's bytes as they arrive.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let report: @Sendable (Int64) -> Void

    nonisolated init(_ report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        report(totalBytesWritten)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// Where a Whisper model stands on this Mac.
public enum WhisperModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(received: Int64, total: Int64)
    case verifying
    case downloaded
    case failed(String)

    public nonisolated var fraction: Double? {
        if case .downloading(let received, let total) = self, total > 0 { return min(1, Double(received) / Double(total)) }
        return nil
    }
}

/// The Whisper models on this Mac, in `<data folder>/Voice/Whisper/<model folder>` (the Debug build's data folder is
/// its own). A download goes to a staging folder, every file is checked against its pinned size and checksum, and only
/// then does the folder take the model's name, so a half-downloaded or altered model is never used.
@MainActor
@Observable
public final class WhisperModelManager {
    public private(set) var states: [String: WhisperModelState] = [:]

    @ObservationIgnored public let directory: URL
    @ObservationIgnored private let downloader: any ModelDownloading
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let catalog: [WhisperModel]

    public init(directory: URL, downloader: any ModelDownloading = HuggingFaceDownloader(), catalog: [WhisperModel] = WhisperModel.catalog) {
        self.directory = directory
        self.downloader = downloader
        self.catalog = catalog
        for model in catalog { states[model.id] = isInstalled(model) ? .downloaded : .notDownloaded }
    }

    public func state(_ model: WhisperModel) -> WhisperModelState { states[model.id] ?? .notDownloaded }

    /// The installed model's folder, for WhisperKit; nil until it's downloaded.
    public func folder(of model: WhisperModel) -> URL? {
        isInstalled(model) ? installedFolder(model) : nil
    }

    public func download(_ model: WhisperModel) {
        guard tasks[model.id] == nil, state(model) != .downloaded else { return }
        states[model.id] = .downloading(received: 0, total: model.expectedBytes)
        tasks[model.id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await install(model)
                states[model.id] = .downloaded
            } catch is CancellationError {
                states[model.id] = .notDownloaded
            } catch {
                states[model.id] = .failed(error.localizedDescription)
            }
            tasks[model.id] = nil
        }
    }

    public func cancel(_ model: WhisperModel) {
        tasks[model.id]?.cancel()
    }

    /// Waits for a download in progress to end, for tests.
    public func waitForDownload(_ model: WhisperModel) async {
        await tasks[model.id]?.value
    }

    public func delete(_ model: WhisperModel) {
        cancel(model)
        try? FileManager.default.removeItem(at: installedFolder(model))
        try? FileManager.default.removeItem(at: stagingFolder(model))
        states[model.id] = .notDownloaded
    }

    // MARK: Installing

    private func install(_ model: WhisperModel) async throws {
        let staging = stagingFolder(model)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: staging)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        var files: [ModelFile] = []
        for source in model.sources { files += try await downloader.manifest(for: source) }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total == model.expectedBytes, !files.isEmpty, Set(files.map(\.path)).count == files.count else {
            throw WhisperModelError.manifestMismatch
        }

        var done: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(file.path)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = done
            let id = model.id
            try await downloader.download(file, to: destination) { [weak self] received in
                Task { @MainActor in
                    guard let self, case .downloading = self.states[id] else { return }
                    self.states[id] = .downloading(received: base + min(received, file.size), total: total)
                }
            }
            try Task.checkCancellation()
            let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
            guard size == file.size else { throw WhisperModelError.sizeMismatch(file.path) }
            done += file.size
            states[model.id] = .downloading(received: done, total: total)
        }

        states[model.id] = .verifying
        let checks = files.map { ($0, staging.appendingPathComponent($0.path)) }
        try await Task.detached(priority: .utility) {
            for (file, url) in checks {
                try Task.checkCancellation()
                guard try file.checksum.matches(fileAt: url) else { throw WhisperModelError.checksumMismatch(file.path) }
            }
        }.value
        try Task.checkCancellation()

        let installed = installedFolder(model)
        try? fileManager.removeItem(at: installed)
        try fileManager.moveItem(at: staging, to: installed)
        try Data(model.id.utf8).write(to: installed.appendingPathComponent(Self.marker))
    }

    /// Written last, so a folder without it is an unfinished install.
    nonisolated static let marker = ".coincide-verified"

    private func isInstalled(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: installedFolder(model).appendingPathComponent(Self.marker).path)
    }

    private func installedFolder(_ model: WhisperModel) -> URL {
        directory.appendingPathComponent(model.folder, isDirectory: true)
    }

    private func stagingFolder(_ model: WhisperModel) -> URL {
        directory.appendingPathComponent(".download-" + model.folder, isDirectory: true)
    }
}
