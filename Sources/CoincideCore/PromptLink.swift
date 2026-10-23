import Foundation

/// `coincide://` links (T3 promptLinks.ts). A link only opens a draft or a folder; it never
/// sends, queues or steers anything, and cannot change permissions, branches or worktrees.
public enum PromptLink {
    public static let scheme = "coincide"
    public static let maximumPromptLength = 8_000

    public struct Repository: Sendable, Equatable {
        public let owner: String
        public let name: String
        public var canonicalKey: String { "github.com/\(owner)/\(name)".lowercased() }
        public var slug: String { "\(owner)/\(name)" }
    }
    public struct PullRequest: Sendable, Equatable {
        public let repository: Repository
        public let number: Int
        public var url: URL { URL(string: "https://github.com/\(repository.owner)/\(repository.name)/pull/\(number)")! }
    }
    public struct Prompt: Sendable, Equatable {
        public let text: String
        /// Zero-width, bidi, tag and similar characters that were removed. They can hide
        /// instructions for an agent from the person reading the draft.
        public let hiddenCharacters: Int
    }
    public enum Link: Sendable, Equatable {
        case newThread(prompt: Prompt, repository: Repository?, provider: String?, model: String?)
        case pullRequest(PullRequest, prompt: Prompt?)
        case thread(id: UUID, prompt: Prompt?)
        case openFolder(path: String)
    }
    public enum ParseError: Error, Equatable, LocalizedError {
        case unsupported, tooLong, hiddenOnly, missingPrompt, invalidRepository, invalidPullRequest, invalidThread, invalidPath
        public var errorDescription: String? {
            switch self {
            case .unsupported: String(localized: "Coincide cannot open this link.")
            case .tooLong: String(localized: "This prompt is longer than 8,000 characters, so Coincide did not open it.")
            case .hiddenOnly: String(localized: "This prompt had only hidden characters, so it may be malicious. Coincide did not open it.")
            case .missingPrompt: String(localized: "This link has no prompt.")
            case .invalidRepository: String(localized: "This link names a repository Coincide cannot read.")
            case .invalidPullRequest: String(localized: "This link names a pull request Coincide cannot read.")
            case .invalidThread: String(localized: "This link names a conversation Coincide cannot read.")
            case .invalidPath: String(localized: "This link names a folder Coincide cannot read.")
            }
        }
    }

    // MARK: Sanitizing

    private static let hiddenRanges: [ClosedRange<UInt32>] = [
        0x0000...0x0008, 0x000B...0x000C, 0x000E...0x001F, 0x007F...0x009F, 0x00AD...0x00AD, 0x034F...0x034F, 0x061C...0x061C,
        0x115F...0x1160, 0x17B4...0x17B5, 0x180B...0x180F, 0x200B...0x200C, 0x200E...0x200F, 0x202A...0x202E, 0x2060...0x206F,
        0x3164...0x3164, 0xFE00...0xFE0D, 0xFEFF...0xFEFF, 0xFFA0...0xFFA0, 0xFFF0...0xFFFB, 0x1BCA0...0x1BCA3, 0x1D173...0x1D17A,
        0xE0000...0xE0FFF,
    ]
    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool { hiddenRanges.contains { $0.contains(scalar.value) } }
    private static func isEmojiPart(_ scalar: Unicode.Scalar?) -> Bool {
        guard let value = scalar?.value else { return false }
        return (0x1F000...0x1FAFF).contains(value) || (0x2190...0x2BFF).contains(value) || value == 0xFE0F
    }

    /// Normalizes line breaks, removes characters a reader cannot see and trims the result.
    /// A zero-width joiner survives only inside an emoji sequence.
    public static func sanitize(_ raw: String) -> Prompt {
        var hidden = 0
        var visible: [Unicode.Scalar] = []
        var previousCR = false
        for scalar in raw.unicodeScalars {
            if scalar == "\r" { visible.append("\n"); previousCR = true; continue }
            defer { previousCR = false }
            if scalar == "\n" { if !previousCR { visible.append("\n") }; continue }
            if scalar.value == 0x2028 || scalar.value == 0x2029 { visible.append("\n"); continue }
            if isHidden(scalar) { hidden += 1; continue }
            visible.append(scalar)
        }
        var kept = String.UnicodeScalarView()
        for (index, scalar) in visible.enumerated() {
            if scalar.value == 0x200D {
                guard isEmojiPart(index > 0 ? visible[index - 1] : nil), isEmojiPart(index + 1 < visible.count ? visible[index + 1] : nil) else { hidden += 1; continue }
            }
            kept.append(scalar)
        }
        return .init(text: String(kept).trimmingCharacters(in: .whitespacesAndNewlines), hiddenCharacters: hidden)
    }

    // MARK: Repositories and pull requests

