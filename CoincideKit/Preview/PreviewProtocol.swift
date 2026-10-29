import Foundation

/// The preview exposes a small command vocabulary, never arbitrary JavaScript or filesystem paths.
public enum PreviewCommand: Sendable, Equatable {
    case read
    case navigate(URL)
    case click(String)
    case input(selector: String, text: String)
    case screenshot
    /// Opens the browser panel on this thread so the user can see the page.
    case show
    /// Shows the user a short "your turn" message with a Done button and waits for them, up to `timeout` seconds.
    case askUser(message: String, timeout: TimeInterval)

    /// How long the app lets the command run before answering with an error.
    public var timeout: TimeInterval {
        if case .askUser(_, let timeout) = self { return timeout + 5 }
        return 30
    }

    public init(json: JSONValue) throws {
        switch json["action"]?.string {
        case "read": self = .read
        case "navigate":
            guard let address = json["url"]?.string, let url = Self.url(address) else {
                throw PreviewError.invalidAddress
            }
            self = .navigate(url)
        case "click": self = .click(try Self.selector(json))
        case "input":
            guard let text = json["text"]?.string, text.utf8.count <= 65_536 else { throw PreviewError.invalidCommand }
            self = .input(selector: try Self.selector(json), text: text)
        case "screenshot": self = .screenshot
        case "show": self = .show
        case "ask-user":
            guard let message = json["message"]?.string, message.utf8.count <= 4096 else { throw PreviewError.invalidCommand }
            let timeout = json["timeout"]?.number ?? UserTurnGate.defaultTimeout
            guard timeout.isFinite, timeout >= 1, timeout <= UserTurnGate.maximumTimeout else { throw PreviewError.invalidCommand }
            self = .askUser(message: message, timeout: timeout)
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
        let normalized = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URL(string: normalized), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else { return nil }
        return url
    }

    private static func selector(_ json: JSONValue) throws -> String {
        guard let selector = json["selector"]?.string, !selector.isEmpty, selector.utf8.count <= 4096 else {
            throw PreviewError.invalidCommand
        }
        return selector
    }
}

public enum PreviewError: LocalizedError {
    case invalidAddress, invalidCommand, unavailable, connection, timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: String(localized: "Enter an HTTP or HTTPS address without a username or password.")
        case .invalidCommand: String(localized: "The preview command is invalid or too large.")
        case .unavailable: String(localized: "Agent control is off for this preview.")
        case .connection: String(localized: "The preview connection could not be started.")
        case .timedOut: String(localized: "The browser didn't finish the command in time.")
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
