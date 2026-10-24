import Darwin
import Foundation

extension ProviderIntegrationCatalog {
    /// Read the private import index, including independent copies whose original
    /// provider files were removed. scan() additionally refreshes linked states.
    public static func libraryItems(libraryRoot: URL = defaultLibraryRoot) throws -> [ProviderIntegrationItem] {
        guard try IntegrationLibrary.directory(libraryRoot, create: false) else { return [] }
        var result: [ProviderIntegrationItem] = []
        for name in try ClaudeSkillFiles.directory(libraryRoot.path) where !name.hasPrefix(".") {
            guard IntegrationLibrary.validID(name), result.count < 10_000 else { throw IntegrationLibrary.failure() }
            let root = libraryRoot.appendingPathComponent(name, isDirectory: true)
            _ = try IntegrationLibrary.directory(root, create: false)
            guard var item = try IntegrationLibrary.record(root), item.id == name else { throw IntegrationLibrary.failure() }
            if item.importMode == .copied {
                let file = try IntegrationLibrary.copiedPath(item, root: root)
                item.available = ClaudeSkillFiles.exists(file.path)
            } else { item.available = ClaudeSkillFiles.exists(item.sourcePath) }
            result.append(item)
        }
        return result
    }

    /// Skills and saved commands become private independent copies. Configuration
    /// integrations are provenance links only: the provider still loads its own
    /// original settings, permissions, hooks and credentials at runtime.
    @discardableResult
    public static func importItem(_ item: ProviderIntegrationItem,
                                  libraryRoot: URL = defaultLibraryRoot) throws -> ProviderIntegrationItem {
        try item.validate()
        guard item.available else { throw CoincideError("This integration is unavailable. Refresh its provider source first.") }
        _ = try IntegrationLibrary.directory(libraryRoot, create: true)
        let destination = libraryRoot.appendingPathComponent(item.id, isDirectory: true)
        if try IntegrationLibrary.directory(destination, create: false), let existing = try IntegrationLibrary.record(destination) {
            guard existing.id == item.id else { throw IntegrationLibrary.failure() }
            return existing
        }
        let staging = libraryRoot.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        _ = try IntegrationLibrary.directory(staging, create: true)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: staging) } }
        var imported = item
        if item.kind == .skills || item.kind == .commands {
            let source = URL(fileURLWithPath: item.sourcePath).resolvingSymlinksInPath()
            guard source.pathExtension.lowercased() == "md",
                  item.kind != .skills || source.lastPathComponent == "SKILL.md",
                  try ClaudeSkillFiles.read(source.path, maximum: 1_048_576) != nil else {
                throw CoincideError("The integration instructions could not be copied. Refresh the source and try again.")
            }
            let sourceRoot = source.deletingLastPathComponent()
            let content = staging.appendingPathComponent("content", isDirectory: true)
            var copier = IntegrationLibrary.Copier(sourceRoot: sourceRoot)
            try copier.copy(sourceRoot, to: content, depth: 0)
            imported.importMode = .copied
            imported.libraryPath = destination.appendingPathComponent("content", isDirectory: true).appendingPathComponent(source.lastPathComponent).path
        } else {
            guard ClaudeSkillFiles.exists(item.sourcePath) else { throw CoincideError("The original provider configuration is unavailable.") }
            imported.importMode = .linked
            imported.libraryPath = nil
        }
        imported.available = true
        try IntegrationLibrary.write(try JSONEncoder().encode(imported), to: staging.appendingPathComponent("entry.json"))
        do { try FileManager.default.moveItem(at: staging, to: destination) }
        catch { throw IntegrationLibrary.failure() }
        committed = true
        return imported
    }

    /// Remove only Coincide's imported entry and its private asset copy. Original
    /// CLI files, installed plugins and provider configuration are never touched.
    public static func removeImport(id: String, libraryRoot: URL = defaultLibraryRoot) throws {
        guard IntegrationLibrary.validID(id) else { throw IntegrationLibrary.failure() }
        guard try IntegrationLibrary.directory(libraryRoot, create: false) else { return }
        let directory = libraryRoot.appendingPathComponent(id, isDirectory: true)
        guard try IntegrationLibrary.directory(directory, create: false) else { return }
        guard let item = try IntegrationLibrary.record(directory), item.id == id else { throw IntegrationLibrary.failure() }
        do { try FileManager.default.removeItem(at: directory) } catch { throw IntegrationLibrary.failure() }
    }

    /// Returns an explicit draft instruction, never executes it. Relative assets
    /// remain beside the copied instruction file. Unlike a slash-command token,
    /// this works after switching providers without modifying their home folders.
    public static func invocationText(for item: ProviderIntegrationItem,
                                      libraryRoot: URL = defaultLibraryRoot) throws -> String {
        try item.validate()
        guard item.kind == .skills || item.kind == .commands else {
            throw CoincideError("This integration is loaded from its provider configuration; it is not a chat command.")
        }
        guard try IntegrationLibrary.directory(libraryRoot, create: false) else { throw CoincideError("Import these instructions before using them in a Coincide conversation.") }
        let root = libraryRoot.appendingPathComponent(item.id, isDirectory: true)
        guard try IntegrationLibrary.directory(root, create: false), let stored = try IntegrationLibrary.record(root), stored.id == item.id,
              stored.importMode == .copied else { throw CoincideError("Import these instructions before using them in a Coincide conversation.") }
        let file = try IntegrationLibrary.copiedPath(stored, root: root)
        guard try ClaudeSkillFiles.read(file.path, maximum: 1_048_576) != nil else { throw CoincideError("The imported instructions are missing. Remove and import this entry again.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let quoted = String(decoding: try encoder.encode(file.path), as: UTF8.self)
        let assetRoot = String(decoding: try encoder.encode(file.deletingLastPathComponent().path), as: UTF8.self)
        return "Use the \(item.kind == .skills ? "skill" : "saved command") instructions at \(quoted). Read that file first and resolve relative supporting resources from \(assetRoot)."
    }
}

private enum IntegrationLibrary {
    static func failure() -> CoincideError { .init("The private integration library could not be accessed safely. Check its location and permissions.") }
    static func validID(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isASCII && ("0123456789abcdef".contains($0)) } }

    @discardableResult
    static func directory(_ url: URL, create: Bool) throws -> Bool {
        guard url.isFileURL, url.path.hasPrefix("/"), url.path != "/" else { throw failure() }
        // Foundation may return the original URL when its final component does
        // not exist. Check each ancestor independently before creating anything
        // so a missing child cannot hide a redirected, existing parent.
        var ancestor = url
        while ancestor.path != "/" {
            guard ancestor.standardizedFileURL.path == ancestor.resolvingSymlinksInPath().standardizedFileURL.path else { throw failure() }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { throw failure() }
            ancestor = parent
        }
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw failure() }
            guard create else { return false }
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw failure() }
            guard lstat(url.path, &info) == 0 else { throw failure() }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw failure() }
        // Ancestor symlinks could redirect a nominally private library elsewhere.
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { throw failure() }
        return true
    }

    static func write(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw failure() }
        defer { close(descriptor) }
        var offset = 0
        try data.withUnsafeBytes { buffer in
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure() }; offset += count
            }
        }
    }

    static func record(_ root: URL) throws -> ProviderIntegrationItem? {
        let path = root.appendingPathComponent("entry.json").path
        var info = stat()
        guard lstat(path, &info) == 0 else { if errno == ENOENT { return nil }; throw failure() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw failure() }
        guard let data = try ClaudeSkillFiles.read(path, maximum: 32_768) else { return nil }
        let item: ProviderIntegrationItem
        do { item = try JSONDecoder().decode(ProviderIntegrationItem.self, from: data); try item.validate() }
        catch { throw failure() }
        guard item.id == root.lastPathComponent, item.importMode != nil,
              item.importMode == .copied ? (item.kind == .skills || item.kind == .commands) : (item.libraryPath == nil) else { throw failure() }
        return item
    }

    static func copiedPath(_ item: ProviderIntegrationItem, root: URL) throws -> URL {
        guard let path = item.libraryPath else { throw failure() }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let content = root.appendingPathComponent("content", isDirectory: true).standardizedFileURL
        guard try directory(content, create: false), url.path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
              ClaudeSkillFiles.inside(url.path, root: content.path), url.pathExtension.lowercased() == "md" else { throw failure() }
        return url
    }

    struct Copier {
        let sourceRoot: URL
        var bytes = 0
        var entries = 0
        var seenDirectories = Set<String>()
        mutating func copy(_ source: URL, to destination: URL, depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 12, entries < 1_024 else { throw CoincideError("The integration asset directory exceeds the import limits.") }
            entries += 1
            let physical = source.resolvingSymlinksInPath()
            guard ClaudeSkillFiles.inside(physical.path, root: sourceRoot.path) else {
                throw CoincideError("The integration contains a link outside its asset directory. Import a self-contained copy instead.")
            }
            var info = stat()
            guard stat(physical.path, &info) == 0, info.st_uid == getuid() || info.st_uid == 0 else { throw failure() }
            if info.st_mode & S_IFMT == S_IFDIR {
                guard seenDirectories.insert(physical.path).inserted else { throw CoincideError("The integration contains a repeated directory link.") }
                _ = try directory(destination, create: true)
                for name in try ClaudeSkillFiles.directory(physical.path) {
                    if [".git", ".DS_Store", "__pycache__", "node_modules", ".build"].contains(name) { continue }
                    if credentialFilename(name) { throw CoincideError("The integration asset directory contains a credential file. Create a clean asset copy before importing.") }
                    try copy(physical.appendingPathComponent(name), to: destination.appendingPathComponent(name), depth: depth + 1)
                }
            } else {
                // A hard link can expose a private file from outside this
                // asset directory without any symlink appearing in its path.
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                      let data = try ClaudeSkillFiles.read(physical.path, maximum: 4_194_304) else { throw failure() }
                bytes += data.count
                guard bytes <= 33_554_432 else { throw CoincideError("The integration asset directory exceeds the 32 MB import limit.") }
                try write(data, to: destination)
                // Supporting scripts retain their executable bit only; files
                // never become group/world readable and are never auto-run.
                if info.st_mode & 0o100 != 0, chmod(destination.path, 0o700) != 0 { throw failure() }
            }
        }
        private func credentialFilename(_ name: String) -> Bool {
            let name = name.lowercased()
            return name == ".env" || name.hasPrefix(".env.") ||
                ["auth.json", "credentials.json", ".credentials.json", ".npmrc", ".netrc", "id_rsa", "id_ed25519", "credentials", "token", "tokens.json"].contains(name) ||
                [".p12", ".pfx", ".key", ".pem"].contains(where: name.hasSuffix)
        }
    }
}
