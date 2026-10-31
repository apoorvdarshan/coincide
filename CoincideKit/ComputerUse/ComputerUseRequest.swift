import Foundation

/// The app's native computer-use capability. Session identity and runtime control stay with Coincide.
public enum ComputerUseRequest: Sendable, Hashable {
    case tools
    case status
    case release
    case call(name: String, arguments: [String: JSONValue])

    public var timeout: TimeInterval {
        switch self {
        case .call: 120
        case .tools, .status, .release: 20
        }
    }

    public init(json: JSONValue) throws {
        guard let object = json.object, let action = object["action"]?.string else { throw ComputerUseError.invalidRequest }
        switch action {
        case "tools", "status", "release":
            guard Set(object.keys) == ["action"] else { throw ComputerUseError.invalidRequest }
            self = action == "tools" ? .tools : action == "status" ? .status : .release
        case "call":
            guard Set(object.keys).isSubset(of: ["action", "name", "arguments"]),
                let name = object["name"]?.string,
                let arguments = object["arguments"]?.object
            else { throw ComputerUseError.invalidRequest }
            try ComputerUseToolPolicy.validate(name: name, arguments: arguments)
            self = .call(name: name, arguments: arguments)
        default: throw ComputerUseError.invalidRequest
        }
    }
}

/// A fixed ceiling on the native operations an agent can call through Coincide. It grants no runtime authority.
/// Browser control, arbitrary scripts, installation, driver configuration and session APIs are deliberately absent.
public enum ComputerUseToolPolicy {
    public static let allowedTools: Set<String> = [
        "list_apps", "list_windows", "get_window_state", "get_desktop_state", "verify_state", "zoom",
        "click", "double_click", "right_click", "set_value", "type_text", "press_key", "hotkey", "scroll", "drag",
        "move_cursor", "invoke_menu", "launch_app", "set_window_frame", "run_steps",
    ]

    private static let batchActions: Set<String> = [
        "click", "double_click", "right_click", "set_value", "type_text", "press_key", "hotkey", "scroll", "drag", "move_cursor",
    ]
    private static let reservedKeys: Set<String> = [
        "session", "session_id", "permission_mode", "permission_profile", "capability_manifest", "grant", "profile",
        "socket", "host", "port", "config", "environment", "env", "script", "source", "code", "url",
        "screenshot_out_file", "debug_image_out", "output_file", "output_path", "output_directory", "output_dir",
    ]
    public static let maximumArgumentsBytes = 262_144

    public static func allows(_ name: String) -> Bool { allowedTools.contains(name) }

    public static func validate(name: String, arguments: [String: JSONValue]) throws {
        guard allows(name) else { throw ComputerUseError.toolNotAllowed(name) }
        guard arguments.count <= 64 else { throw ComputerUseError.invalidArguments }
        var nodes = 0
        try validateValue(.object(arguments), depth: 0, nodes: &nodes)
        guard JSONValue.object(arguments).compactJSON.utf8.count <= maximumArgumentsBytes else { throw ComputerUseError.invalidArguments }
        if name == "run_steps" { try validateBatch(arguments) }
    }

    private static func validateValue(_ value: JSONValue, depth: Int, nodes: inout Int) throws {
        nodes += 1
        guard depth <= 12, nodes <= 4_096 else { throw ComputerUseError.invalidArguments }
        switch value {
        case .object(let object):
            guard object.count <= 64 else { throw ComputerUseError.invalidArguments }
            for (key, child) in object {
                guard !key.isEmpty, key.utf8.count <= 128, !key.hasPrefix("_"),
                    !reservedKeys.contains(key.lowercased())
                else { throw ComputerUseError.invalidArguments }
                try validateValue(child, depth: depth + 1, nodes: &nodes)
            }
        case .array(let values):
            guard values.count <= 2_048 else { throw ComputerUseError.invalidArguments }
            for child in values { try validateValue(child, depth: depth + 1, nodes: &nodes) }
        case .string(let text):
            guard text.utf8.count <= 65_536, !text.contains("\0") else { throw ComputerUseError.invalidArguments }
        case .number(let number):
            guard number.isFinite else { throw ComputerUseError.invalidArguments }
        case .null, .bool: break
        }
    }

