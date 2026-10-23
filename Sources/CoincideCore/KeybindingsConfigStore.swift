import Darwin
import CryptoKit
import Foundation

/// Exact on-disk revision captured when a shortcut editor is opened. A nil
/// digest represents an absent file, distinct from no requested comparison.
public struct KeybindingsConfigRevision: Equatable, Sendable {
    public let digest: String?
    public init(digest: String? = nil) { self.digest = digest }
    fileprivate init(data: Data?) {
        digest = data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }
}

public struct KeybindingsConfigIssue: Hashable, Sendable {
    public enum Kind: String, Sendable { case malformedConfig = "keybindings.malformed-config", invalidEntry = "keybindings.invalid-entry" }
    public let kind: Kind
    /// Zero-based array position for an invalid entry.
    public let index: Int?
    public let message: String
    public init(kind: Kind, index: Int? = nil, message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind; self.index = index; self.message = trimmed.isEmpty ? "Invalid keybindings configuration." : trimmed
    }
    /// One line for the warning banner, such as "Entry 3: Unknown command “foo.bar”."
    public var summary: String { index.map { "Entry \($0 + 1): " + message } ?? message }
}

public struct KeybindingsConfigState: Equatable, Sendable {
    /// Defaults merged with the file, in precedence order (last wins).
    public var keybindings: [ResolvedKeybinding]
    public var issues: [KeybindingsConfigIssue]
    /// The file's valid entries as written.
    public var fileRules: [KeybindingRule]
    public var revision: KeybindingsConfigRevision
    public init(keybindings: [ResolvedKeybinding] = KeybindingDefaults.resolved, issues: [KeybindingsConfigIssue] = [], fileRules: [KeybindingRule] = [], revision: KeybindingsConfigRevision = .init()) {
        self.keybindings = keybindings; self.issues = issues; self.fileRules = fileRules; self.revision = revision
    }
}

