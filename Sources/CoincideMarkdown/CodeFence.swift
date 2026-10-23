import Foundation

/// Fence info-string helpers ported from T3's MarkdownCodeBlock logic.
public enum CodeFence {
    /// `title="a.swift"`, `file=…`, `filename=…`, or a bare `name.ext` token in the fence meta.
    public static func title(_ meta: String) -> String? {
        let meta = meta.trimmingCharacters(in: .whitespaces)
        guard !meta.isEmpty else { return nil }
        if let match = meta.range(of: #"(?:^|\s)(?:title|file(?:name)?)=(?:"([^"]+)"|'([^']+)'|(\S+))"#, options: [.regularExpression, .caseInsensitive]) {
            let assignment = meta[match].trimmingCharacters(in: .whitespaces)
            guard let equals = assignment.firstIndex(of: "=") else { return nil }
            var value = assignment[assignment.index(after: equals)...]
            if let first = value.first, first == "\"" || first == "'", value.count >= 2, value.last == first { value = value.dropFirst().dropLast() }
            return value.isEmpty ? nil : String(value)
        }
        return meta.split(whereSeparator: \.isWhitespace).map(String.init)
            .first { $0.range(of: #"^[\w@][\w@./-]*\.[A-Za-z0-9]+$"#, options: .regularExpression) != nil }
    }

    static let shellLanguages: Set<String> = ["sh", "bash", "zsh", "fish", "shell", "powershell", "pwsh"]

    /// T3's Run predicate: a closed shell fence holding one non-empty line that does not
    /// continue with a backslash and has no control or invisible format characters, so the
    /// command shown is exactly what the terminal receives.
    public static func runnableCommand(language: String, code: String, closed: Bool, streaming: Bool) -> String? {
        guard closed, !streaming, shellLanguages.contains(language.lowercased()) else { return nil }
        let body = code.hasSuffix("\n") ? String(code.dropLast()) : code
        let command = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !command.hasSuffix("\\"),
              !body.unicodeScalars.contains(where: { [.control, .format].contains($0.properties.generalCategory) }) else { return nil }
        return command
    }
}
