import Foundation

/// Pinned T3 editor identifiers, plus Xcode as an explicit native macOS addition.
public enum ExternalEditorID: String, Codable, CaseIterable, Identifiable, Sendable {
    case cursor, trae, kiro, vscode
    case vscodeInsiders = "vscode-insiders"
    case vscodium, zed, antigravity, idea, aqua, clion, datagrip, dataspell, goland
    case phpstorm, pycharm, rider, rubymine, rustrover, webstorm
    case fileManager = "file-manager"
    case xcode
    public var id: String { rawValue }
}

public struct ExternalEditorDescriptor: Identifiable, Sendable, Equatable {
    public let id: ExternalEditorID
    public init(id: ExternalEditorID) { self.id = id }
    public var name: String { ExternalEditorCatalog.definition(id).name }
    public var supportsLine: Bool { id != .fileManager }
    public var supportsColumn: Bool { supportsLine && id != .xcode }
}

public struct ExternalEditorLocation: Sendable, Equatable {
    public let line: Int
    public let column: Int?
    /// Positions are one-based. A column is meaningful only together with a line.
    public init(line: Int, column: Int? = nil) throws {
        guard (1...Int(Int32.max)).contains(line), column.map({ (1...Int(Int32.max)).contains($0) }) ?? true else {
            throw ExternalEditorError(.invalidLocation, "Use a positive line and column within the editor's supported range.")
        }
        self.line = line; self.column = column
    }
}

public struct ExternalEditorTarget: Sendable, Equatable {
    public let workspaceRoot: URL
    public let relativePath: String?
    public let location: ExternalEditorLocation?
    public init(workspaceRoot: URL, relativePath: String? = nil, location: ExternalEditorLocation? = nil) {
        self.workspaceRoot = workspaceRoot; self.relativePath = relativePath; self.location = location
    }
}

public struct ExternalEditorError: Error, LocalizedError, Sendable, Equatable {
    public enum Failure: Sendable, Equatable { case invalidLocation, invalidTarget, invalidInstallation, unavailable, launchFailed, closed }
    public let failure: Failure
    public let message: String
    public var errorDescription: String? { message }
    public init(_ failure: Failure, _ message: String) { self.failure = failure; self.message = message }
}

/// A launch request, rather than an assertion that the other app displayed the document.
public enum ExternalEditorLaunchPlan: Sendable, Equatable {
    case defaultApplication(URL)
    case reveal(URL)
    case application(applicationURL: URL, targetURL: URL)
    case command(executableURL: URL, arguments: [String])
}

public enum ExternalEditorCatalog {
    enum Style: Equatable { case goto, direct, lineColumn, xcode, system }
    struct Definition {
        let name: String
        let bundleNames: [String]
        let bundleIDs: [String]
        let launchers: [String]
        let style: Style
    }
    public static var editors: [ExternalEditorDescriptor] { ExternalEditorID.allCases.map { .init(id: $0) } }
    public static func bundleIdentifiers(for id: ExternalEditorID) -> [String] { definition(id).bundleIDs }
    public static func bundleNames(for id: ExternalEditorID) -> [String] { definition(id).bundleNames }

