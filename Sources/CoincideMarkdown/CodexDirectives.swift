import Foundation
import Markdown

public enum CodexArtifactTemplateKind: String, Sendable, CaseIterable {
    case document, presentation, spreadsheet, site, googleDocs = "google-docs", googleSlides = "google-slides", googleSheets = "google-sheets", image, email, slack
    public var label: String {
        switch self {
        case .document: "Document template"
        case .presentation: "Presentation template"
        case .spreadsheet: "Spreadsheet template"
        case .site: "Site template"
        case .googleDocs: "Google Doc template"
        case .googleSlides: "Google Slides template"
        case .googleSheets: "Google Sheet template"
        case .image: "Image template"
        case .email: "Email template"
        case .slack: "Slack template"
        }
    }
    var symbol: String {
        switch self {
        case .document, .googleDocs: "doc.text"
        case .presentation, .googleSlides: "rectangle.on.rectangle"
        case .spreadsheet, .googleSheets: "tablecells"
        case .site: "globe"
        case .image: "photo"
        case .email: "envelope"
        case .slack: "bubble.left.and.bubble.right"
        }
    }
}

public struct CodexArtifactTemplate: Sendable, Equatable {
    public var artifactKind: CodexArtifactTemplateKind
    public var displayName: String
    public var galleryKind: String?
    public var skillDirectory: String
    public var skillName: String

