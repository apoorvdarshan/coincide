import Darwin
import Foundation

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
    public init(keybindings: [ResolvedKeybinding] = KeybindingDefaults.resolved, issues: [KeybindingsConfigIssue] = [], fileRules: [KeybindingRule] = []) {
        self.keybindings = keybindings; self.issues = issues; self.fileRules = fileRules
    }
}

/// Owns `keybindings.json` beside the workspace database, following T3's server
/// semantics: lenient JSON, per-entry issues, defaults when the file is malformed,
/// first-run defaults, startup backfill of missing commands and atomic writes.
public actor KeybindingsConfigStore {
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
        do {
            try prepareDirectory()
            try syncDefaultsOnStartup()
        } catch { warnings.append("Keybindings defaults could not be written: \(error.localizedDescription)") }
        return load()
    }

    /// The runtime view: invalid entries become issues; a malformed file yields defaults.
    public func load() -> KeybindingsConfigState {
        guard let data = try? Data(contentsOf: fileURL) else {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return .init(keybindings: defaultResolved, issues: [.init(kind: .malformedConfig, message: "keybindings.json could not be read.")])
            }
            return .init(keybindings: defaultResolved)
        }
        let decoded = Self.decode(data)
        let compiled = KeybindingResolver.compile(decoded.rules)
        return .init(keybindings: KeybindingResolver.merge(compiled, defaults: defaultResolved), issues: decoded.issues, fileRules: decoded.rules)
    }

    /// T3 `syncDefaultKeybindingsOnStartup`. Missing commands are added before the
    /// user's rules so existing custom shortcuts keep priority; a default whose shortcut
    /// and condition are already used is skipped. Nothing is written while the file has issues.
    public func syncDefaultsOnStartup() throws {
        let applied = appliedMigrations()
        let pendingLate = lateDefaults.filter { !applied.contains($0.id) }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try write(defaults)
            if !pendingLate.isEmpty { try recordMigrations(applied.union(lateDefaults.map(\.id))) }
            return
        }
        let current = load()
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
        if !appended.isEmpty { try write(appended + custom) }
        let settled = pendingLate.filter { late in !skipped.contains(late.rule) }
        if !settled.isEmpty { try recordMigrations(applied.union(settled.map(\.id))) }
    }

    /// Adds `rule`, replacing `replacing` (and any identical rule). Writes atomically,
    /// keeps the newest 256 rules and drops entries that cannot be decoded, like T3.
    @discardableResult
    public func upsert(_ rule: KeybindingRule, replacing: KeybindingRule? = nil) throws -> KeybindingsConfigState {
        try Self.validate(rule)
        var next = try writableRules().filter { !$0.isSame(as: rule) && !(replacing.map($0.isSame(as:)) ?? false) }
        next.append(rule)
        if next.count > KeybindingResolver.maxRules { next = Array(next.suffix(KeybindingResolver.maxRules)) }
        try write(next)
        return .init(keybindings: KeybindingResolver.merge(KeybindingResolver.compile(next), defaults: defaultResolved), fileRules: next)
    }

    @discardableResult
    public func remove(_ rule: KeybindingRule) throws -> KeybindingsConfigState {
        let next = try writableRules().filter { !$0.isSame(as: rule) }
        try write(next)
        return .init(keybindings: KeybindingResolver.merge(KeybindingResolver.compile(next), defaults: defaultResolved), fileRules: next)
    }

    private func writableRules() throws -> [KeybindingRule] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoded = Self.decode(data)
        if decoded.issues.contains(where: { $0.kind == .malformedConfig }) {
            throw CoincideError("keybindings.json is not a JSON array. Fix or remove the file before changing shortcuts here.")
        }
        return decoded.rules
    }

    private func write(_ rules: [KeybindingRule]) throws {
        try prepareDirectory()
        try Self.encode(rules).write(to: fileURL, options: .atomic)
    }
    /// The data root also holds the private workspace database; create it owner-only, as the database does.
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    private func appliedMigrations() -> Set<String> {
        guard let text = try? String(contentsOf: migrationsURL, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }
    private func recordMigrations(_ ids: Set<String>) throws {
        try Data((ids.sorted().joined(separator: "\n") + "\n").utf8).write(to: migrationsURL, options: .atomic)
    }

    // MARK: Pure decoding

    public static func validate(_ rule: KeybindingRule) throws {
        let key = rule.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= KeybindingShortcut.maxLength else { throw CoincideError("A shortcut needs 1 to \(KeybindingShortcut.maxLength) characters.") }
        guard rule.command.isKnown else { throw CoincideError("Unknown command “\(rule.command.rawValue)”.") }
        guard KeybindingShortcut(parsing: key) != nil else { throw CoincideError("“\(key)” is not a valid shortcut. Join modifiers and one key with +.") }
        if let when = rule.when {
            guard when.count <= KeybindingWhen.maxLength else { throw CoincideError("A condition can have at most \(KeybindingWhen.maxLength) characters.") }
            guard KeybindingWhen(parsing: when) != nil else { throw CoincideError("“\(when)” is not a valid condition. Use variables with !, &&, || and parentheses.") }
        }
    }

    public static func decode(_ data: Data) -> (rules: [KeybindingRule], issues: [KeybindingsConfigIssue]) {
        let text = String(decoding: data, as: UTF8.self)
        guard let json = try? JSONSerialization.jsonObject(with: Data(stripLenientJSON(text).utf8), options: [.fragmentsAllowed]),
              let entries = json as? [Any] else {
            return ([], [.init(kind: .malformedConfig, message: "keybindings.json must contain a JSON array of rules. Using the default shortcuts.")])
        }
        var rules: [KeybindingRule] = [], issues: [KeybindingsConfigIssue] = []
        for (index, entry) in entries.enumerated() {
            do { rules.append(try decodeEntry(entry)) }
            catch { issues.append(.init(kind: .invalidEntry, index: index, message: error.localizedDescription)) }
        }
        return (rules, issues)
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
        let descriptor = open(path, O_EVTONLY)
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
        guard stat(fileURL.path, &info) == 0 else { return nil }
        return [Int(info.st_ino), Int(info.st_size), Int(info.st_mtimespec.tv_sec), Int(info.st_mtimespec.tv_nsec)]
    }
}
