import Foundation
import Darwin

public struct PiExtensionRequest: Sendable, Equatable {
    public enum Method: String, Sendable { case confirm, select, input, editor }
    public let method: Method
    public let title: String
    public let message: String?
    public let options: [String]
    public let placeholder: String?
    public let prefill: String?
    public init(params: JSONValue) throws {
        guard let method = Method(rawValue: params["method"].string ?? ""), let title = params["title"].string,
              title.utf8.count <= 16_384, !title.contains("\u{0}") else { throw CoincideError(PiProtocol.failure) }
        func optional(_ key: String) throws -> String? {
            guard params[key] != .null else { return nil }
            guard let text = params[key].string, text.utf8.count <= 1_048_576, !text.contains("\u{0}") else { throw CoincideError(PiProtocol.failure) }
            return text
        }
        let options: [String]
        if method == .select {
            guard let raw = params["options"].array, !raw.isEmpty, raw.count <= 256 else { throw CoincideError(PiProtocol.failure) }
            options = try raw.map { guard let value = $0.string, value.utf8.count <= 16_384, !value.contains("\u{0}") else { throw CoincideError(PiProtocol.failure) }; return value }
            guard Set(options).count == options.count else { throw CoincideError(PiProtocol.failure) }
        } else { options = [] }
        self.method = method; self.title = title; self.options = options
        message = try optional("message"); placeholder = try optional("placeholder"); prefill = try optional("prefill")
    }
    public static func presentation(_ request: ApprovalRequest) throws -> Self {
        guard request.method == "pi/extension" else { throw CoincideError(PiProtocol.failure) }
        return try .init(params: request.params)
    }
}

