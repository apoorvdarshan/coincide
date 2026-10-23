import CryptoKit
import Foundation

/// One runnable entry: an app-owned action, or a t3.json script that still needs explicit review.
public struct ResolvedProjectScript: Sendable, Equatable, Identifiable {
    public enum Source: Sendable, Equatable { case projectAction(ProjectAction), checkoutFile(index: Int) }
    /// Action IDs are stable; file entries use a name/command digest so a remembered choice survives reordering.
    public let id: String
    public let script: ProjectScript
    public let source: Source
    public var action: ProjectAction? { if case .projectAction(let value) = source { value } else { nil } }
    public var fileIndex: Int? { if case .checkoutFile(let index) = source { index } else { nil } }
    public var menuLabel: String { ProjectActions.menuLabel(name: script.name, setup: script.runOnWorktreeCreate, settle: script.runOnSettle) }
    public var shortcut: ProjectActionShortcut? { action?.shortcut }
    public static func fileID(_ script: ProjectScript) -> String {
        "file-" + SHA256.hash(data: Data((script.name + "\0" + script.command).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// T3's resolution: a project's own action list overrides the checkout's t3.json scripts.
public struct ProjectScriptCatalog: Sendable, Equatable {
    public enum Origin: Sendable, Equatable { case projectActions, checkoutFile, none }
    public let origin: Origin
    public let scripts: [ResolvedProjectScript]
    /// t3.json scripts not yet imported into this project's actions.
    public let importable: [ProjectScript]
    public init(actions: [ProjectAction]?, configuration: ProjectConfiguration?) {
        let file = configuration?.scripts ?? []
        if let actions {
            origin = .projectActions
            scripts = actions.compactMap { action in (try? action.script()).map { .init(id: action.id, script: $0, source: .projectAction(action)) } }
            importable = ProjectActions.importable(file, existing: actions)
        } else {
            origin = file.isEmpty ? .none : .checkoutFile
            scripts = file.enumerated().map { .init(id: ResolvedProjectScript.fileID($0.element), script: $0.element, source: .checkoutFile(index: $0.offset)) }
            importable = file
        }
    }
    /// The remembered script, else the first without a role, else the first that does not settle.
    public func primary(preferredID: String?) -> ResolvedProjectScript? {
        if let preferredID, let value = scripts.first(where: { $0.id == preferredID }) { return value }
        return scripts.first { !$0.script.runOnWorktreeCreate && !$0.script.runOnSettle } ?? scripts.first { !$0.script.runOnSettle }
    }
    public func script(for role: ProjectScriptRole) -> ResolvedProjectScript? {
        scripts.first { role == .setup ? $0.script.runOnWorktreeCreate : $0.script.runOnSettle }
    }
}

public enum ProjectSettingSource: String, Sendable, Equatable {
    case project, app, repository, builtIn
    public var title: String {
        switch self {
        case .project: String(localized: "Project")
        case .app: String(localized: "All projects")
        case .repository: String(localized: "t3.json")
        case .builtIn: String(localized: "Default")
        }
    }
}

public struct ProjectResolvedSetting<Value: Sendable & Equatable>: Sendable, Equatable {
    public let value: Value
    public let source: ProjectSettingSource
    public init(value: Value, source: ProjectSettingSource) { self.value = value; self.source = source }
}

/// Four-tier resolution for repository-declarable settings: project override, app default,
/// the checkout's t3.json, then T3's built-in value. A nil tier means Inherit.
public enum ProjectDefaultsResolver {
    public static let builtInThreadEnvironmentMode = ProjectThreadEnvironmentMode.local
    public static let builtInWorktreeSubmodules = ProjectWorktreeSubmoduleMode.recursive
    public static func threadEnvironmentMode(project: ProjectThreadEnvironmentMode?, app: ProjectThreadEnvironmentMode?,
                                             repository: ProjectConfiguration?) -> ProjectResolvedSetting<ProjectThreadEnvironmentMode> {
        resolve(project, app, repository?.defaultThreadEnvMode, builtInThreadEnvironmentMode)
    }
    public static func worktreeSubmodules(project: ProjectWorktreeSubmoduleMode?, app: ProjectWorktreeSubmoduleMode?,
                                          repository: ProjectConfiguration?) -> ProjectResolvedSetting<ProjectWorktreeSubmoduleMode> {
        resolve(project, app, repository?.worktreeSubmodules, builtInWorktreeSubmodules)
    }
    private static func resolve<Value>(_ project: Value?, _ app: Value?, _ repository: Value?, _ builtIn: Value) -> ProjectResolvedSetting<Value> {
        if let project { return .init(value: project, source: .project) }
        if let app { return .init(value: app, source: .app) }
        if let repository { return .init(value: repository, source: .repository) }
        return .init(value: builtIn, source: .builtIn)
    }
}
