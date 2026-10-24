import CoreFoundation
import Foundation

extension ProviderIntegrationCatalog {
    /// Inspect configured local providers. No configured executable, hook, or
    /// server is started. Enabled means configured, not connection verified.
    public static func scan(workspacePath: String? = nil, codexHome: String? = nil,
                            claudeHome: String? = nil, libraryRoot: URL = defaultLibraryRoot) throws -> ProviderIntegrationScan {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let codex = normalized(codexHome ?? ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home + "/.codex")
        let claude = normalized(claudeHome ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? home + "/.claude")
        let workspace = workspacePath.map(normalized)
        var reader = IntegrationDiscovery(codex: codex, claude: claude, workspace: workspace)
        try reader.discover()
        let imports = try libraryItems(libraryRoot: libraryRoot)
        var indexed = Dictionary(reader.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for var item in imports {
            if item.importMode == .linked {
                if let live = indexed[item.id] {
                    item = live; item.importMode = .linked
                } else { item.available = false }
            }
            if let assetKey = instructionAssetKey(item) {
                // Keep the imported lexical source as provenance while hiding
                // an equivalent live alias. Separate imported copies remain
                // independently removable, even if they began at one source.
                let aliases = indexed.values.filter { !$0.imported && instructionAssetKey($0) == assetKey }.map(\.id)
                for alias in aliases { indexed.removeValue(forKey: alias) }
            }
            indexed[item.id] = item
        }
        return .init(items: indexed.values.sorted {
            ($0.provider.rawValue, $0.kind.rawValue, $0.name, $0.sourcePath) < ($1.provider.rawValue, $1.kind.rawValue, $1.name, $1.sourcePath)
        }, issues: reader.issues)
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
    fileprivate static func instructionAssetKey(_ item: ProviderIntegrationItem) -> String? {
        guard item.kind == .skills || item.kind == .commands else { return nil }
        let physical = URL(fileURLWithPath: item.sourcePath).resolvingSymlinksInPath().standardizedFileURL.path
        return [item.provider.rawValue, item.kind.rawValue, item.scope, physical].map { "\($0.utf8.count):\($0)" }.joined()
    }
}

private struct IntegrationDiscovery {
    let codex: String
    let claude: String
    let workspace: String?
    var items: [ProviderIntegrationItem] = []
    var issues: [ProviderIntegrationIssue] = []
    var visited = Set<String>()
    var instructionAssets = Set<String>()
    var codexPluginStates: [String: Bool] = [:]
    var claudePluginStates: [String: Bool] = [:]
    var claudeMCPDisabled = Set<String>()
    var claudeHooksDisabled = false
    var directoryBudget = 2_000

    mutating func discover() throws {
        try Task.checkCancellation()
        var claudeSettings: [(String, String)] = [(claude + "/settings.json", "User")]
        if let workspace {
            claudeSettings += [(workspace + "/.claude/settings.json", "Project"), (workspace + "/.claude/settings.local.json", "Local")]
        }
        // Merge the effective local enablement before discovering plugin assets.
        // Managed policy remains enforced by the CLI, never overridden here.
        for (path, _) in claudeSettings {
            if let settings = json(path, provider: .claude) {
                for (name, value) in settings["enabledPlugins"] as? [String: Any] ?? [:] {
                    if let value = boolean(value) { claudePluginStates[name] = value }
                }
                if let disabled = settings["disabledMcpjsonServers"] as? [String] { claudeMCPDisabled.formUnion(disabled) }
                if let enabled = settings["enabledMcpjsonServers"] as? [String] { claudeMCPDisabled.subtract(enabled) }
                if let disabled = boolean(settings["disableAllHooks"]) { claudeHooksDisabled = disabled }
            }
        }
        skills(at: codex + "/skills", provider: .codex, scope: "User")
        let agents = URL(fileURLWithPath: codex).deletingLastPathComponent().appendingPathComponent(".agents/skills").path
        skills(at: agents, provider: .codex, scope: "User")
        commands(at: codex + "/prompts", provider: .codex, scope: "User")
        skills(at: claude + "/skills", provider: .claude, scope: "User")
        commands(at: claude + "/commands", provider: .claude, scope: "User")
        codexConfiguration(codex + "/config.toml", scope: "User")
        hooksJSON(codex + "/hooks.json", provider: .codex, scope: "User", enabled: true)
        if let workspace {
            skills(at: workspace + "/.agents/skills", provider: .codex, scope: "Project")
            skills(at: workspace + "/.codex/skills", provider: .codex, scope: "Project")
            commands(at: workspace + "/.codex/prompts", provider: .codex, scope: "Project")
            skills(at: workspace + "/.claude/skills", provider: .claude, scope: "Project")
            commands(at: workspace + "/.claude/commands", provider: .claude, scope: "Project")
            codexConfiguration(workspace + "/.codex/config.toml", scope: "Project")
            hooksJSON(workspace + "/.codex/hooks.json", provider: .codex, scope: "Project", enabled: true)
            if let settings = json(workspace + "/.mcp.json", provider: .claude) {
                mcp(settings, path: workspace + "/.mcp.json", provider: .claude, scope: "Project", enabled: true)
            }
        }
        for (path, scope) in claudeSettings {
            guard let settings = json(path, provider: .claude) else { continue }
            mcp(settings, path: path, provider: .claude, scope: scope, enabled: true)
            hooks(settings, path: path, provider: .claude, scope: scope, enabled: !claudeHooksDisabled)
            for (name, _) in settings["enabledPlugins"] as? [String: Any] ?? [:] {
                add(.init(provider: .claude, kind: .plugins, name: name,
                          summary: "Configured plugin. Uses the original Claude configuration and credentials.",
                          sourcePath: path, scope: scope, enabled: claudePluginStates[name] ?? false))
            }
        }
        let claudeConfig = URL(fileURLWithPath: claude).lastPathComponent == ".claude"
            ? URL(fileURLWithPath: claude).deletingLastPathComponent().appendingPathComponent(".claude.json").path
            : claude + "/.claude.json"
        if let settings = json(claudeConfig, provider: .claude) {
            mcp(settings, path: claudeConfig, provider: .claude, scope: "User", enabled: true)
            if let workspace, let projects = settings["projects"] as? [String: Any], let project = projects[workspace] as? [String: Any] {
                mcp(project, path: claudeConfig, provider: .claude, scope: "Local", enabled: true)
            }
        }
        claudePlugins()
        // Project configuration can override a user plugin's enabled state.
        // Discover assets only after merging those states so deduplication does
        // not preserve an earlier, superseded user-scope value.
        for identifier in codexPluginStates.keys.sorted() {
            codexPlugin(identifier, enabled: codexPluginStates[identifier] == true)
        }
        codexCachedPlugins()
        try Task.checkCancellation()
    }

    mutating func add(_ item: ProviderIntegrationItem) {
        guard items.count < 10_000, (try? item.validate()) != nil else {
            issue(item.sourcePath, item.provider, "Some integration metadata exceeded the supported limits."); return
        }
        if let key = ProviderIntegrationCatalog.instructionAssetKey(item), !instructionAssets.insert(key).inserted { return }
        if visited.insert(item.id).inserted { items.append(item) }
    }
    mutating func issue(_ path: String, _ provider: ProviderKind, _ message: String = "This provider source could not be inspected. Review it in the provider CLI.") {
        guard issues.count < 100 else { return }
        let value = ProviderIntegrationIssue(provider: provider, sourcePath: path, message: message)
        if !issues.contains(value) { issues.append(value) }
    }
    mutating func json(_ path: String, provider: ProviderKind) -> [String: Any]? {
        do {
            guard let text = try ClaudeSkillFiles.text(path) else { return nil }
            return try ClaudeSkillFiles.json(text)
        } catch { issue(path, provider); return nil }
    }
    mutating func children(_ path: String, provider: ProviderKind) -> [String] {
        guard ClaudeSkillFiles.exists(path) else { return [] }
        guard directoryBudget > 0 else { issue(path, provider, "Discovery reached its directory limit."); return [] }
        directoryBudget -= 1
        do { return try ClaudeSkillFiles.directory(path) } catch { issue(path, provider); return [] }
    }

    mutating func skills(at root: String, provider: ProviderKind, scope: String, enabled: Bool = true, namespace: String? = nil, depth: Int = 0, boundaryRoot: String? = nil) {
        guard depth < 4 else { issue(root, provider, "Skill discovery reached its nesting limit."); return }
        for name in children(root, provider: provider) where !name.hasPrefix(".") || name == ".system" {
            let directory = root + "/" + name
            if let boundaryRoot,
               !ClaudeSkillFiles.inside(URL(fileURLWithPath: directory + "/SKILL.md").resolvingSymlinksInPath().path, root: boundaryRoot) {
                issue(directory, provider, "A plugin skill outside its installation directory was skipped."); continue
            }
            if name == ".system" { skills(at: directory, provider: provider, scope: scope, enabled: enabled, namespace: namespace, depth: depth + 1, boundaryRoot: boundaryRoot); continue }
            skill(directory + "/SKILL.md", fallback: name, provider: provider, scope: scope, enabled: enabled, namespace: namespace)
        }
    }
    mutating func skill(_ path: String, fallback: String, provider: ProviderKind, scope: String, enabled: Bool, namespace: String?) {
        do {
            guard let metadata = try ClaudeSkillMetadata.read(path: path) else { return }
            let name = provider == .claude ? fallback : (metadata.name ?? fallback)
            let qualified = namespace.map { $0 + ":" + name } ?? name
            let token = provider == .codex ? "$" + qualified : "/" + qualified
            add(.init(provider: provider, kind: .skills, name: qualified,
                      summary: metadata.description.isEmpty ? "Skill instructions and supporting assets." : metadata.description,
                      sourcePath: path, scope: scope, enabled: enabled,
                      invocation: metadata.userInvocable ? token : nil))
        } catch { issue(path, provider) }
    }
    mutating func commands(at root: String, provider: ProviderKind, scope: String, enabled: Bool = true, prefix: String = "", depth: Int = 0) {
        guard depth < 8 else { issue(root, provider, "Command discovery reached its nesting limit."); return }
        let physicalRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        for name in children(root, provider: provider) where !name.hasPrefix(".") {
            let path = root + "/" + name
            guard ClaudeSkillFiles.inside(URL(fileURLWithPath: path).resolvingSymlinksInPath().path, root: physicalRoot) else {
                issue(path, provider, "An external command link was skipped."); continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                commands(at: path, provider: provider, scope: scope, enabled: enabled, prefix: prefix + name + ":", depth: depth + 1)
            } else if name.lowercased().hasSuffix(".md") {
                do {
                    guard let metadata = try ClaudeSkillMetadata.read(path: path) else { continue }
                    let command = prefix + String(name.dropLast(3))
                    add(.init(provider: provider, kind: .commands, name: command,
                              summary: metadata.description.isEmpty ? "Saved command instructions. Import to use independently in Coincide." : metadata.description,
                              sourcePath: path, scope: scope, enabled: enabled,
                              invocation: provider == .codex ? "/prompts:" + command : "/" + command))
                } catch { issue(path, provider) }
            }
        }
    }

    mutating func codexConfiguration(_ path: String, scope: String) {
        do {
            guard let text = try ClaudeSkillFiles.text(path) else { return }
            let tables = try ProviderIntegrationTOML.tables(text)
            for table in tables {
                if table.path.count == 2, table.path[0] == "mcp_servers" {
                    add(.init(provider: .codex, kind: .mcp, name: table.path[1],
                              summary: "Configured MCP server. Arguments, environment values, and authentication stay in Codex.",
                              sourcePath: path, scope: scope, enabled: table.values["enabled"] != "false"))
                }
                if table.path.count == 2, table.path[0] == "plugins" {
                    let name = table.path[1], enabled = table.values["enabled"] != "false"
                    codexPluginStates[name] = enabled
                    add(.init(provider: .codex, kind: .plugins, name: name,
                              summary: "Configured plugin. Uses the original Codex configuration and credentials.",
                              sourcePath: path, scope: scope, enabled: enabled))
                }
                if table.path.isEmpty, table.values["notify"] != nil {
                    add(.init(provider: .codex, kind: .hooks, name: "Notification callback",
                              summary: "Codex notification command. Command and arguments are kept private in the provider configuration.",
                              sourcePath: path, scope: scope))
                }
                if (table.path.isEmpty && (table.values["mcp_servers"] != nil || table.values["plugins"] != nil)) ||
                    (["mcp_servers", "plugins"].contains(table.path.first ?? "") && table.path.count == 1 && !table.values.isEmpty) {
                    issue(path, .codex, "Some inline integration definitions require review in the provider CLI; table definitions are supported.")
                }
            }
        } catch { issue(path, .codex) }
    }
    mutating func mcp(_ object: [String: Any], path: String, provider: ProviderKind, scope: String, enabled: Bool) {
        guard let servers = object["mcpServers"] as? [String: Any] else { return }
        for (name, raw) in servers {
            guard let config = raw as? [String: Any] else { issue(path, provider); continue }
            add(.init(provider: provider, kind: .mcp, name: name,
                      summary: "Configured MCP server. Arguments, environment values, and authentication stay in the provider configuration.",
                      sourcePath: path, scope: scope,
                      enabled: enabled && boolean(config["disabled"]) != true && boolean(config["enabled"]) != false && (provider != .claude || !claudeMCPDisabled.contains(name))))
        }
    }
    mutating func hooksJSON(_ path: String, provider: ProviderKind, scope: String, enabled: Bool) {
        if let config = json(path, provider: provider) { hooks(config, path: path, provider: provider, scope: scope, enabled: enabled) }
    }
    mutating func hooks(_ config: [String: Any], path: String, provider: ProviderKind, scope: String, enabled: Bool) {
        guard let events = config["hooks"] as? [String: Any] else { return }
        for (event, raw) in events {
            guard let entries = raw as? [Any], !entries.isEmpty else { continue }
            let count = entries.reduce(0) { $0 + (($1 as? [String: Any])?["hooks"] as? [Any] ?? [$1]).count }
            add(.init(provider: provider, kind: .hooks, name: event,
                      summary: "\(count) configured hook\(count == 1 ? "" : "s"). Commands, prompts, matchers, and credentials remain in the original configuration.",
                      sourcePath: path, scope: scope, enabled: enabled))
        }
    }

    mutating func codexPlugin(_ identifier: String, enabled: Bool) {
        let parts = identifier.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, safeComponent(parts[0]), safeComponent(parts[1]) else { return }
        let root = codex + "/plugins/cache/" + parts[1] + "/" + parts[0]
        let versions = children(root, provider: .codex).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        guard let version = versions.first(where: safeComponent) else { return }
        pluginAssets(root + "/" + version, identifier: identifier, provider: .codex, enabled: enabled)
    }
    mutating func codexCachedPlugins() {
        let cache = codex + "/plugins/cache"
        for marketplace in children(cache, provider: .codex) where safeComponent(marketplace) {
            let market = cache + "/" + marketplace
            for plugin in children(market, provider: .codex) where safeComponent(plugin) {
                let root = market + "/" + plugin
                let identifier = plugin + "@" + marketplace
                guard codexPluginStates[identifier] == nil else { continue }
                let versions = children(root, provider: .codex).filter(safeComponent).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                var installed: (path: String, manifest: String)?
                for version in versions {
                    let path = root + "/" + version
                    var directory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { continue }
                    let manifest = [".codex-plugin/plugin.json", ".claude-plugin/plugin.json", "plugin.json"]
                        .map { path + "/" + $0 }.first { ClaudeSkillFiles.exists($0) }
                    if let manifest { installed = (path, manifest); break }
                }
                guard let installed else { continue }
                let physicalRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
                guard ClaudeSkillFiles.inside(URL(fileURLWithPath: installed.manifest).resolvingSymlinksInPath().path, root: physicalRoot),
                      let manifest = json(installed.manifest, provider: .codex), manifest["name"] is String else {
                    issue(root, .codex, "A cached plugin manifest could not be inspected safely."); continue
                }
                let markerPath = root + "/.codex-remote-plugin-install.json"
                let marker = json(markerPath, provider: .codex)
                let remoteID = marker?["remote_plugin_id"] as? String
                let remotelyInstalled = marker?["schema_version"] as? Int == 1 && remoteID.map {
                    !$0.isEmpty && $0.utf8.count <= 1_024 && !$0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
                } == true
                if marker != nil && !remotelyInstalled {
                    issue(markerPath, .codex, "The cached plugin installation record is not a supported version.")
                }
                add(.init(provider: .codex, kind: .plugins, name: identifier,
                          summary: remotelyInstalled
                            ? "Installed remote plugin. Runtime availability and authentication remain with Codex."
                            : "Cached plugin assets. Activation is controlled by Codex; no active installation was found.",
                          sourcePath: remotelyInstalled ? markerPath : installed.manifest,
                          scope: remotelyInstalled ? "Plugin" : "Cache", enabled: remotelyInstalled))
                pluginAssets(installed.path, identifier: identifier, provider: .codex, enabled: remotelyInstalled)
            }
        }
    }
    mutating func claudePlugins() {
        let path = claude + "/plugins/installed_plugins.json"
        guard let registry = json(path, provider: .claude), let plugins = registry["plugins"] as? [String: Any] else { return }
        for (name, raw) in plugins {
            guard let installations = raw as? [[String: Any]] else { issue(path, .claude); continue }
            for installation in installations {
                let scope = installation["scope"] as? String ?? "user"
                if scope == "project" || scope == "local" {
                    guard let workspace, let target = installation["projectPath"] as? String,
                          URL(fileURLWithPath: target).standardizedFileURL.path == workspace else { continue }
                }
                guard let root = installation["installPath"] as? String, root.hasPrefix("/"), root.utf8.count < 4_096 else { continue }
                let enabled = claudePluginStates[name] ?? false
                add(.init(provider: .claude, kind: .plugins, name: name,
                          summary: "Installed plugin. Enabled state follows the original Claude settings.",
                          sourcePath: path, scope: scope.capitalized, enabled: enabled, available: ClaudeSkillFiles.exists(root)))
                pluginAssets(root, identifier: name, provider: .claude, enabled: enabled)
            }
        }
    }
    mutating func pluginAssets(_ root: String, identifier: String, provider: ProviderKind, enabled: Bool) {
        let namespace = String(identifier.split(separator: "@").first ?? Substring(identifier))
        let scope = "Plugin"
        let physicalRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        func contained(_ path: String) -> Bool {
            ClaudeSkillFiles.inside(URL(fileURLWithPath: path).resolvingSymlinksInPath().path, root: physicalRoot)
        }
        if contained(root + "/skills") { skills(at: root + "/skills", provider: provider, scope: scope, enabled: enabled, namespace: namespace, boundaryRoot: physicalRoot) }
        if contained(root + "/commands") { commands(at: root + "/commands", provider: provider, scope: scope, enabled: enabled, prefix: namespace + ":") }
        if contained(root + "/.mcp.json"), let config = json(root + "/.mcp.json", provider: provider) { mcp(config, path: root + "/.mcp.json", provider: provider, scope: scope, enabled: enabled) }
        if contained(root + "/hooks/hooks.json") { hooksJSON(root + "/hooks/hooks.json", provider: provider, scope: scope, enabled: enabled && (provider != .claude || !claudeHooksDisabled)) }
        // Custom manifest paths are honored only inside the installed plugin.
        for manifestPath in [root + "/.codex-plugin/plugin.json", root + "/.claude-plugin/plugin.json", root + "/plugin.json"] {
            guard contained(manifestPath) else { issue(manifestPath, provider, "A plugin manifest outside its installation directory was skipped."); continue }
            guard let manifest = json(manifestPath, provider: provider) else { continue }
            for key in ["skills", "commands"] {
                let paths = (manifest[key] as? [String]) ?? (manifest[key] as? String).map { [$0] } ?? []
                for relative in paths.prefix(64) {
                    let target = ClaudeSkillFiles.path(relative, relativeTo: root)
                    let physical = URL(fileURLWithPath: target).resolvingSymlinksInPath().path
                    guard ClaudeSkillFiles.inside(physical, root: URL(fileURLWithPath: root).resolvingSymlinksInPath().path) else {
                        issue(manifestPath, provider, "A plugin resource outside its installation directory was skipped."); continue
                    }
                    if key == "skills" {
                        if ClaudeSkillFiles.exists(target + "/SKILL.md") {
                            guard contained(target + "/SKILL.md") else {
                                issue(manifestPath, provider, "A plugin skill outside its installation directory was skipped."); continue
                            }
                            skill(target + "/SKILL.md", fallback: URL(fileURLWithPath: target).lastPathComponent, provider: provider, scope: scope, enabled: enabled, namespace: namespace)
                        } else { skills(at: target, provider: provider, scope: scope, enabled: enabled, namespace: namespace, boundaryRoot: physicalRoot) }
                    } else { commands(at: target, provider: provider, scope: scope, enabled: enabled, prefix: namespace + ":") }
                }
            }
            break
        }
    }
    private func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.hasPrefix(".")
    }
    private func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }; return number.boolValue
    }
}