    static func definition(_ id: ExternalEditorID) -> Definition {
        func code(_ name: String, _ names: [String], _ ids: [String], _ commands: [String]) -> Definition {
            .init(name: name, bundleNames: names, bundleIDs: ids,
                  launchers: commands.map { "Contents/Resources/app/bin/" + $0 }, style: .goto)
        }
        func jetbrains(_ name: String, _ names: [String]? = nil, _ ids: [String]? = nil) -> Definition {
            .init(name: name, bundleNames: names ?? [name], bundleIDs: ids ?? ["com.jetbrains." + id.rawValue],
                  launchers: ["Contents/MacOS/" + id.rawValue], style: .lineColumn)
        }
        switch id {
        case .cursor: return code("Cursor", ["Cursor"], ["com.todesktop.230313mzl4w4u92"], ["cursor", "code"])
        case .trae: return code("Trae", ["Trae"], ["com.trae.app"], ["trae", "code"])
        case .kiro: return code("Kiro", ["Kiro"], ["dev.kiro.desktop"], ["kiro", "code"])
        case .vscode: return code("VS Code", ["Visual Studio Code"], ["com.microsoft.VSCode"], ["code"])
        case .vscodeInsiders: return code("VS Code Insiders", ["Visual Studio Code - Insiders"], ["com.microsoft.VSCodeInsiders"], ["code-insiders", "code"])
        case .vscodium: return code("VSCodium", ["VSCodium"], ["com.vscodium"], ["codium", "code"])
        case .antigravity: return code("Antigravity IDE", ["Antigravity IDE"], ["com.google.antigravity-ide"], ["antigravity-ide", "agy-ide", "code"])
        case .zed: return .init(name: "Zed", bundleNames: ["Zed"], bundleIDs: ["dev.zed.Zed"], launchers: ["Contents/MacOS/cli"], style: .direct)
        case .idea: return jetbrains("IntelliJ IDEA", ["IntelliJ IDEA", "IntelliJ IDEA CE", "IntelliJ IDEA Ultimate"], ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"])
        case .aqua: return jetbrains("Aqua", nil, ["com.jetbrains.aqua", "com.jetbrains.aqua-EAP"])
        case .clion: return jetbrains("CLion", nil, ["com.jetbrains.CLion"])
        case .datagrip: return jetbrains("DataGrip")
        case .dataspell: return jetbrains("DataSpell")
        case .goland: return jetbrains("GoLand")
        case .phpstorm: return jetbrains("PhpStorm", nil, ["com.jetbrains.PhpStorm"])
        case .pycharm: return jetbrains("PyCharm", ["PyCharm", "PyCharm CE"], ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce", "com.jetbrains.pycharm.edu"])
        case .rider: return jetbrains("Rider", ["Rider", "JetBrains Rider"])
        case .rubymine: return jetbrains("RubyMine")
        case .rustrover: return jetbrains("RustRover")
        case .webstorm: return jetbrains("WebStorm", nil, ["com.jetbrains.WebStorm"])
        case .fileManager: return .init(name: "Default Application", bundleNames: [], bundleIDs: [], launchers: [], style: .system)
        case .xcode: return .init(name: "Xcode", bundleNames: ["Xcode"], bundleIDs: ["com.apple.dt.Xcode"], launchers: ["Contents/Developer/usr/bin/xed"], style: .xcode)
        }
    }

    static func acceptsBundleName(_ name: String, id: ExternalEditorID) -> Bool {
        let definition = definition(id)
        return definition.bundleNames.contains { base in
            if name == base + ".app" { return true }
            guard definition.style == .lineColumn, name.hasPrefix(base + " "), name.hasSuffix(".app") else { return false }
            let version = name.dropFirst(base.count + 1).dropLast(4)
            return !version.isEmpty && version.first?.isNumber == true && version.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
        }
    }

    public static func plan(editor: ExternalEditorID, installation: ExternalEditorInstallation?,
                            metadata: WorkspaceFileMetadata, location: ExternalEditorLocation? = nil) throws -> ExternalEditorLaunchPlan {
        guard metadata.resolvedURL.isFileURL, metadata.resolvedURL.path.hasPrefix("/"),
              !metadata.resolvedURL.path.contains("\0") else {
            throw ExternalEditorError(.invalidTarget, "Choose an existing local workspace file or folder.")
        }
        guard metadata.kind == .file || location == nil else {
            throw ExternalEditorError(.invalidLocation, "A line or column can only be selected in a file.")
        }
        if editor == .fileManager { return .defaultApplication(metadata.resolvedURL) }
        guard let installation, installation.id == editor else {
            throw ExternalEditorError(.unavailable, "This editor is no longer available. Refresh the installed editors and choose another.")
        }
        if location == nil, editor != .cursor {
            return .application(applicationURL: installation.applicationURL, targetURL: metadata.resolvedURL)
        }
        let path = metadata.resolvedURL.path, definition = definition(editor)
        let arguments: [String]
        switch definition.style {
        case .goto:
            let base = editor == .cursor ? ["--classic"] : []
            arguments = base + (location.map { ["--goto", positioned(path, $0)] } ?? [path])
        case .direct: arguments = [location.map { positioned(path, $0) } ?? path]
        case .lineColumn:
            arguments = location.map { ["--line", String($0.line)] + ($0.column.map { ["--column", String($0)] } ?? []) + [path] } ?? [path]
        case .xcode: arguments = location.map { ["--line", String($0.line), path] } ?? [path]
        case .system: return .defaultApplication(metadata.resolvedURL)
        }
        return .command(executableURL: installation.executableURL, arguments: arguments)
    }
    private static func positioned(_ path: String, _ location: ExternalEditorLocation) -> String {
        path + ":" + String(location.line) + (location.column.map { ":" + String($0) } ?? "")
    }
}
