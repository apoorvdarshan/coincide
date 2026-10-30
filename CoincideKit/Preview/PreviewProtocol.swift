import Foundation

/// The preview exposes a small command vocabulary, never arbitrary JavaScript. The only filesystem paths it takes are
/// the files `upload` attaches to a page, which the agent could read anyway.
public indirect enum PreviewCommand: Sendable, Equatable {
    case read
    case navigate(URL)
    case click(String)
    case input(selector: String, text: String)
    /// Attaches local files to the page's file input (the selector names it, or the button or label that opens it),
    /// answering the page's file chooser with them so no dialog appears.
    case upload(selector: String, files: [URL])
    case screenshot
    /// Opens the browser panel on this thread so the user can see the page.
    case show
    /// Shows the user a short "your turn" message with a Done button and waits for them, up to `timeout` seconds.
    case askUser(message: String, timeout: TimeInterval)
    /// Has Coincide sign in on the current page with a saved login (optionally named by `item`), after the user allows
    /// it. Coincide types the secrets itself; the reply carries the username at most.
    case fillLogin(item: String?)
    /// Lists the thread's tabs: id, URL, title, whether it is active and loading.
    case tabs
    /// Opens a tab (at `url`, or empty) and makes it active.
    case newTab(URL?)
    case selectTab(String)
    case closeTab(String)
    /// A page command for one tab rather than the active one.
    case inTab(String, PreviewCommand)

    /// The most tabs a thread can have.
    public static let tabLimit = 20
    /// The most files one `upload` attaches.
    public static let uploadLimit = 20

    /// How long the app lets the command run before answering with an error.
    public var timeout: TimeInterval {
        switch self {
        case .inTab(_, let command): return command.timeout
        case .askUser(_, let timeout): return timeout + 5
        // The user's approval, then the password manager (which may ask for Touch ID).
        case .fillLogin: return LoginApprovalGate.timeout + 90
        default: return 30
        }
    }

    public init(json: JSONValue) throws {
        let command = try Self.command(json)
        guard let tab = json["tab"] else {
            self = command
            return
        }
        // Page commands can name a tab; the tab commands name theirs themselves.
        guard let id = tab.string, Self.isTabID(id) else { throw PreviewError.invalidCommand }
        switch command {
        case .read, .navigate, .click, .input, .upload, .screenshot, .fillLogin: self = .inTab(id, command)
        case .selectTab, .closeTab: self = command
        default: throw PreviewError.invalidCommand
        }
    }

    static func isTabID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 32 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func tabID(_ json: JSONValue) throws -> String {
        guard let id = json["tab"]?.string, isTabID(id) else { throw PreviewError.invalidCommand }
        return id
    }

    private static func command(_ json: JSONValue) throws -> PreviewCommand {
        switch json["action"]?.string {
        case "read": return .read
        case "navigate":
            guard let address = json["url"]?.string, let url = Self.url(address) else {
                throw PreviewError.invalidAddress
            }
            return .navigate(url)
        case "click": return .click(try Self.selector(json))
        case "input":
            guard let text = json["text"]?.string, text.utf8.count <= 65_536 else { throw PreviewError.invalidCommand }
            return .input(selector: try Self.selector(json), text: text)
        case "upload":
            guard let paths = json["files"]?.array?.compactMap(\.string), (1...Self.uploadLimit).contains(paths.count),
                paths.count == json["files"]?.array?.count,
                paths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 })
            else { throw PreviewError.invalidCommand }
            return .upload(selector: try Self.selector(json), files: paths.map { URL(fileURLWithPath: $0).standardizedFileURL })
        case "screenshot": return .screenshot
        case "show": return .show
        case "fill-login":
            let item = json["item"]?.string
            guard (item?.utf8.count ?? 0) <= 200 else { throw PreviewError.invalidCommand }
            return .fillLogin(item: item)
        case "ask-user":
            guard let message = json["message"]?.string, message.utf8.count <= 4096 else { throw PreviewError.invalidCommand }
            let timeout = json["timeout"]?.number ?? UserTurnGate.defaultTimeout
            guard timeout.isFinite, timeout >= 1, timeout <= UserTurnGate.maximumTimeout else { throw PreviewError.invalidCommand }
            return .askUser(message: message, timeout: timeout)
        case "tabs": return .tabs
        case "new-tab":
            guard let address = json["url"]?.string else { return .newTab(nil) }
            guard let url = Self.url(address) else { throw PreviewError.invalidAddress }
            return .newTab(url)
        case "select-tab": return .selectTab(try tabID(json))
        case "close-tab": return .closeTab(try tabID(json))
        default: throw PreviewError.invalidCommand
        }
    }

    public static func url(_ address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 8192 else { return nil }
        if let colon = trimmed.firstIndex(of: ":"), !trimmed.contains("://"), !trimmed.hasPrefix("[") {
            let suffix = trimmed[trimmed.index(after: colon)...].split(separator: "/", maxSplits: 1).first ?? ""
            guard !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber }) else { return nil }
        }
        let normalized = trimmed.contains("://") ? trimmed : (Self.isLocal(trimmed) ? "http://" : "https://") + trimmed
        guard let url = URL(string: normalized), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else { return nil }
        return url
    }

    /// Whether an address typed without a scheme names a development server, which gets `http://` like browsers give
    /// it: localhost, an IP address, a `.local` or `.localhost` name, a single-label name, or any address with a port.
    /// Everything else gets `https://`.
    static func isLocal(_ address: String) -> Bool {
        let authority = address.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? address
        if authority.hasPrefix("[") { return true }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count > 1 { return true }
        let host = authority.lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || !host.contains(".") { return true }
        let labels = host.split(separator: ".")
        return labels.count == 4 && labels.allSatisfy { UInt8($0) != nil }
    }

    private static func selector(_ json: JSONValue) throws -> String {
        guard let selector = json["selector"]?.string, !selector.isEmpty, selector.utf8.count <= 4096 else {
            throw PreviewError.invalidCommand
        }
        return selector
    }
}

