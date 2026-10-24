import CryptoKit
import Darwin
import Foundation

public enum ProviderConfigurationScope: String, CaseIterable, Sendable, Identifiable {
    case user, project, local
    public var id: String { rawValue }
    public var title: String { switch self { case .user: "User"; case .project: "Shared project"; case .local: "Project local" } }
}

public enum ProviderConfigurationControl: Sendable, Equatable {
    case toggle, choice([String]), text, lines, integer(ClosedRange<Int>)
}

/// Only explicitly supported, non-credential settings are exposed to views.
/// The complete source is never part of the UI's document model.
public struct ProviderConfigurationField: Sendable, Identifiable, Equatable {
    public let path: [String]
    public let title: String
    public let detail: String
    public let group: String
    public let control: ProviderConfigurationControl
    public let value: String
    public let isEditable: Bool
    public var id: String { path.map { $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }.joined(separator: "/") }
}

public struct ProviderConfigurationDocument: Sendable {
    public let provider: ProviderKind
    public let scope: ProviderConfigurationScope
    public let sourceURL: URL
    public let resolvedURL: URL
    public let exists: Bool
    public let fields: [ProviderConfigurationField]
    public let notices: [String]
    fileprivate let revision: String
}

/// Reads provider-owned configuration and changes only a small, typed allowlist.
/// This service never starts a provider, invokes a hook, or writes on load.
public actor ProviderConfigurationEditor {
    private let maximumBytes = 1_048_576
    public init() {}

    public static func sourceURL(provider: ProviderKind, scope: ProviderConfigurationScope,
        codex: CodexRuntimeConfiguration, claude: ClaudeRuntimeProfile, workspacePath: String?,
        environment: [String: String] = ProcessChannel.environment()) throws -> URL {
        guard provider.isSupported else { throw CoincideError("Choose Codex or Claude.") }
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let root: URL
        if scope == .user {
            let path = provider == .codex ? codex.homeDirectory ?? environment["CODEX_HOME"] ?? home + "/.codex"
                : claude.configurationDirectory ?? environment["CLAUDE_CONFIG_DIR"] ?? home + "/.claude"
            guard path.hasPrefix("/"), !path.contains("\0") else { throw CoincideError("The provider configuration directory must be an absolute path.") }
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            guard let workspacePath, workspacePath.hasPrefix("/"), !workspacePath.contains("\0") else {
                throw CoincideError("Select a project to edit its configuration.")
            }
            root = URL(fileURLWithPath: workspacePath, isDirectory: true).appendingPathComponent(provider == .codex ? ".codex" : ".claude", isDirectory: true)
        }
        guard provider != .codex || scope != .local else { throw CoincideError("Codex has user and project configuration scopes.") }
        return root.appendingPathComponent(provider == .codex ? "config.toml" : scope == .local ? "settings.local.json" : "settings.json")
    }

    public func load(provider: ProviderKind, scope: ProviderConfigurationScope, sourceURL: URL) throws -> ProviderConfigurationDocument {
        guard provider.isSupported else { throw CoincideError("Choose Codex or Claude.") }
        let read = try readSource(sourceURL)
        let definitions = Self.definitions(provider: provider, scope: scope)
        var fields: [ProviderConfigurationField] = []
        var notices: [String] = []
        if provider == .claude {
            let object = try jsonObject(read.data)
            for definition in definitions { fields.append(definition.field(value: Self.lookup(definition.path, in: object))) }
            if let plugins = object["enabledPlugins"] as? [String: Any] {
                for name in plugins.keys.sorted() where Self.safeName(name) {
                    let definition = Definition(["enabledPlugins", name], name, "Enables this installed plugin. Its hooks and tools may run in provider sessions.", "Plugins", .toggle)
                    fields.append(definition.field(value: plugins[name]))
                }
            }
        } else {
            let toml = try ProviderConfigurationTOML(data: read.data)
            for definition in definitions { fields.append(definition.field(value: toml.value(at: definition.path))) }
            for path in toml.paths.sorted(by: { $0.joined(separator: ".") < $1.joined(separator: ".") }) {
                if path.count == 2, path[0] == "features", Self.safeName(path[1]) {
                    let definition = Definition(path, path[1], "Uses the installed Codex version's native feature flag.", "Feature flags", .toggle)
                    fields.append(definition.field(value: toml.value(at: path)))
                }
            }
            let servers = Set(toml.paths.filter { $0.count >= 3 && $0[0] == "mcp_servers" }.map { $0[1] })
            for name in servers.sorted() where Self.safeName(name) {
                let definition = Definition(["mcp_servers", name, "enabled"], name, "Controls whether Codex loads this configured MCP server. Connection and trust are verified by Codex.", "MCP servers", .toggle)
                fields.append(definition.field(value: toml.value(at: definition.path)))
            }
            let plugins = Set(toml.paths.filter { $0.count >= 3 && $0[0] == "plugins" }.map { $0[1] })
            for name in plugins.sorted() where Self.safeName(name) {
                let definition = Definition(["plugins", name, "enabled"], name, "Controls whether Codex loads this configured plugin. Its hooks and tools may run in provider sessions; availability and trust are verified by Codex.", "Plugins", .toggle)
                fields.append(definition.field(value: toml.value(at: definition.path)))
            }
        }
        if fields.contains(where: { !$0.isEditable }) {
            notices.append("Some values use an advanced format or contain sensitive text. They are preserved and can be edited in the source file.")
        }
        if scope == .project { notices.append("Shared project settings can be committed with the project and affect other people using it. Provider trust and organization policy still apply.") }
        if scope == .local { notices.append("Keep .claude/settings.local.json out of version control. Coincide does not change your project's ignore rules.") }
        notices.append(provider == .claude
            ? "Claude can reload permissions, hooks and other settings during active sessions. Model defaults apply to future sessions; a conversation's explicit controls and managed policy take precedence."
            : "Codex reads these defaults when its runtime starts. A conversation's explicit model, effort and permission controls, command-line overrides and managed policy take precedence.")
        return .init(provider: provider, scope: scope, sourceURL: sourceURL, resolvedURL: read.target,
            exists: read.exists, fields: fields, notices: notices, revision: read.revision)
    }

    /// `changes` contains field IDs and their draft values. Empty means remove
    /// this source's override, not force a permissive provider default.
    public func save(_ document: ProviderConfigurationDocument, changes: [String: String]) throws -> ProviderConfigurationDocument {
        guard !changes.isEmpty else { return document }
        let current = try readSource(document.sourceURL)
        guard current.target == document.resolvedURL, current.revision == document.revision, current.exists == document.exists else {
            throw CoincideError("This configuration changed outside Coincide. Reload it before saving; your provider file has not been overwritten.")
        }
        let known = Dictionary(uniqueKeysWithValues: document.fields.map { ($0.id, $0) })
        var edits: [([String], Any?)] = []
        for (id, value) in changes.sorted(by: { $0.key < $1.key }) {
            guard let field = known[id], field.isEditable else { throw CoincideError("This setting cannot be changed with the structured editor.") }
            edits.append((field.path, try Self.validate(value, control: field.control)))
        }
        let replacement: Data
        if document.provider == .claude {
            var object = try jsonObject(current.data)
            for (path, value) in edits { try Self.assign(path, value: value, in: &object) }
            do { replacement = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10]) }
            catch { throw CoincideError("The settings could not be encoded. The source file is unchanged.") }
        } else {
            var toml = try ProviderConfigurationTOML(data: current.data)
            for (path, value) in edits { try toml.set(path, value: value) }
            replacement = Data(toml.source.utf8)
        }
        guard replacement.count <= maximumBytes else { throw CoincideError("This configuration is too large for the structured editor.") }
        try replace(current, source: document.sourceURL, data: replacement)
        return try load(provider: document.provider, scope: document.scope, sourceURL: document.sourceURL)
    }

    private struct Read {
        let target: URL
        let exists: Bool
        let data: Data
        let revision: String
        let permissions: mode_t
    }

    private func readSource(_ source: URL) throws -> Read {
        guard source.isFileURL else { throw CoincideError("Only local provider configuration files can be edited.") }
        let target = source.resolvingSymlinksInPath().standardizedFileURL
        let descriptor = open(target.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            guard errno == ENOENT else { throw CoincideError("The provider configuration could not be read safely.") }
            // A dangling symlink must not become a new regular file by accident.
            var entry = stat()
            if lstat(source.path, &entry) == 0, entry.st_mode & S_IFMT == S_IFLNK {
                throw CoincideError("The provider configuration link has no readable target. Repair the link before editing.")
            }
            return .init(target: target, exists: false, data: Data(), revision: "missing", permissions: 0o600)
        }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == getuid(), attributes.st_nlink == 1,
              attributes.st_size >= 0, attributes.st_size <= maximumBytes else {
            throw CoincideError("The structured editor requires a regular configuration file you own, no larger than 1 MB, without hard links.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data: Data
        do { data = try handle.readToEnd() ?? Data() }
        catch { throw CoincideError("The provider configuration could not be read.") }
        guard data.count <= maximumBytes else { throw CoincideError("This configuration is too large for the structured editor.") }
        return .init(target: target, exists: true, data: data, revision: Self.digest(data), permissions: attributes.st_mode & 0o777)
    }

    private func replace(_ original: Read, source: URL, data: Data) throws {
        let parent = original.target.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw CoincideError("The configuration directory could not be created.") }
        let temporary = parent.appendingPathComponent(".coincide-config-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CoincideError("A private temporary configuration could not be created.") }
        defer { close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do { try handle.write(contentsOf: data) }
        catch { throw CoincideError("The new configuration could not be written. The original is unchanged.") }
        guard fchmod(descriptor, original.permissions) == 0, fsync(descriptor) == 0 else { throw CoincideError("The new configuration could not be saved safely.") }
        let latest = try readSource(source)
        guard latest.target == original.target, latest.exists == original.exists, latest.revision == original.revision else {
            throw CoincideError("The configuration changed while saving. Reload it and try again.")
        }
        guard rename(temporary.path, original.target.path) == 0 else { throw CoincideError("The provider configuration could not be replaced.") }
        let directory = open(parent.path, O_RDONLY)
        if directory >= 0 { _ = fsync(directory); close(directory) }
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        if data.isEmpty { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CoincideError("Expected a JSON object.") }
            try ProviderConfigurationJSON.validateUniqueKeys(data)
            return object
        } catch { throw CoincideError("The provider settings are not a valid JSON object. Correct the source file before editing.") }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func safeName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 160 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && !sensitive(value)
    }
    private static func sensitive(_ value: String) -> Bool {
        let lower = value.lowercased()
        if ["bearer ", "authorization", "api_key", "api-key", "password", "token", "secret", "credential", "private_key", "private-key", "sk-", "ghp_", "gho_", "github_pat_", "--header", "-h ", "--user ", "--data"].contains(where: { lower.contains($0) }) { return true }
        // Permission rules can embed shell commands. An allowlisted JSON key
        // does not make an env assignment, header or authenticated URL public.
        return lower.range(of: #"\b[a-z_][a-z0-9_]*\s*=|https?://[^\s/]+@|https?://[^\s]+\?"#, options: .regularExpression) != nil
    }
    private static func lookup(_ path: [String], in object: [String: Any]) -> Any? {
        guard let first = path.first else { return nil }
        if path.count == 1 { return object[first] }
        guard let child = object[first] as? [String: Any] else { return object[first] == nil ? nil : NSNull() }
        return lookup(Array(path.dropFirst()), in: child)
    }
    private static func assign(_ path: [String], value: Any?, in object: inout [String: Any]) throws {
        guard let first = path.first else { return }
        if path.count == 1 { object[first] = value; return }
        guard object[first] == nil || object[first] is [String: Any] else { throw CoincideError("An advanced value occupies this setting. Edit it in the source file.") }
        var child = object[first] as? [String: Any] ?? [:]
        try assign(Array(path.dropFirst()), value: value, in: &child)
        object[first] = child.isEmpty ? nil : child
    }
    private static func validate(_ raw: String, control: ProviderConfigurationControl) throws -> Any? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard value.utf8.count <= 32_768, !value.contains("\0"), !sensitive(value) else {
            throw CoincideError("Use the provider's source file for sensitive values. Credentials cannot be entered in this editor.")
        }
        switch control {
        case .toggle:
            guard value == "true" || value == "false" else { throw CoincideError("Choose Enabled, Disabled or Inherit.") }
            return value == "true"
        case .choice(let options):
            guard options.contains(value) else { throw CoincideError("Choose a supported setting value.") }
            return value
        case .text:
            guard !value.contains("\n"), !value.contains("\r"), value.count <= 512 else { throw CoincideError("Enter a single value of at most 512 characters.") }
            return value
        case .lines:
            let lines = value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard lines.count <= 200, lines.allSatisfy({ $0.count <= 512 }) else { throw CoincideError("Use up to 200 entries, one per line, each at most 512 characters.") }
            return Array(NSOrderedSet(array: lines)) as? [String] ?? lines
        case .integer(let range):
            guard value.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(value), range.contains(number) else {
                throw CoincideError("Enter a whole number from \(range.lowerBound) to \(range.upperBound).")
            }
            return number
        }
    }

    private struct Definition {
        let path: [String]; let title: String; let detail: String; let group: String; let control: ProviderConfigurationControl
        init(_ path: [String], _ title: String, _ detail: String, _ group: String, _ control: ProviderConfigurationControl) {
            self.path = path; self.title = title; self.detail = detail; self.group = group; self.control = control
        }
        func field(value: Any?) -> ProviderConfigurationField {
            var text = ""
            var valid = true
            if let value {
                switch control {
                case .toggle:
                    if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { text = number.boolValue ? "true" : "false" }
                    else { valid = false }
                case .choice(let choices):
                    if let value = value as? String, choices.contains(value) { text = value } else { valid = false }
                case .text:
                    if let value = value as? String { text = value } else { valid = false }
                case .lines:
                    if let value = value as? [String] { text = value.joined(separator: "\n") } else { valid = false }
                case .integer(let range):
                    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue), range.contains(number.intValue) { text = number.stringValue }
                    else { valid = false }
                }
            }
            if !text.isEmpty, (try? ProviderConfigurationEditor.validate(text, control: control)) == nil { text = ""; valid = false }
            return .init(path: path, title: title, detail: detail, group: group, control: control, value: valid ? text : "", isEditable: valid)
        }
    }

    private static func definitions(provider: ProviderKind, scope: ProviderConfigurationScope) -> [Definition] {
        if provider == .codex {
            return [
                .init(["model"], "Default model", "Model identifier used when a conversation does not specify one.", "Model", .text),
                .init(["model_reasoning_effort"], "Reasoning effort", "Available effort levels depend on the selected model.", "Model", .choice(["none", "minimal", "low", "medium", "high", "xhigh"])),
                .init(["model_reasoning_summary"], "Reasoning summaries", "Controls the provider's reasoning summary preference.", "Model", .choice(["auto", "concise", "detailed", "none"])),
                .init(["model_verbosity"], "Response detail", "Applies only to models that support this preference.", "Model", .choice(["low", "medium", "high"])),
                .init(["service_tier"], "Service tier", "Priority availability and pricing depend on your account and model.", "Model", .choice(["fast", "flex"])),
                .init(["approval_policy"], "Approval policy", "A conversation's permission control overrides this default. Never means no approval prompts; sandbox restrictions still apply.", "Permissions", .choice(["on-request", "never"])),
                .init(["sandbox_mode"], "Sandbox", "Danger-full-access removes filesystem sandbox protection. Changing defaults here does not change Coincide's conversation permission control.", "Permissions", .choice(["read-only", "workspace-write", "danger-full-access"])),
                .init(["sandbox_workspace_write", "network_access"], "Workspace network access", "Allows network access within the workspace-write sandbox.", "Permissions", .toggle),
                .init(["sandbox_workspace_write", "writable_roots"], "Additional writable folders", "One absolute folder path per line. Used by the workspace-write sandbox.", "Permissions", .lines),
                .init(["allow_login_shell"], "Login shell", "Allows shell tools to use the login shell environment.", "Tools", .toggle),
                .init(["web_search"], "Web search", "Choose the provider's search mode. Model and runtime availability still apply.", "Tools", .choice(["disabled", "cached", "indexed", "live"])),
                .init(["check_for_update_on_startup"], "Check CLI updates", "Checks the installed Codex CLI for updates at startup.", "CLI preferences", .toggle),
                .init(["analytics", "enabled"], "CLI analytics", "Controls Codex analytics; this is separate from Coincide's settings.", "CLI preferences", .toggle)
            ]
        }
        let permissionModes = scope == .user ? ["default", "acceptEdits", "plan", "dontAsk", "auto", "bypassPermissions"] : ["default", "acceptEdits", "plan", "dontAsk"]
        return [
            .init(["model"], "Default model", "Model name or alias used when a conversation does not specify one.", "Model", .text),
            .init(["effortLevel"], "Reasoning effort", "Available effort levels depend on the selected Claude model.", "Model", .choice(["low", "medium", "high", "xhigh", "max"])),
            .init(["autoCompactWindow"], "Compaction threshold", "Context token threshold. Coincide's explicit runtime override takes precedence.", "Model", .integer(100_000...1_000_000)),
            .init(["permissions", "defaultMode"], "Default permission mode", "Coincide passes its conversation permission choice explicitly. Auto and bypassPermissions are user-scope settings only.", "Permissions", .choice(permissionModes)),
            .init(["permissions", "allow"], "Allowed tool rules", "One Claude permission rule per line, such as Read or Bash(npm run lint). Existing rules across scopes merge.", "Permissions", .lines),
            .init(["permissions", "ask"], "Always ask rules", "One rule per line. These rules request approval even when another scope allows the tool.", "Permissions", .lines),
            .init(["permissions", "deny"], "Denied tool rules", "One rule per line. Denials take precedence over allow rules.", "Permissions", .lines),
            .init(["permissions", "additionalDirectories"], "Additional folders", "One folder path per line. Project scope requires the provider's project trust.", "Permissions", .lines),
            .init(["permissions", "blockReadsOutsideWorkingDirectories"], "Restrict outside reads", "Blocks reads outside the working directories where supported by your CLI.", "Permissions", .toggle),
            .init(["disableAllHooks"], "Disable hooks", "Stops configured hooks. Re-enabling lets configured hook commands run in provider sessions.", "Hooks", .toggle),
            .init(["enabledMcpjsonServers"], "Approved project MCP servers", "One configured .mcp.json server name per line. Approval does not prove a live connection.", "MCP servers", .lines),
            .init(["disabledMcpjsonServers"], "Disabled project MCP servers", "One configured .mcp.json server name per line.", "MCP servers", .lines),
            .init(["enableAllProjectMcpServers"], "Approve all project MCP servers", "Lets Claude load project .mcp.json servers without individual approval, subject to managed policy.", "MCP servers", .toggle),
            .init(["autoUpdatesChannel"], "CLI update channel", "Select the stable or latest Claude CLI channel.", "CLI preferences", .choice(["stable", "latest"])),
            .init(["cleanupPeriodDays"], "CLI transcript retention", "Retention in days for Claude's own transcript files, separate from Coincide conversations.", "CLI preferences", .integer(0...3650))
        ]
    }
}