/// Owns `keybindings.json` beside the workspace database, following T3's server
/// semantics: lenient JSON, per-entry issues, defaults when the file is malformed,
/// first-run defaults, startup backfill of missing commands and atomic writes.
public actor KeybindingsConfigStore {
    public static let maximumFileBytes = 1_048_576
    public nonisolated let fileURL: URL
    public nonisolated var migrationsURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("keybindings-migrations") }
    private let defaults: [KeybindingRule]
    private let defaultResolved: [ResolvedKeybinding]
    private let lateDefaults: [KeybindingDefaults.LateDefault]
    /// Startup decisions T3 logs as warnings; exposed for diagnostics and tests.
    public private(set) var warnings: [String] = []

    public init(fileURL: URL, defaults: [KeybindingRule] = KeybindingDefaults.rules, lateDefaults: [KeybindingDefaults.LateDefault] = KeybindingDefaults.late) {
        self.fileURL = fileURL; self.defaults = defaults; self.lateDefaults = lateDefaults
        defaultResolved = KeybindingResolver.compile(defaults)
    }

    /// Prepares the directory, writes or backfills defaults, then reads the result.
    /// A write failure still returns the current runtime state with defaults.
    public func start() -> KeybindingsConfigState {
        warnings.removeAll(keepingCapacity: true)
        do {
            try prepareDirectory()
            try syncDefaultsOnStartup()
        } catch { warnings.append("Keybindings defaults could not be written: \(error.localizedDescription)") }
        warnings = Array(warnings.suffix(64))
        return load()
    }

    /// The runtime view: invalid entries become issues; a malformed file yields defaults.
    public func load() -> KeybindingsConfigState {
        do { return state(data: try storage.read(fileURL.lastPathComponent, maximum: Self.maximumFileBytes)) }
        catch { return .init(keybindings: defaultResolved, issues: [.init(kind: .malformedConfig, message: "keybindings.json could not be safely read. The file was preserved.")]) }
    }
    private func state(data: Data?) -> KeybindingsConfigState {
        guard let data else { return .init(keybindings: defaultResolved) }
        let decoded = Self.decode(data)
        let compiled = KeybindingResolver.compile(decoded.rules)
        return .init(keybindings: KeybindingResolver.merge(compiled, defaults: defaultResolved), issues: decoded.issues, fileRules: decoded.rules, revision: .init(data: data))
    }

    /// T3 `syncDefaultKeybindingsOnStartup`. Missing commands are added before the
    /// user's rules so existing custom shortcuts keep priority; a default whose shortcut
    /// and condition are already used is skipped. Nothing is written while the file has issues.
    public func syncDefaultsOnStartup() throws {
        let applied = try appliedMigrations()
        let pendingLate = lateDefaults.filter { !applied.contains($0.id) }
        let original = try storage.read(fileURL.lastPathComponent, maximum: Self.maximumFileBytes)
        guard let original else {
            try write(defaults, expected: nil)
            if !pendingLate.isEmpty { try recordMigrations(applied.union(lateDefaults.map(\.id))) }
            return
        }
        let current = state(data: original)
        guard current.issues.isEmpty else {
            warnings.append("Skipped default keybinding backfill because keybindings.json has issues."); return
        }
        let custom = current.fileRules
        let existing = Set(custom.map(\.command))
        var missing: [KeybindingRule] = []
        for rule in defaults where !existing.contains(rule.command) {
            if let conflict = custom.first(where: { $0.shortcutContext != nil && $0.shortcutContext == rule.shortcutContext }) {
                warnings.append("Skipped default \(rule.command.rawValue) (\(rule.key)) because \(conflict.command.rawValue) uses the same shortcut and condition.")
                continue
            }
            missing.append(rule)
        }
        for late in pendingLate where custom.contains(where: { $0.isSame(as: late.alongside) }) && !custom.contains(where: { $0.shortcutContext == late.rule.shortcutContext }) {
            missing.append(late.rule)
        }
        let slots = max(0, KeybindingResolver.maxRules - custom.count)
        let appended = Array(missing.prefix(slots)), skipped = Array(missing.dropFirst(slots))
        if !skipped.isEmpty { warnings.append("Skipped \(skipped.count) default keybindings at the \(KeybindingResolver.maxRules)-rule limit.") }
        if !appended.isEmpty { try write(appended + custom, expected: original) }
        let settled = pendingLate.filter { late in !skipped.contains(late.rule) }
        if !settled.isEmpty { try recordMigrations(applied.union(settled.map(\.id))) }
    }

    /// Adds `rule`, replacing `replacing` (and any identical rule). Writes atomically,
    /// keeps the newest 256 rules and drops entries that cannot be decoded, like T3.
    @discardableResult
    public func upsert(_ rule: KeybindingRule, replacing: KeybindingRule? = nil, expectedRevision: KeybindingsConfigRevision? = nil) throws -> KeybindingsConfigState {
        try Self.validate(rule)
        let current = try writableRules(expectedRevision: expectedRevision)
        var next = current.rules.filter { !$0.isSame(as: rule) && !(replacing.map($0.isSame(as:)) ?? false) }
        next.append(rule)
        if next.count > KeybindingResolver.maxRules { next = Array(next.suffix(KeybindingResolver.maxRules)) }
        let written = try write(next, expected: current.data)
        return .init(keybindings: KeybindingResolver.merge(KeybindingResolver.compile(next), defaults: defaultResolved), fileRules: next, revision: .init(data: written))
    }

    @discardableResult
    public func remove(_ rule: KeybindingRule, expectedRevision: KeybindingsConfigRevision? = nil) throws -> KeybindingsConfigState {
        let current = try writableRules(expectedRevision: expectedRevision)
        let next = current.rules.filter { !$0.isSame(as: rule) }
        let written = try write(next, expected: current.data)
        return .init(keybindings: KeybindingResolver.merge(KeybindingResolver.compile(next), defaults: defaultResolved), fileRules: next, revision: .init(data: written))
    }

    private func writableRules(expectedRevision: KeybindingsConfigRevision?) throws -> (data: Data?, rules: [KeybindingRule]) {
        let original = try storage.read(fileURL.lastPathComponent, maximum: Self.maximumFileBytes)
        if let expectedRevision, expectedRevision != KeybindingsConfigRevision(data: original) {
            throw CoincideError("The shortcuts file changed. Reload it before saving this edit.")
        }
        guard let data = original else { return (nil, []) }
        let decoded = Self.decode(data)
        if decoded.issues.contains(where: { $0.kind == .malformedConfig }) {
            throw CoincideError("keybindings.json is not a JSON array. Fix or remove the file before changing shortcuts here.")
        }
        return (data, decoded.rules)
    }

    private var storage: KeybindingsPrivateFiles { .init(root: fileURL.deletingLastPathComponent()) }
    @discardableResult private func write(_ rules: [KeybindingRule], expected: Data?) throws -> Data {
        guard rules.count <= KeybindingResolver.maxRules else { throw CoincideError("Too many shortcut rules.") }
        let data = Self.encode(rules)
        try storage.write(data, name: fileURL.lastPathComponent, maximum: Self.maximumFileBytes, expected: expected)
        return data
    }
    /// The data root also holds the private workspace database; create it owner-only, as the database does.
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    private func appliedMigrations() throws -> Set<String> {
        guard let data = try storage.read(migrationsURL.lastPathComponent, maximum: 65_536) else { return [] }
        guard let text = String(data: data, encoding: .utf8) else { throw CoincideError("The shortcut migration file is invalid and was preserved.") }
        return Set(text.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }
    private func recordMigrations(_ ids: Set<String>) throws {
        let expected = try storage.read(migrationsURL.lastPathComponent, maximum: 65_536)
        try storage.write(Data((ids.sorted().joined(separator: "\n") + "\n").utf8), name: migrationsURL.lastPathComponent, maximum: 65_536, expected: expected)
    }

    // MARK: Pure decoding

    public static func validate(_ rule: KeybindingRule) throws {
        let shortcutText = rule.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shortcutText.isEmpty, shortcutText.utf16.count <= KeybindingShortcut.maxLength else { throw CoincideError("A shortcut needs 1 to \(KeybindingShortcut.maxLength) characters.") }
        guard rule.command.isKnown else { throw CoincideError("Unknown command “\(rule.command.rawValue.prefix(96))”.") }
        guard KeybindingShortcut(parsing: shortcutText) != nil else { throw CoincideError("“\(shortcutText)” is not a valid shortcut. Join modifiers and one key with +.") }
        if let when = rule.when {
            guard when.utf16.count <= KeybindingWhen.maxLength else { throw CoincideError("A condition can have at most \(KeybindingWhen.maxLength) characters.") }
            guard KeybindingWhen(parsing: when) != nil else { throw CoincideError("“\(when)” is not a valid condition. Use variables with !, &&, || and parentheses.") }
        }
    }

    public static func decode(_ data: Data) -> (rules: [KeybindingRule], issues: [KeybindingsConfigIssue]) {
        guard data.count <= maximumFileBytes, let text = String(data: data, encoding: .utf8) else {
            return ([], [.init(kind: .malformedConfig, message: "keybindings.json exceeds its size limit or is not UTF-8. The file was preserved.")])
        }
        let cleaned = stripLenientJSON(text)
        guard Self.hasBoundedJSONDepth(cleaned),
              let json = try? JSONSerialization.jsonObject(with: Data(cleaned.utf8), options: [.fragmentsAllowed]),
              let entries = json as? [Any] else {
            return ([], [.init(kind: .malformedConfig, message: "keybindings.json must contain a JSON array of rules. Using the default shortcuts.")])
        }
        guard entries.count <= 4_096 else {
            return ([], [.init(kind: .malformedConfig, message: "keybindings.json has too many entries. The file was preserved.")])
        }
        var rules: [KeybindingRule] = [], issues: [KeybindingsConfigIssue] = []
        for (index, entry) in entries.enumerated() {
            do { rules.append(try decodeEntry(entry)) }
            catch { issues.append(.init(kind: .invalidEntry, index: index, message: error.localizedDescription)) }
        }
        return (rules, issues)
    }

    private static func hasBoundedJSONDepth(_ text: String) -> Bool {
        var depth = 0, quoted = false, escaped = false
        for byte in text.utf8 {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 91 || byte == 123 { depth += 1; if depth > 32 { return false } }
            else if byte == 93 || byte == 125 { depth -= 1; if depth < 0 { return false } }
        }
        return !quoted && depth == 0
    }

    private static func decodeEntry(_ entry: Any) throws -> KeybindingRule {
        guard let object = entry as? [String: Any] else { throw CoincideError("Expected an object with “key” and “command”.") }
        guard let key = (object["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw CoincideError("“key” must be a non-empty string.")
        }
        guard let command = (object["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            throw CoincideError("“command” must be a non-empty string.")
        }
        var when: String?
        if let raw = object["when"], !(raw is NSNull) {
            guard let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                throw CoincideError("“when” must be a non-empty string.")
            }
            when = value
        }
        let rule = KeybindingRule(key: key, command: .init(command), when: when)
        try validate(rule)
        return rule
    }

    /// T3 `fromLenientJson`: comments outside strings become a space, then commas
    /// before a closing bracket are removed.
    public static func stripLenientJSON(_ text: String) -> String {
        func scan(_ scalars: [Unicode.Scalar], _ outside: (inout String.UnicodeScalarView, [Unicode.Scalar], inout Int) -> Void) -> [Unicode.Scalar] {
            var output = String.UnicodeScalarView(), index = 0
            while index < scalars.count {
                if scalars[index] == "\"" {
                    output.append(scalars[index]); index += 1
                    while index < scalars.count {
                        let inner = scalars[index]; output.append(inner); index += 1
                        if inner == "\\", index < scalars.count { output.append(scalars[index]); index += 1 }
                        else if inner == "\"" { break }
                    }
                } else { outside(&output, scalars, &index) }
            }
            return Array(output)
        }
        let uncommented = scan(Array(text.unicodeScalars)) { output, scalars, index in
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            if scalars[index] == "/", next == "/" {
                while index < scalars.count, scalars[index] != "\n" { index += 1 }
                output.append(" ")
            } else if scalars[index] == "/", next == "*" {
                index += 2
                while index < scalars.count, !(scalars[index] == "*" && index + 1 < scalars.count && scalars[index + 1] == "/") { index += 1 }
                index = min(scalars.count, index + 2); output.append(" ")
            } else { output.append(scalars[index]); index += 1 }
        }
        let cleaned = scan(uncommented) { output, scalars, index in
            if scalars[index] == "," {
                var lookahead = index + 1
                while lookahead < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[lookahead]) { lookahead += 1 }
                if lookahead < scalars.count, scalars[lookahead] == "}" || scalars[lookahead] == "]" { index += 1; return }
            }
            output.append(scalars[index]); index += 1
        }
        var result = String.UnicodeScalarView(); result.append(contentsOf: cleaned)
        return String(result)
    }

    /// One rule per line, in T3's `key`, `command`, `when` field order.
    public static func encode(_ rules: [KeybindingRule]) -> Data {
        func quoted(_ value: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }
        let lines = rules.map { rule in
            "  { \"key\": \(quoted(rule.key)), \"command\": \(quoted(rule.command.rawValue))" + (rule.when.map { ", \"when\": \(quoted($0))" } ?? "") + " }"
        }
        return Data(("[\n" + lines.joined(separator: ",\n") + (lines.isEmpty ? "" : "\n") + "]\n").utf8)
    }
}

