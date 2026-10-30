import Foundation

/// The preview exposes a small command vocabulary, never arbitrary JavaScript. The only filesystem paths it takes are
/// the files `upload` attaches to a page, which the agent could read anyway.
public indirect enum PreviewCommand: Sendable, Equatable {
    /// The page's text and elements, a page of 30,000 characters and 200 elements at a time, optionally only inside
    /// the element `scope` names.
    case read(page: Int = 1, scope: String? = nil)
    case navigate(URL)
    /// Searches with the user's search engine.
    case search(String)
    case click(String)
    case input(selector: String, text: String)
    /// Types text as if from the keyboard into the element (rich editors included), after clearing it with `clear`.
    case type(selector: String, text: String, clear: Bool)
    /// A real key press, into the element `selector` names (focused first) or whatever has focus.
    case press(key: KeyPress, selector: String?)
    /// Answers the page's open alert, confirmation or prompt: OK with `accept`, and `text` for a prompt.
    case dialog(accept: Bool, text: String?)
    case back
    case forward
    case reload
    /// Scrolls the page: to an element, to the top or bottom, or by a number of pixels (negative goes up).
    case scroll(ScrollTarget)
    /// Waits until an element matching `selector`, or `text`, shows on the page, up to `timeout` seconds.
    case waitFor(selector: String?, text: String?, timeout: TimeInterval)
    /// Attaches local files to the page's file input (the selector names it, or the button or label that opens it),
    /// answering the page's file chooser with them so no dialog appears.
    case upload(selector: String, files: [URL])
    case screenshot
    case fullPageScreenshot
    case downloads
    case frames
    case console(clear: Bool)
    /// Changes the CSS viewport dimensions; nil restores the panel's size.
    case viewport(width: Int?, height: Int?)
    case inFrame(String, PreviewCommand)
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
        case .inTab(_, let command), .inFrame(_, let command): return command.timeout
        case .askUser(_, let timeout): return timeout + 5
        case .waitFor(_, _, let timeout): return timeout + 5
        // The user's approval, then the password manager (which may ask for Touch ID).
        case .fillLogin: return LoginApprovalGate.timeout + 90
        default: return 30
        }
    }

    public init(json: JSONValue) throws {
        var command = try Self.command(json)
        if let frame = json["frame"] {
            guard let id = frame.string, Self.isTabID(id) else { throw PreviewError.invalidCommand }
            switch command {
            case .read, .click, .input, .type, .press, .scroll, .waitFor, .upload:
                command = .inFrame(id, command)
            default: throw PreviewError.invalidCommand
            }
        }
        guard let tab = json["tab"] else {
            self = command
            return
        }
        // Page commands can name a tab; the tab commands name theirs themselves.
        guard let id = tab.string, Self.isTabID(id) else { throw PreviewError.invalidCommand }
        switch command {
        case .read, .navigate, .search, .click, .input, .type, .press, .dialog, .back, .forward, .reload, .scroll, .waitFor, .upload,
            .screenshot, .fullPageScreenshot, .downloads, .frames, .console, .viewport, .inFrame, .fillLogin:
            self = .inTab(id, command)
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
        case "read":
            let pageNumber = json["page"]?.number ?? 1
            guard pageNumber.isFinite, pageNumber.rounded() == pageNumber, (1...1000).contains(pageNumber) else { throw PreviewError.invalidCommand }
            let page = Int(pageNumber)
            let scope = json["selector"]?.string
            guard (1...1000).contains(page), (scope?.utf8.count ?? 0) <= 4096, scope?.isEmpty != true else { throw PreviewError.invalidCommand }
            return .read(page: page, scope: scope)
        case "type":
            guard let text = json["text"]?.string, text.utf8.count <= 65_536 else { throw PreviewError.invalidCommand }
            return .type(selector: try Self.selector(json), text: text, clear: json["clear"]?.bool ?? false)
        case "press":
            guard let name = json["key"]?.string, name.utf8.count <= 64, let key = KeyPress(name) else { throw PreviewError.invalidCommand }
            let selector = json["selector"] == nil ? nil : try Self.selector(json)
            return .press(key: key, selector: selector)
        case "dialog":
            guard let accept = json["accept"]?.bool else { throw PreviewError.invalidCommand }
            let text = json["text"]?.string
            guard (text?.utf8.count ?? 0) <= 65_536 else { throw PreviewError.invalidCommand }
            return .dialog(accept: accept, text: text)
        case "back": return .back
        case "forward": return .forward
        case "reload": return .reload
        case "scroll":
            if json["selector"] != nil { return .scroll(.element(try Self.selector(json))) }
            switch json["to"]?.string {
            case "top": return .scroll(.top)
            case "bottom": return .scroll(.bottom)
            case nil:
                let by = json["by"]?.number
                guard by.map({ $0.isFinite && abs($0) <= 1_000_000 }) ?? true else { throw PreviewError.invalidCommand }
                return .scroll(.by(by))
            default: throw PreviewError.invalidCommand
            }
        case "wait-for":
            let selector = json["selector"] == nil ? nil : try Self.selector(json)
            let text = json["text"]?.string
            guard selector != nil || text != nil, (text?.utf8.count ?? 0) <= 4096, text?.isEmpty != true else { throw PreviewError.invalidCommand }
            let timeout = json["timeout"]?.number ?? 10
            guard timeout.isFinite, timeout >= 0.5, timeout <= 60 else { throw PreviewError.invalidCommand }
            return .waitFor(selector: selector, text: text, timeout: timeout)
        case "navigate":
            guard let address = json["url"]?.string, let url = Self.url(address) else {
                throw PreviewError.invalidAddress
            }
            return .navigate(url)
        case "search":
            guard let query = json["query"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty,
                query.utf8.count <= 2048
            else { throw PreviewError.invalidCommand }
            return .search(query)
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
        case "screenshot": return json["fullPage"]?.bool == true ? .fullPageScreenshot : .screenshot
        case "downloads": return .downloads
        case "frames": return .frames
        case "console": return .console(clear: json["clear"]?.bool ?? false)
        case "viewport":
            if json["reset"]?.bool == true { return .viewport(width: nil, height: nil) }
            let width: Double
            let height: Double
            switch json["preset"]?.string {
            case "mobile": (width, height) = (390, 844)
            case "tablet": (width, height) = (820, 1180)
            case "desktop": (width, height) = (1280, 860)
            case nil:
                guard let w = json["width"]?.number, let h = json["height"]?.number else { throw PreviewError.invalidCommand }
                (width, height) = (w, h)
            default: throw PreviewError.invalidCommand
            }
            guard width.isFinite, height.isFinite, width.rounded() == width, height.rounded() == height,
                (320...2560).contains(width), (240...2560).contains(height) else { throw PreviewError.invalidCommand }
            return .viewport(width: Int(width), height: Int(height))
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

/// Where `scroll` goes.
public enum ScrollTarget: Sendable, Equatable {
    case element(String)
    case top
    case bottom
    /// Pixels down (negative: up); nil for most of a screen.
    case by(Double?)
}

public enum PreviewError: LocalizedError {
    case invalidAddress, invalidCommand, unavailable, connection, timedOut, tooManyTabs, noSuchTab
    /// The page shows an alert, confirmation or prompt, which blocks it until answered.
    case dialogOpen
    case noDialog
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
        case .dialogOpen: String(localized: "The page is showing a dialog. Answer it with dialog first.")
        case .noDialog: String(localized: "The page isn't showing a dialog.")
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
