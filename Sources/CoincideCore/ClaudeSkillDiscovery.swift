import Foundation
import CoreFoundation

/// Captured launcher inputs only. These are filesystem metadata settings, never
/// credentials or values parsed from a skill's executable body.
public struct ClaudeSkillDiscoveryConfiguration: Sendable, Hashable {
    public let runtime: ClaudeRuntimeConfiguration
    public let homeDirectory: String
    public let pluginCacheDirectory: String?
    public let additionalDirectories: [String]
    public let managedSettingsPath: String
    public init(runtime: ClaudeRuntimeConfiguration, environment: [String: String] = ProcessChannel.environment(),
                launchArguments: [String] = [], managedSettingsPath: String = "/Library/Application Support/ClaudeCode/managed-settings.json") throws {
        try runtime.validate(); self.runtime = runtime
        if case .defaultHome(let home) = runtime.configurationDirectorySelection { homeDirectory = home }
        else { homeDirectory = environment["HOME"] ?? NSHomeDirectory() }
        pluginCacheDirectory = environment["CLAUDE_CODE_PLUGIN_CACHE_DIR"]
        var extra: String?
        for index in launchArguments.indices {
            let value = launchArguments[index]
            if value == "--add-dir", index + 1 < launchArguments.count { extra = launchArguments[index + 1] }
            else if value.hasPrefix("--add-dir=") { extra = String(value.dropFirst(10)) }
        }
        additionalDirectories = extra.map { [ClaudeSkillFiles.path($0, relativeTo: runtime.workspacePath)] } ?? []
        self.managedSettingsPath = managedSettingsPath
        for value in [homeDirectory, managedSettingsPath] + additionalDirectories + (pluginCacheDirectory.map { [$0] } ?? []) {
            try SkillValidation.text(value, maximum: 4_096, empty: false)
        }
    }
}