/// Bounded, descriptor-relative settings I/O. The persistent lock serializes
/// cooperating app instances; the original bytes are rechecked before rename.
private struct KeybindingsPrivateFiles {
    let root: URL
    private func failure() -> CoincideError { .init("The shortcuts storage is unavailable or changed. Reload it before editing.") }
    func read(_ name: String, maximum: Int) throws -> Data? {
        try directory(create: false) { directory in
            guard let directory else { return nil }
            return try read(name, maximum: maximum, directory: directory)
        }
    }
    func write(_ data: Data, name: String, maximum: Int, expected: Data?) throws {
        guard data.count <= maximum else { throw failure() }
        try directory(create: true) { directory in
            guard let directory, try read(name, maximum: maximum, directory: directory) == expected else { throw failure() }
            let temporary = ".keybindings-" + UUID().uuidString
            let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw failure() }
            defer { Darwin.close(descriptor); _ = unlinkat(directory, temporary, 0) }
            var offset = 0
            while offset < data.count {
                let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure() }; offset += count
            }
            guard fsync(descriptor) == 0,
                  try read(name, maximum: maximum, directory: directory) == expected,
                  renameat(directory, temporary, directory, name) == 0,
                  fsync(directory) == 0 else { throw failure() }
        }
    }
    private func read(_ name: String, maximum: Int, directory: Int32) throws -> Data? {
        guard !name.isEmpty, name.utf8.count <= 160, !name.hasPrefix("."),
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }) else { throw failure() }
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw failure() }; defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, safe(before), before.st_size >= 0, before.st_size <= maximum else { throw failure() }
        var data = Data(count: Int(before.st_size)), offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw failure() }; offset += count
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, safe(after), before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw failure() }
        return data
    }
    private func safe(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1 && info.st_mode & 0o022 == 0
    }
    private func directory<T>(create: Bool, _ body: (Int32?) throws -> T) throws -> T {
        guard root.isFileURL, !root.path.contains("\0") else { throw failure() }
        if create {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT, !create { return try body(nil) }
        guard descriptor >= 0 else { throw failure() }; defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw failure() }
        let lock = openat(descriptor, ".keybindings.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw failure() }; defer { Darwin.close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, safe(lockInfo), lockInfo.st_mode & 0o077 == 0,
              flock(lock, LOCK_EX) == 0 else { throw failure() }
        defer { _ = flock(lock, LOCK_UN) }
        return try body(descriptor)
    }
}