public enum PreviewError: LocalizedError {
    case invalidAddress, invalidCommand, unavailable, connection, timedOut, tooManyTabs, noSuchTab
    /// A file to upload is missing, a folder, or unreadable.
    case uploadFileMissing(String)
    /// The page didn't ask for files after its file input was activated.
    case uploadNotAccepted

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: String(localized: "Enter an HTTP or HTTPS address without a username or password.")
        case .invalidCommand: String(localized: "The preview command is invalid or too large.")
        case .unavailable: String(localized: "Agent control is off for this preview.")
        case .connection: String(localized: "The preview connection could not be started.")
        case .timedOut: String(localized: "The browser didn't finish the command in time.")
        case .tooManyTabs: String(localized: "This thread has 20 tabs. Close one first.")
        case .noSuchTab: String(localized: "There's no tab with that id in this thread.")
        case .uploadFileMissing(let path): String(localized: "\(path) isn't a readable file.")
        case .uploadNotAccepted:
            String(localized: "The page didn't open its file chooser. Name the file input, or the button that opens it, with selector.")
        }
    }
}

/// One bounded HTTP request. The listener closes after its response; it supports neither pipelining nor chunks.
struct PreviewHTTPRequest: Sendable {
    static let maximumBody = 1_048_576
    let path: String
    let host: String
    let authorization: String
    let body: Data

    static func parse(_ data: Data) throws -> Self? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 16_384 else { throw PreviewError.invalidCommand }
            return nil
        }
        guard boundary.lowerBound <= 16_384,
            let header = String(data: data[..<boundary.lowerBound], encoding: .utf8)
        else { throw PreviewError.invalidCommand }
        let lines = header.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[0] == "POST", first[2] == "HTTP/1.1" else { throw PreviewError.invalidCommand }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw PreviewError.invalidCommand }
            let name = line[..<colon].lowercased()
            guard fields[name] == nil else { throw PreviewError.invalidCommand }
            fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard fields["origin"] == nil, fields["transfer-encoding"] == nil,
            fields["content-type"]?.split(separator: ";").first == "application/json",
            let length = fields["content-length"].flatMap(Int.init), (0...maximumBody).contains(length),
            let host = fields["host"], let authorization = fields["authorization"]
        else { throw PreviewError.invalidCommand }
        let body = data[boundary.upperBound...]
        guard body.count <= length else { throw PreviewError.invalidCommand }
        guard body.count == length else { return nil }
        return Self(path: String(first[1]), host: host, authorization: authorization, body: Data(body))
    }
}