public enum ClaudeSkillService {
    private struct Root { let path: String, scope: String; var prefix: String? }
    private struct Settings { var overrides: [String: String] = [:]; var plugins: [String: Bool] = [:] }
    public static func discover(configuration: ClaudeSkillDiscoveryConfiguration) throws -> ProviderSkillInventory {
        let runtime = configuration.runtime, cwd = runtime.registeredWorkspacePath
        try runtime.validate(); let anchor = try ClaudeSkillFiles.identity(cwd, directory: true)
        guard try ClaudeSkillFiles.identity(runtime.workspacePath, directory: true) == anchor else { throw ProviderSkillError(.unavailable) }
        var problems: [ProviderSkillProblem] = []
        func problem(_ path: String? = nil) {
            let safePath = path.flatMap { (try? SkillValidation.text($0, maximum: 4_096, empty: false)) != nil ? $0 : nil }
            if problems.count < 256 { problems.append(.init(path: safePath, message: "Some Claude skill metadata could not be read safely. Review its source with Claude before using it.")) }
        }
        let repo = repositoryRoot(runtime.workspacePath)
        var paths = [runtime.configurationDirectory + "/settings.json", runtime.workspacePath + "/.claude/settings.json", runtime.workspacePath + "/.claude/settings.local.json"]
        if let repo, !repo.utf8.elementsEqual(runtime.workspacePath.utf8) { paths.append(repo + "/.claude/settings.local.json") }
        paths.append(configuration.managedSettingsPath)
        var settings = Settings()
        for path in paths {
            do {
                guard let source = try ClaudeSkillFiles.text(path) else { continue }
                let value = try ClaudeSkillFiles.json(source)
                var overrides: [String: String] = [:]
                if let raw = value["skillOverrides"] {
                    guard let entries = raw as? [String: Any] else { throw ProviderSkillError(.invalidResponse) }
                    for (name, raw) in entries {
                        guard let mode = raw as? String, ["on", "name-only", "user-invocable-only", "off"].contains(mode) else { throw ProviderSkillError(.invalidResponse) }
                        overrides[name] = mode
                    }
                }
                let pluginValues: [String: Any]
                if let raw = value["enabledPlugins"] { guard let entries = raw as? [String: Any] else { throw ProviderSkillError(.invalidResponse) }; pluginValues = entries }
                else { pluginValues = [:] }
                for (name, mode) in overrides { settings.overrides[name] = mode }
                for (key, raw) in pluginValues {
                    if let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { settings.plugins[key] = value.boolValue }
                    else { settings.plugins.removeValue(forKey: key) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { problem(path) }
        }
        var roots = [Root(path: runtime.configurationDirectory + "/skills", scope: "user"), Root(path: runtime.workspacePath + "/.claude/skills", scope: "project")]
        roots += configuration.additionalDirectories.map { Root(path: $0 + "/.claude/skills", scope: "project") }
        roots += pluginRoots(configuration, settings: settings, problem: problem)
        guard roots.count <= 256 else { throw ProviderSkillError(.invalidResponse) }
        var skills: [ProviderSkill] = [], names = Set<String>(), scanned = 0
        for root in roots {
            try Task.checkCancellation()
            guard ClaudeSkillFiles.exists(root.path) else { continue }
            do {
                let rootIdentity = try ClaudeSkillFiles.identity(root.path, directory: true)
                let single = root.prefix != nil && ClaudeSkillFiles.exists(root.path + "/SKILL.md")
                let entries = single ? [URL(fileURLWithPath: root.path).lastPathComponent] : try ClaudeSkillFiles.directory(root.path)
                for entry in entries {
                    scanned += 1; guard scanned <= 10_000, skills.count < 2_000 else { throw ProviderSkillError(.invalidResponse) }
                    let path = single ? root.path + "/SKILL.md" : root.path + "/" + entry + "/SKILL.md"
                    do {
                        guard let metadata = try ClaudeSkillMetadata.read(path: path) else { continue }
                        var name = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let prefix = root.prefix {
                            let declared = single ? metadata.name ?? name : name
                            let short = declared.hasPrefix(prefix + ":") ? String(declared.dropFirst(prefix.count + 1)) : declared
                            let sanitized = short.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "-", options: .regularExpression)
                            name = prefix + ":" + sanitized
                        }
                        guard !names.contains(name) else { continue }
                        let mode = root.prefix == nil ? settings.overrides[name] : nil
                        let skill = ProviderSkill(name: name, path: path, description: metadata.description, scope: root.scope,
                            enabled: mode != "off", userInvocable: metadata.userInvocable,
                            userInvocationOnly: metadata.userInvocationOnly || mode == "user-invocable-only")
                        try skill.validate()
                        // Invalid token shapes are not advertised as runnable native names.
                        guard !name.isEmpty, name.range(of: "^[A-Za-z0-9][A-Za-z0-9:_-]*$", options: .regularExpression) != nil else { continue }
                        names.insert(name); skills.append(skill)
                    } catch is CancellationError { throw CancellationError() }
                    catch { problem(path) }
                }
                guard try ClaudeSkillFiles.identity(root.path, directory: true) == rootIdentity else { throw ProviderSkillError(.unavailable) }
            } catch is CancellationError { throw CancellationError() }
            catch { problem(root.path) }
        }
        guard try ClaudeSkillFiles.identity(cwd, directory: true) == anchor else { throw ProviderSkillError(.unavailable) }
        let result = ProviderSkillInventory(cwd: cwd, skills: skills.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }, problems: problems)
        try result.validate(); return result
    }
    private static func repositoryRoot(_ cwd: String) -> String? {
        var current = cwd
        for _ in 0..<256 {
            if ClaudeSkillFiles.exists(current + "/.git") { return current }
            let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
            if parent == current { return nil }; current = parent
        }
        return nil
    }
    private static func pluginRepositoryRoot(_ cwd: String) -> String? {
        guard let root = repositoryRoot(cwd) else { return nil }
        guard let raw = try? ClaudeSkillFiles.text(root + "/.git", maximum: 16_384), raw.hasPrefix("gitdir:"),
              let directory = raw.split(separator: "\n").first.map({ String($0.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines) }), !directory.isEmpty else { return root }
        let git = ClaudeSkillFiles.path(directory, relativeTo: root)
        guard let common = try? ClaudeSkillFiles.text(git + "/commondir", maximum: 16_384),
              let backlink = try? ClaudeSkillFiles.text(git + "/gitdir", maximum: 16_384) else { return root }
        let shared = ClaudeSkillFiles.path(common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: git)
        let back = ClaudeSkillFiles.path(backlink.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: git)
        guard URL(fileURLWithPath: git).deletingLastPathComponent().path == shared + "/worktrees",
              URL(fileURLWithPath: back).resolvingSymlinksInPath().path == URL(fileURLWithPath: root + "/.git").resolvingSymlinksInPath().path else { return root }
        return URL(fileURLWithPath: shared).lastPathComponent == ".git" ? URL(fileURLWithPath: shared).deletingLastPathComponent().path : shared
    }
    private static func pluginRoots(_ configuration: ClaudeSkillDiscoveryConfiguration, settings: Settings,
                                    problem: (String?) -> Void) -> [Root] {
        let cwd = configuration.runtime.workspacePath
        let cache: String
        if var raw = configuration.pluginCacheDirectory {
            if raw == "~" { raw = configuration.homeDirectory }
            else if raw.hasPrefix("~/") { raw = configuration.homeDirectory + String(raw.dropFirst()) }
            cache = ClaudeSkillFiles.path(raw, relativeTo: cwd)
        } else { cache = configuration.runtime.configurationDirectory + "/plugins" }
        do {
            guard let text = try ClaudeSkillFiles.text(cache + "/installed_plugins.json", maximum: 4_194_304) else { return [] }
            guard let plugins = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let records = plugins["plugins"] as? [String: Any], records.count <= 256,
                  records.values.allSatisfy({ ($0 as? [Any]).map { $0.count <= 256 } == true }) else { throw ProviderSkillError(.invalidResponse) }
            var roots: [Root] = []
            for key in records.keys.sorted() where settings.plugins[key] == true {
                guard let rawEntries = records[key] as? [Any] else { throw ProviderSkillError(.invalidResponse) }
                let entries = rawEntries.compactMap { $0 as? [String: Any] }
                let applicable = entries.filter { entry in
                    guard let scope = entry["scope"] as? String, ["user", "managed", "project", "local"].contains(scope), let install = entry["installPath"] as? String,
                          (try? SkillValidation.text(install, maximum: 4_096, empty: false)) != nil else { return false }
                    if scope == "user" || scope == "managed" { return true }
                    guard let project = entry["projectPath"] as? String, (try? SkillValidation.text(project, maximum: 4_096, empty: false)) != nil else { return false }
                    let path = ClaudeSkillFiles.path(project, relativeTo: cwd)
                    return path.utf8.elementsEqual(cwd.utf8) || (pluginRepositoryRoot(cwd).map { pluginRepositoryRoot(path) == $0 } ?? false)
                }
                guard let install = applicable.first(where: { ClaudeSkillFiles.exists(ClaudeSkillFiles.path($0["installPath"] as! String, relativeTo: cwd)) }) ?? applicable.first,
                      let rawPath = install["installPath"] as? String, let installScope = install["scope"] as? String else { continue }
                let path = ClaudeSkillFiles.path(rawPath, relativeTo: cwd), scope = ["user", "managed"].contains(installScope) ? "user" : "project"
                var manifest: [String: Any] = [:]
                do {
                    if let raw = try ClaudeSkillFiles.text(path + "/.claude-plugin/plugin.json") {
                        guard let parsed = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                              parsed["name"].map({ ($0 as? String).map { !$0.isEmpty } == true }) ?? true,
                              parsed["skills"].map({ $0 is String || $0 is [String] }) ?? true else { throw ProviderSkillError(.invalidResponse) }; manifest = parsed
                    }
                } catch { problem(path + "/.claude-plugin/plugin.json") }
                let prefix = manifest["name"] as? String ?? String(key.split(separator: "@").first ?? "")
                guard prefix.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*$", options: .regularExpression) != nil else { continue }
                let hasDefault = ClaudeSkillFiles.exists(path + "/skills")
                if hasDefault { roots.append(.init(path: path + "/skills", scope: scope, prefix: prefix)) }
                if manifest["skills"] == nil, !hasDefault, ClaudeSkillFiles.exists(path + "/SKILL.md") { roots.append(.init(path: path, scope: scope, prefix: prefix)) }
                let declared: [String]
                if let single = manifest["skills"] as? String { declared = [single] }
                else if let multiple = manifest["skills"] as? [String] { declared = multiple }
                else { declared = [] }
                guard declared.count <= 256 else { throw ProviderSkillError(.invalidResponse) }
                let physical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                for relative in declared {
                    try SkillValidation.text(relative, maximum: 4_096, empty: false)
                    let candidate = ClaudeSkillFiles.path(relative, relativeTo: path)
                    guard ClaudeSkillFiles.inside(candidate, root: path), ClaudeSkillFiles.inside(URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path, root: physical) else { continue }
                    roots.append(.init(path: candidate, scope: scope, prefix: prefix))
                }
            }
            return roots
        } catch { problem(cache); return [] }
    }
}