    /// T3's resolver: a known kind, a display name, an absolute skill directory and an
    /// `artifact-template-` skill. Anything else stays literal Markdown.
    public init?(attributes: [String: String?]) {
        guard let kind = (attributes["artifact_kind"] ?? nil).flatMap(CodexArtifactTemplateKind.init(rawValue:)),
              let name = (attributes["display_name"] ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let directory = attributes["skill_directory"] ?? nil,
              (directory.hasPrefix("/") && !directory.hasPrefix("//")) || directory.range(of: #"^[A-Za-z]:[\\/]|^(?:\\\\[^\\]+\\[^\\]+|//[^/]+/[^/]+)"#, options: .regularExpression) != nil,
              let skill = attributes["skill_name"] ?? nil, skill.hasPrefix("artifact-template-") else { return nil }
        let gallery = attributes["gallery_kind"] ?? nil
        if attributes.keys.contains("gallery_kind") { guard let gallery, ["imagegen", "product-design"].contains(gallery) else { return nil } }
        artifactKind = kind; displayName = name; galleryKind = gallery; skillDirectory = directory; skillName = skill
    }
}

/// Codex app directives: `:codex-file-citation{path line_range_start}`,
/// `:codex-followup[Label]{prompt}` and the leaf `::artifact-template{…}`.
public enum CodexDirectives {
    static let citation = Array("codex-file-citation".unicodeScalars), followUp = Array("codex-followup".unicodeScalars)

    struct Inline { var end: Int; var replacement: String; var isFollowUp: Bool }

    /// A text directive at `start` (the colon), rendered as T3's Markdown adapter does.
    static func inline(_ s: [Unicode.Scalar], at start: Int) -> Inline? {
        guard start + 1 < s.count, s[start] == ":" else { return nil }
        for (name, isFollowUp) in [(citation, false), (followUp, true)] {
            let nameEnd = start + 1 + name.count
            guard nameEnd <= s.count, Array(s[(start + 1)..<nameEnd]) == name else { continue }
            if nameEnd < s.count, s[nameEnd] == "-" || s[nameEnd] == "_" || s[nameEnd].properties.isAlphabetic || s[nameEnd].properties.numericType != nil { return nil }
            var index = nameEnd, label: String?
            if index < s.count, s[index] == "[" {
                guard let close = labelEnd(s, from: index) else { return nil }
                label = String(String.UnicodeScalarView(s[(index + 1)..<close])); index = close + 1
            }
            var attributes: [String: String?] = [:]
            if index < s.count, s[index] == "{" {
                guard let parsed = Self.attributes(s, from: index) else { return nil }
                attributes = parsed.values; index = parsed.end
            }
            if isFollowUp {
                guard let label, !label.allSatisfy(\.isWhitespace), let prompt = attributes["prompt"] ?? nil, !prompt.allSatisfy(\.isWhitespace) else { return nil }
                return Inline(end: index, replacement: label, isFollowUp: true)
            }
            guard let markdown = citationMarkdown(attributes) else { return nil }
            return Inline(end: index, replacement: markdown, isFollowUp: false)
        }
        return nil
    }

    /// `[basename](<path#L7>)` with the path's `%`, `#` and `?` escaped as T3 does.
    static func citationMarkdown(_ attributes: [String: String?]) -> String? {
        guard let path = (attributes["path"] ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        var destination = path.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "#", with: "%23").replacingOccurrences(of: "?", with: "%3F")
        if let raw = attributes["line_range_start"] ?? nil, let line = Int(raw.trimmingCharacters(in: .whitespaces)), line > 0 { destination += "#L\(line)" }
        let normalized = path.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        let base = normalized.split(separator: "/").last.map(String.init) ?? normalized
        let label = (base.isEmpty ? "File" : base).replacingOccurrences(of: #"[\\\[\]*_`<&]"#, with: #"\\$0"#, options: .regularExpression)
        destination = destination.replacingOccurrences(of: "\\", with: "%5C").replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
            .replacingOccurrences(of: "\r", with: "%0D").replacingOccurrences(of: "\n", with: "%0A")
        return "[\(label)](<\(destination)>)"
    }

    /// A whole-line `::artifact-template{…}` leaf directive.
    static func artifactLine(_ line: String) -> CodexArtifactTemplate? {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3, trimmed.hasPrefix("::artifact-template") else { return nil }
        let s = Array(trimmed.unicodeScalars)
        var index = "::artifact-template".unicodeScalars.count
        if index < s.count, s[index] == "[" { guard let close = labelEnd(s, from: index) else { return nil }; index = close + 1 }
        guard index < s.count, s[index] == "{", let parsed = attributes(s, from: index),
              s[parsed.end...].allSatisfy({ $0.properties.isWhitespace }) else { return nil }
        return CodexArtifactTemplate(attributes: parsed.values)
    }

    private static func labelEnd(_ s: [Unicode.Scalar], from start: Int) -> Int? {
        var depth = 0, index = start
        while index < s.count, s[index] != "\n" {
            switch s[index] {
            case "\\": index += 1
            case "[": depth += 1
            case "]": depth -= 1; if depth == 0 { return index }
            default: break
            }
            index += 1
        }
        return nil
    }

    /// micromark-extension-directive attributes: `key`, `key=value`, quoted values, `#id`, `.class`.
    static func attributes(_ s: [Unicode.Scalar], from start: Int) -> (values: [String: String?], end: Int)? {
        guard start < s.count, s[start] == "{" else { return nil }
        var values: [String: String?] = [:], index = start + 1
        func isNameCharacter(_ value: Unicode.Scalar) -> Bool {
            value.properties.isAlphabetic || value.properties.numericType != nil || "-_:.".unicodeScalars.contains(value)
        }
        while index < s.count {
            while index < s.count, s[index] == " " || s[index] == "\t" { index += 1 }
            guard index < s.count, s[index] != "\n" else { return nil }
            if s[index] == "}" { return (values, index + 1) }
            if s[index] == "#" || s[index] == "." {
                let key = s[index] == "#" ? "id" : "class"
                var end = index + 1
                while end < s.count, isNameCharacter(s[end]), s[end] != "." { end += 1 }
                guard end > index + 1 else { return nil }
                values[key] = String(String.UnicodeScalarView(s[(index + 1)..<end])); index = end; continue
            }
            var end = index
            while end < s.count, isNameCharacter(s[end]) { end += 1 }
            guard end > index else { return nil }
            let key = String(String.UnicodeScalarView(s[index..<end])); index = end
            guard index < s.count, s[index] == "=" else { values[key] = .some(nil); continue }
            index += 1
            guard index < s.count else { return nil }
            if s[index] == "\"" || s[index] == "'" {
                let quote = s[index]
                var close = index + 1
                while close < s.count, s[close] != quote, s[close] != "\n" { close += 1 }
                guard close < s.count, s[close] == quote else { return nil }
                values[key] = String(String.UnicodeScalarView(s[(index + 1)..<close])); index = close + 1
            } else {
                var close = index
                while close < s.count, !s[close].properties.isWhitespace, !"\"'=<>`}".unicodeScalars.contains(s[close]) { close += 1 }
                guard close > index else { return nil }
                values[key] = String(String.UnicodeScalarView(s[index..<close])); index = close
            }
        }
        return nil
    }

    /// Copy text for a message: citations become Markdown links, follow-ups their label and
    /// artifact templates `Name (Kind template)`. Code and HTML stay as authored.
    public static func renderForCopy(_ markdown: String) -> String {
        guard markdown.contains(":codex-") || markdown.contains("::artifact-template"), markdown.utf8.count <= 1_048_576 else { return markdown }
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var transform = MarkdownSourceTransform(math: false, footnotes: false, directives: true)
        var output = transform.apply(lines, excluded: MarkdownDocument.protectedLines(Document(parsing: normalized, options: [.disableSmartOpts])))
        for index in output.indices {
            guard let decoded = MarkdownSourceTransform.decode(output[index].trimmingCharacters(in: CharacterSet(charactersIn: "`"))), decoded.kind == "A",
                  decoded.index < transform.artifacts.count else { continue }
            let template = transform.artifacts[decoded.index]
            output[index] = "\(template.displayName) (\(template.artifactKind.label))"
        }
        return output.joined(separator: "\n")
    }
}