    private static func matches(_ value: String, _ pattern: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: value).map { String(value[$0]) } ?? "" }
    }
    private static func repository(owner: String, name: String) -> Repository? {
        var trimmed = name
        if trimmed.lowercased().hasSuffix(".git") { trimmed.removeLast(4) }
        guard matches(owner, #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"#) != nil, matches(trimmed, #"^[A-Za-z0-9._-]{1,100}$"#) != nil,
              !trimmed.allSatisfy({ $0 == "." }) else { return nil }
        return .init(owner: owner, name: trimmed)
    }
    /// `owner/name` or a github.com repository URL.
    public static func repository(_ value: String) -> Repository? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = matches(trimmed, #"^https?://(?:www\.)?github\.com/([^/?#]+)/([^/?#]+)/?$"#) ?? matches(trimmed, #"^([^/\s]+)/([^/\s]+)$"#) else { return nil }
        return repository(owner: parts[1], name: parts[2])
    }
    /// `owner/name/123`, `owner/name#123` or a github.com pull request URL.
    public static func pullRequest(_ value: String) -> PullRequest? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = matches(trimmed, #"^https?://(?:www\.)?github\.com/([^/?#]+)/([^/?#]+)/pull/(\d+)(?:[/?#].*)?$"#)
                ?? matches(trimmed, #"^([^/\s#]+)/([^/\s#]+)(?:/|#)(\d+)$"#),
              let repository = repository(owner: parts[1], name: parts[2]), let number = Int(parts[3]), number > 0 else { return nil }
        return .init(repository: repository, number: number)
    }

    // MARK: Parsing

    /// URLSearchParams semantics: `+` is a space and the first value wins.
    static func queryValues(_ url: URL) -> [String: String]? {
        guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery, !query.isEmpty else { return [:] }
        var values: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = String(pieces[0]).replacingOccurrences(of: "+", with: "%20").removingPercentEncoding,
                  let value = (pieces.count > 1 ? String(pieces[1]) : "").replacingOccurrences(of: "+", with: "%20").removingPercentEncoding else { return nil }
            if values[key] == nil { values[key] = value }
        }
        return values
    }

    private static func prompt(_ values: [String: String]) -> Result<Prompt?, ParseError> {
        guard let raw = values["prompt"] else { return .success(nil) }
        guard raw.utf16.count <= maximumPromptLength else { return .failure(.tooLong) }
        let prompt = sanitize(raw)
        if prompt.text.isEmpty && prompt.hiddenCharacters > 0 { return .failure(.hiddenOnly) }
        return .success(prompt.text.isEmpty ? nil : prompt)
    }

    public static func parse(_ url: URL) -> Result<Link, ParseError> {
        guard url.scheme?.lowercased() == scheme, let host = url.host?.lowercased(), let values = queryValues(url) else { return .failure(.unsupported) }
        let path = url.path
        switch host {
        case "new":
            guard path.isEmpty || path == "/" else { return .failure(.unsupported) }
            let prompt: Prompt?
            switch self.prompt(values) { case .success(let value): prompt = value; case .failure(let error): return .failure(error) }
            if let raw = values["pr"] {
                guard let pullRequest = pullRequest(raw) else { return .failure(.invalidPullRequest) }
                return .success(.pullRequest(pullRequest, prompt: prompt))
            }
            guard let prompt else { return .failure(.missingPrompt) }
            var repository: Repository?
            if let raw = values["repo"] {
                guard let parsed = self.repository(raw) else { return .failure(.invalidRepository) }
                repository = parsed
            }
            let provider = values["provider"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let model = values["model"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(.newThread(prompt: prompt, repository: repository, provider: provider?.isEmpty == false ? provider : nil,
                                       model: model?.isEmpty == false ? model : nil))
        case "threads":
            let components = path.split(separator: "/").map(String.init)
            guard components.count == 1, let id = UUID(uuidString: components[0]) else { return .failure(.invalidThread) }
            switch self.prompt(values) {
            case .success(let prompt): return .success(.thread(id: id, prompt: prompt))
            case .failure(let error): return .failure(error)
            }
        case "open":
            guard path.isEmpty || path == "/", let raw = values["path"], raw.hasPrefix("/"), !raw.contains("\0"), raw.utf8.count <= 4_096 else {
                return .failure(.invalidPath)
            }
            return .success(.openFolder(path: URL(fileURLWithPath: raw).standardizedFileURL.path))
        default:
            return .failure(.unsupported)
        }
    }

    // MARK: Building

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static func url(host: String, path: String = "", items: [(String, String)]) -> URL? {
        var components = URLComponents()
        components.scheme = scheme; components.host = host; components.path = path
        let encoded = items.compactMap { key, value in value.addingPercentEncoding(withAllowedCharacters: unreserved).map { "\(key)=\($0)" } }
        guard encoded.count == items.count else { return nil }
        if !encoded.isEmpty { components.percentEncodedQuery = encoded.joined(separator: "&") }
        return components.url
    }
    public static func newThreadURL(prompt: String, repository: Repository? = nil, provider: String? = nil, model: String? = nil) -> URL? {
        var items = [("prompt", prompt)]
        if let repository { items.append(("repo", repository.slug)) }
        if let provider, !provider.isEmpty {
            items.append(("provider", provider))
            if let model, !model.isEmpty { items.append(("model", model)) }
        }
        return url(host: "new", items: items)
    }
    public static func threadURL(id: UUID, prompt: String? = nil) -> URL? {
        url(host: "threads", path: "/" + id.uuidString.lowercased(), items: prompt.map { [("prompt", $0)] } ?? [])
    }
    public static func openFolderURL(path: String) -> URL? { url(host: "open", items: [("path", path)]) }
}