    private static func validateBatch(_ arguments: [String: JSONValue]) throws {
        guard let steps = arguments["steps"]?.array, (1...64).contains(steps.count) else { throw ComputerUseError.invalidArguments }
        for step in steps {
            guard let object = step.object,
                Set(object.keys).isSubset(of: ["tool", "args", "wait_for", "expect", "timeout_ms"]),
                let name = object["tool"]?.string, batchActions.contains(name), let args = object["args"]?.object
            else { throw ComputerUseError.invalidArguments }
            // Use only the explicit action form; aliases, scripts and nested batches cannot bypass the ceiling.
            try validate(name: name, arguments: args)
            for key in ["wait_for", "expect"] {
                if let check = object[key], check.object == nil && check.array == nil { throw ComputerUseError.invalidArguments }
            }
        }
        if let observe = arguments["observe"] {
            if let object = observe.object {
                let fields: Set<String> = [
                    "pid", "window_id", "query", "max_elements", "max_depth", "timeout_ms", "tree_format", "include_screenshot",
                    "include_accessibility_tree", "since", "verbose", "full_output", "display_only",
                ]
                guard Set(object.keys).isSubset(of: fields) else { throw ComputerUseError.invalidArguments }
            } else if observe.bool == nil { throw ComputerUseError.invalidArguments }
        }
    }
}

public enum ComputerUseError: LocalizedError {
    case invalidRequest, invalidArguments, unavailable, connection, timedOut, busy, responseTooLarge
    case toolNotAllowed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: String(localized: "The computer-use request is invalid or too large.")
        case .invalidArguments: String(localized: "The computer-use arguments are invalid or contain a reserved option.")
        case .unavailable: String(localized: "Computer Use is off for this thread.")
        case .connection: String(localized: "The computer-use connection could not be started.")
        case .timedOut: String(localized: "Computer Use did not finish the command in time.")
        case .busy: String(localized: "This thread already has a computer-use command running.")
        case .responseTooLarge: String(localized: "The computer-use result is too large. Request a narrower snapshot.")
        case .toolNotAllowed(let name): String(localized: "The computer-use tool \(name) is not available through Coincide.")
        }
    }
}

/// A bounded, single HTTP request without browser-origin access, chunks or pipelining.
struct ComputerUseHTTPRequest: Sendable {
    static let maximumBody = ComputerUseToolPolicy.maximumArgumentsBytes + 1_024
    static let maximumHeaders = 16_384
    let path: String
    let host: String
    let authorization: String
    let body: Data

    static func parse(_ data: Data) throws -> Self? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= maximumHeaders else { throw ComputerUseError.invalidRequest }
            return nil
        }
        guard boundary.lowerBound <= maximumHeaders, let header = String(data: data[..<boundary.lowerBound], encoding: .utf8)
        else { throw ComputerUseError.invalidRequest }
        let lines = header.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[0] == "POST", first[2] == "HTTP/1.1", first[1].hasPrefix("/") else {
            throw ComputerUseError.invalidRequest
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw ComputerUseError.invalidRequest }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), fields[name] == nil
            else { throw ComputerUseError.invalidRequest }
            fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard fields["origin"] == nil, fields["transfer-encoding"] == nil,
            fields["content-type"]?.split(separator: ";").first == "application/json",
            let text = fields["content-length"], !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
            let length = Int(text), (0...maximumBody).contains(length),
            let host = fields["host"], let authorization = fields["authorization"]
        else { throw ComputerUseError.invalidRequest }
        let body = data[boundary.upperBound...]
        guard body.count <= length else { throw ComputerUseError.invalidRequest }
        guard body.count == length else { return nil }
        return Self(path: String(first[1]), host: host, authorization: authorization, body: Data(body))
    }
}