/// Watches one file through its directory, so editors that save by atomic rename are
/// seen as well as in-place writes. Events coalesce, and only a changed file identity,
/// size or modification time is reported, so unrelated database writes stay quiet.
public final class KeybindingsFileWatcher: @unchecked Sendable {
    public let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let fileURL: URL
    private let debounce: DispatchTimeInterval
    private let queue = DispatchQueue(label: "Coincide.keybindings-watch", qos: .utility)
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var pending: DispatchWorkItem?
    private var fingerprint: [Int]?
    private var stopped = false

    public init(fileURL: URL, debounce: DispatchTimeInterval = .milliseconds(100)) {
        self.fileURL = fileURL; self.debounce = debounce
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        queue.sync {
            fingerprint = currentFingerprint()
            directorySource = source(path: fileURL.deletingLastPathComponent().path, mask: [.write, .rename, .delete, .link]) { [weak self] _ in
                self?.attachFile(); self?.schedule()
            }
            attachFile()
        }
    }
    deinit {
        pending?.cancel(); directorySource?.cancel(); fileSource?.cancel(); continuation.finish()
    }

    public func stop() {
        queue.async { [self] in
            guard !stopped else { return }; stopped = true
            pending?.cancel(); directorySource?.cancel(); fileSource?.cancel()
            directorySource = nil; fileSource = nil; continuation.finish()
        }
    }

    private func attachFile() {
        fileSource?.cancel(); fileSource = nil
        guard !stopped else { return }
        fileSource = source(path: fileURL.path, mask: [.write, .extend, .delete, .rename, .attrib]) { [weak self] events in
            if events.contains(.delete) || events.contains(.rename) { self?.attachFile() }
            self?.schedule()
        }
    }
    private func source(path: String, mask: DispatchSource.FileSystemEvent,
                        handler: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = open(path, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: queue)
        source.setEventHandler { [weak source] in handler(source?.data ?? []) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
    private func schedule() {
        guard !stopped else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            if self.fileSource == nil { self.attachFile() }
            let next = self.currentFingerprint()
            guard next != self.fingerprint else { return }
            self.fingerprint = next; self.continuation.yield()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
    private func currentFingerprint() -> [Int]? {
        var info = stat()
        guard lstat(fileURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return nil }
        return [Int(info.st_ino), Int(info.st_size), Int(info.st_mtimespec.tv_sec), Int(info.st_mtimespec.tv_nsec)]
    }
}