/// Pi uses LF-delimited records, not JSON-RPC envelopes. Native continuation
/// identity is a session file; Pi does not expose a strong per-prompt turn ID.
enum PiProtocol {
    static let failure = "The Pi connection could not confirm the operation. It was not automatically retried."
    static let rejected = "Pi did not accept the request."
    static let modelFailure = "The Pi model catalog could not be read safely."
    static let historyFailure = "Pi could not prove the exact native history boundary. No history operation was enabled."
    static func inputCommand(_ input: ProviderInput) throws -> (name: String, fields: [String: JSONValue]) {
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/compact") {
            let rest = text.dropFirst("/compact".count)
            if rest.isEmpty || rest.first?.isWhitespace == true {
                guard input.images.isEmpty else { throw ProviderSteeringError(.invalidRequest) }
                let instructions = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                return ("compact", instructions.isEmpty ? [:] : ["customInstructions": .string(instructions)])
            }
        }
        var fields: [String: JSONValue] = ["message": .string(input.text), "streamingBehavior": .string("steer")]
        if !input.images.isEmpty {
            fields["images"] = .array(input.images.map { .object(["type": .string("image"), "mimeType": .string($0.mimeType), "data": .string($0.data.base64EncodedString())]) })
        }
        return ("prompt", fields)
    }
    static func forkAccepted(_ value: JSONValue) throws -> Bool {
        guard value.object != nil, case .bool(let cancelled) = value["cancelled"] else { throw ProviderHistoryError(.invalidResponse) }
        if value["text"] != .null {
            guard let text = value["text"].string, text.utf8.count <= 4_194_304, !text.contains("\0") else { throw ProviderHistoryError(.invalidResponse) }
        }
        return !cancelled
    }
    static func observedVersion(_ data: Data) throws -> String {
        guard data.count <= 8_192, let text = String(data: data, encoding: .utf8) else { throw CoincideError(failure) }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
        guard words.count == 1 || (words.count == 2 && words.first == "pi"), let last = words.last else { throw CoincideError(failure) }
        let version = String(last)
        guard PiRuntimeConfiguration.supportsObservedVersion(version) else { throw CoincideError("Pi 0.80.5 or newer with settled/entries support is required for this captured runtime.") }
        return version
    }
    static func entries(_ value: JSONValue, state: PiState) throws -> PiRuntimeEntries { try .init(value, state: state) }
    /// Payload equality is a necessary refusal check after an already-owned
    /// ancestor window. Text equality alone never establishes native ownership.
    static func inputDigest(_ entry: PiHistoryEntry) throws -> String {
        guard entry.isUserMessage else { throw PiHistoryGraphError(.invalidWindow) }
        let content = entry.raw["message"]["content"]
        if let text = content.string { return try PiHistoryInputEvidence.digest(.init(text: text)) }
        guard let items = content.array else { throw PiHistoryGraphError(.invalidWindow) }
        var text = "", images: [ProviderImage] = []
        for item in items {
            if item["type"] == .string("text"), let fragment = item["text"].string { text += fragment }
            else if item["type"] == .string("image"), let mime = item["mimeType"].string, let encoded = item["data"].string,
                    encoded.utf8.count <= PiHistoryGraph.maximumLineBytes, let data = Data(base64Encoded: encoded) {
                images.append(.init(mimeType: mime, data: data))
            } else { throw PiHistoryGraphError(.invalidWindow) }
        }
        return try PiHistoryInputEvidence.digest(.init(text: text, images: images))
    }
    /// Pi silently creates an empty session if switch_session names a missing
    /// file. Require an actual native session header before attempting resume.
    static func resumeHeader(_ path: String, cwd: URL) throws -> (UInt64, UInt64) {
        guard path.hasPrefix("/"), !path.contains("\u{0}"), path.utf8.count <= 16_384 else { throw CoincideError(failure) }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CoincideError(failure) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CoincideError(failure) }
        var data = Data(), block = [UInt8](repeating: 0, count: 4_096)
        while data.firstIndex(of: 10) == nil, data.count < 65_536 {
            let count = Darwin.read(fd, &block, block.count)
            guard count >= 0 else { throw CoincideError(failure) }
            if count == 0 { break }; data.append(contentsOf: block.prefix(count))
        }
        guard let end = data.firstIndex(of: 10), let header = try? JSONDecoder().decode(JSONValue.self, from: Data(data[..<end])),
              header["type"].string == "session", let nativeCWD = header["cwd"].string,
              URL(fileURLWithPath: nativeCWD).standardizedFileURL.resolvingSymlinksInPath() == cwd else { throw CoincideError(failure) }
        _ = try id(header["id"])
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }
    static func id(_ value: JSONValue, maximum: Int = 4_096) throws -> String {
        guard let text = value.string, !text.isEmpty, text.utf8.count <= maximum,
              !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw CoincideError(failure) }
        return text
    }
    static func state(_ value: JSONValue) throws -> PiState {
        guard value.object != nil, case .bool(let streaming) = value["isStreaming"],
              case .bool(let compacting) = value["isCompacting"],
              case .number(let count) = value["pendingMessageCount"], let pending = Int(exactly: count), pending >= 0,
              pending <= 100_000 else { throw CoincideError(failure) }
        let file = try id(value["sessionFile"], maximum: 16_384)
        guard file.hasPrefix("/"), !file.contains("\u{0}") else { throw CoincideError(failure) }
        let model: PiModelSelection?
        if value["model"] == .null { model = nil }
        else { model = try .init(provider: id(value["model"]["provider"]), modelID: id(value["model"]["id"])) }
        let thinking = value["thinkingLevel"] == .null ? nil : try id(value["thinkingLevel"], maximum: 128)
        let sessionID = try id(value["sessionId"])
        return .init(sessionFile: file, sessionID: sessionID, model: model, thinking: thinking, idle: !streaming && !compacting && pending == 0)
    }
    static func models(_ value: JSONValue) throws -> [ProviderModel] {
        guard let entries = value["models"].array, entries.count <= 4_096 else { throw CoincideError(modelFailure) }
        var result: [ProviderModel] = [], seen: [String: ProviderModel] = [:]
        for raw in entries {
            let selection = try PiModelSelection(provider: id(raw["provider"]), modelID: id(raw["id"]))
            let name = raw["name"].string ?? selection.modelID
            guard name.utf8.count <= 16_384, !name.contains("\u{0}") else { throw CoincideError(modelFailure) }
            let ladder = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
            let map = raw["thinkingLevelMap"].object ?? [:]
            let levels = raw["reasoning"] == .bool(true) ? ladder.filter {
                map[$0] != .null && (!["xhigh", "max"].contains($0) || map[$0] != nil)
            } : []
            let model = ProviderModel(id: selection.catalogID, name: name, piSelection: selection, piThinkingLevels: levels)
            if let prior = seen[model.id] { guard prior == model else { throw CoincideError(modelFailure) } }
            else { seen[model.id] = model; result.append(model) }
        }
        return result
    }

    /// This is an app-owned extension, loaded by literal argv. It only enforces
    /// the captured tool approval boundary; it is not an OS filesystem sandbox.
    static func permissionExtension(_ permission: PermissionMode) -> String {
        let mode = permission.rawValue
        return """
        export default function(pi) {
          const mode = \"\(mode)\";
          pi.on(\"tool_call\", async (event, ctx) => {
            if (mode === \"fullAccess\") return;
            if ([\"read\", \"grep\", \"find\", \"ls\"].includes(event.toolName)) return;
            if (mode === \"autoAcceptEdits\" && [\"edit\", \"write\"].includes(event.toolName)) return;
            let summary;
            try { summary = JSON.stringify(event.input).slice(0, 4000); } catch { summary = \"Review the requested tool action.\"; }
            const allowed = await ctx.ui.confirm(`Allow ${event.toolName}?`, summary, { signal: ctx.signal });
            if (!allowed) return { block: true, reason: \"The action was declined in Coincide.\" };
          });
        }
        """
    }
    static func permissionExtension(_ permission: PermissionMode, reservationPath: String, processEpoch: UUID,
                                    mcpConfigurationPath: String? = nil, mcpExtensionPath: String? = nil) throws -> String {
        let fragment = try PiInputBridge.extensionFragment(reservationPath: reservationPath, processEpoch: processEpoch)
        var source = permissionExtension(permission)
        var imports = PiInputBridge.extensionImports
        var body = fragment
        if let mcpConfigurationPath, let mcpExtensionPath {
            imports += "\n" + PiMCPBridge.extensionImports
            body += "\n" + (try PiMCPBridge.extensionFragment(configurationPath: mcpConfigurationPath, extensionPath: mcpExtensionPath))
            source = source.replacingOccurrences(of: "export default function(pi) {", with: "export default async function(pi) {")
            source = source.replacingOccurrences(of: "if (mode === \"fullAccess\") return;",
                with: "if (mode === \"fullAccess\") return;\n    if (" + PiMCPBridge.readOnlyToolExpression + ") return;")
        } else if mcpConfigurationPath != nil || mcpExtensionPath != nil { throw PiMCPBridgeError.invalidConfiguration }
        let factory = mcpConfigurationPath == nil ? "export default function(pi) {" : "export default async function(pi) {"
        return imports + "\n" + source.replacingOccurrences(of: factory, with: factory + "\n" + body)
    }
}

struct PiState: Sendable, Equatable {
    let sessionFile: String
    let sessionID: String
    let model: PiModelSelection?
    let thinking: String?
    let idle: Bool
}
