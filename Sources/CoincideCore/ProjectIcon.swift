import Darwin
import Foundation

/// Two-character fallback icon derived from the project name, matching T3: `Nebula` → `NA`,
/// `Silver Orchard` → `SO`, `M7 Forge` → `M7`, with a stable palette color.
public struct ProjectMonogram: Sendable, Equatable {
    public let text: String
    public let color: ProjectIconColor
    public init(name: String) {
        let normalized = name.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        text = Self.text(normalized)
        let seed = normalized.lowercased(with: Locale(identifier: "en_US"))
        var index = 0
        for scalar in (seed.isEmpty ? "project" : seed).unicodeScalars { index = (index * 31 + Int(scalar.value)) % ProjectIconColor.allCases.count }
        color = ProjectIconColor.allCases[index]
    }
    private static func text(_ name: String) -> String {
        var words: [String] = [], current = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber:
                current.append(scalar)
            default:
                if !current.isEmpty { words.append(String(current)); current = .init() }
            }
        }
        if !current.isEmpty { words.append(String(current)) }
        guard let firstWord = words.first, let first = firstWord.first else { return "PR" }
        let glyphs = Array(firstWord)
        let second = glyphs.dropFirst().first(where: \.isNumber) ?? (words.count > 1 ? words.last?.first : glyphs.last) ?? first
        return String(String([first, second]).uppercased().prefix(2))
    }
}

public struct ProjectIconAsset: Sendable, Equatable {
    public let relativePath: String
    public let data: Data
    public var fileExtension: String { URL(fileURLWithPath: relativePath).pathExtension.lowercased() }
}

/// Reads a bounded image from inside a checkout. Paths resolve through the anchored workspace file
/// service, so links cannot escape the root; nothing is executed or written.
public enum ProjectIconResolver {
    public static let maximumBytes = 1_048_576
    /// T3's built-in candidate locations, checked after t3.json `iconPath`.
    public static let candidates = [
        "favicon.svg", "favicon.ico", "favicon.png", "public/favicon.svg", "public/favicon.ico", "public/favicon.png",
        "app/favicon.ico", "app/favicon.png", "app/icon.svg", "app/icon.png", "app/icon.ico", "src/favicon.ico", "src/favicon.svg",
        "src/app/favicon.ico", "src/app/icon.svg", "src/app/icon.png", "assets/icon.svg", "assets/icon.png", "assets/logo.svg",
        "assets/logo.png", ".idea/icon.svg", "Resources/AppIcon.icns", "AppIcon.icns", "icon.svg"
    ]
    public static func isRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") && path.utf16.count <= 1_024 &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    /// `preferred` paths (an explicit image override, then t3.json `iconPath`) are tried before the candidates.
    public static func resolve(using files: WorkspaceFileService, preferred: [String] = []) async throws -> ProjectIconAsset? {
        var seen: Set<String> = []
        for path in preferred + candidates where seen.insert(path).inserted && isRelativePath(path) &&
            ProjectIconOverride.imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
            try Task.checkCancellation()
            let data: Data
            do { data = try await files.readBinary(relativePath: path, maxBytes: maximumBytes) }
            catch is CancellationError { throw CancellationError() }
            catch let error as WorkspaceFileError where [.closed, .rootMissing, .rootNotDirectory, .rootReplaced].contains(error.failure) { throw error }
            catch { continue }
            guard !data.isEmpty else { continue }
            return .init(relativePath: path, data: data)
        }
        return nil
    }
}
