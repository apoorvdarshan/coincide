import Foundation

/// Port of T3's `removeAgentCredits`: removes recognized coding-agent `Co-authored-by` trailers
/// and "Generated with/by <agent>" footers from a merge commit body. Human co-authors, examples
/// inside fenced or indented code, block quotes and ordinary prose are preserved.
public enum PullRequestMergeMessage {
    static let agentEmails: Set<String> = ["noreply@anthropic.com", "claude@anthropic.com", "noreply@openai.com", "codex@openai.com",
                                           "cursoragent@cursor.com", "copilot@github.com", "noreply@github.com"]

    public static func removeAgentCredits(_ message: String) -> String {
        let newline = message.contains("\r\n") ? "\r\n" : "\n"
        let lines = message.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var fence: String?, removed = false, kept: [String] = []
        for line in lines {
            if line.hasPrefix("    ") || line.hasPrefix("\t") { kept.append(line); continue }
            if let (marker, remainder) = fenceDelimiter(line) {
                if let open = fence {
                    if marker.first == open.first, marker.count >= open.count, remainder.allSatisfy({ $0 == " " || $0 == "\t" }) { fence = nil }
                } else if marker.first == "~" || !remainder.contains("`") { fence = marker }
                kept.append(line); continue
            }
            if fence != nil { kept.append(line); continue }
            let text = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^[-*]\\s+", with: "", options: .regularExpression)
            if isAgentAuthor(text) || isGeneratedFooter(text) { removed = true; continue }
            kept.append(line)
        }
        guard removed else { return message }
        // Only trailing blank lines are trimmed; the last kept line's own text stays intact.
        return kept.joined(separator: newline).replacingOccurrences(of: "(?:\\r?\\n[ \\t]*)+$", with: "", options: .regularExpression)
    }

    private static func fenceDelimiter(_ line: String) -> (String, Substring)? {
        let leading = line.prefix { $0 == " " }
        guard leading.count <= 3 else { return nil }
        let rest = line.dropFirst(leading.count)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let marker = rest.prefix { $0 == first }
        guard marker.count >= 3 else { return nil }
        return (String(marker), rest.dropFirst(marker.count))
    }

    private static func isAgentAuthor(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "^co-authored-by:\\s*(.*?)\\s*<([^<>]+)>\\s*$", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text), let emailRange = Range(match.range(at: 2), in: text) else { return false }
        let email = text[emailRange].lowercased(), name = String(text[nameRange])
        guard agentEmails.contains(email) else { return false }
        // GitHub's generic noreply address is also used by people; require Copilot's name.
        return email != "noreply@github.com" || name.range(of: "^(github copilot|copilot)$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isGeneratedFooter(_ text: String) -> Bool {
        let footer = text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(https://(?:claude\\.ai|www\\.anthropic\\.com|chatgpt\\.com|openai\\.com|cursor\\.com|github\\.com|opencode\\.ai|x\\.ai|antigravity\\.google)(?:/[^\\s)]*)?\\)",
                                               with: "$1", options: [.regularExpression, .caseInsensitive])
        return footer.range(of: "^(?:🤖\\s*)?generated (?:with|by)\\s+(?:claude(?: code)?|codex|cursor|github copilot|copilot|opencode|grok|antigravity)[.!]?$",
                            options: [.regularExpression, .caseInsensitive]) != nil
    }
}
