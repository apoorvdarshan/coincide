import Foundation

/// Safe transport errors never retain a frame, request, stderr or native error message.
public struct MuseMSPError: LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable { case invalidInput, protocolViolation, remoteFailure, profileUnproven, overflow, timedOut, cancelled, closed }
    public let kind: Kind
    public let code: Int?
    public let nativeKind: String?
    public init(_ kind: Kind, code: Int? = nil, nativeKind: String? = nil) {
        self.kind = kind; self.code = code
        self.nativeKind = Self.safeNativeKinds.contains(nativeKind ?? "") ? nativeKind : nil
    }
    public var errorDescription: String? {
        switch kind {
        case .invalidInput: "The Muse request is invalid. Refresh its options and try again."
        case .profileUnproven: "Muse did not confirm the selected permission profile. No prompt was sent."
        case .remoteFailure: "Muse could not accept this request. Check its installation and sign-in."
        case .overflow: "Muse output exceeded the safe buffer limit. Reopen the conversation to reconcile it."
        case .timedOut: "Muse did not confirm the request. Reopen the conversation to reconcile it."
        case .cancelled: "The Muse request was cancelled."
        case .closed: "The Muse connection closed. Reopen the conversation to reconcile it."
        case .protocolViolation: "Muse sent an unsupported response. Reopen the conversation to reconcile it."
        }
    }
    private static let safeNativeKinds: Set<String> = ["sessionNotFound", "notFound", "sessionInUse", "commandRejected", "overloaded", "backpressured", "invalidParams", "authRequired", "capabilityRequired", "approvalRequirementStale", "approvalAlreadyResolved", "approvalNotFound", "userInputAlreadySettled", "userInputNotFound", "userInputAnswerInvalid"]
}

public struct MuseInitializeResult: Sendable, Equatable {
    public let schemaFingerprint: String
    public let grantedCapabilities: [String]
    /// Absence means durable in MSP v1; an unfamiliar value grants no durability.
    public let durability: String
    public let serverVersion: String
    public var survivesHostDeath: Bool { durability == "durable" }
    public var supportsResumePermissionProfile: Bool { schemaFingerprint == MuseProtocol.resumeProfileFingerprint }
}

public struct MuseSessionInfo: Sendable, Equatable {
    public let sessionID: String
    public let workspaceRoot: String?
    public let providerID: String?
    public let modelID: String?
    public let activeTurnID: String?
    public let status: String
    public let profileID: String?
    public let approvalMode: String?
    public let viewCursor: String
}

public struct MuseTurnAdmission: Sendable, Equatable {
    public let commandID: String
    public let turnID: String
    public let disposition: String
}

public enum MuseProtocol {
    public static let schemaFingerprint = "sha256:eae467ab60cb9a5d5af4de616830f065e59375c987fd59269c8cc33ed2a1137f"
    public static let resumeProfileFingerprint = "sha256:f282ad16e21520d0cda68cb190149b86e2b062eef1dd282749360c05aa3d1082"
    public static let maximumFrameBytes = 10_485_760
    public static let reasoningEfforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    public static func initialize(_ value: JSONValue) throws -> MuseInitializeResult {
        guard value["schema"]["version"] == .number(1), value["experimentalApi"] == .bool(false),
              let fingerprint = value["schema"]["fingerprint"].string,
              fingerprint.hasPrefix("sha256:"), fingerprint.count == 71,
              fingerprint.dropFirst(7).allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let grants = value["grantedCapabilities"].array, grants.count <= 64 else { throw MuseMSPError(.protocolViolation) }
        _ = try text(value["serverInfo"]["name"], maximum: 256)
        let version = try text(value["serverInfo"]["version"], maximum: 256)
        let names = try grants.map { try text($0, maximum: 128) }
        guard Set(names).count == names.count else { throw MuseMSPError(.protocolViolation) }
        let durability = try optionalText(value["sessionDurability"], maximum: 128) ?? "durable"
        return .init(schemaFingerprint: fingerprint, grantedCapabilities: names, durability: durability, serverVersion: version)
    }

    public static func session(_ value: JSONValue, expectedID: String, workspaceRoot: String, requiredProfile: String? = nil) throws -> MuseSessionInfo {
        let session = value["session"]
        let id = try identity(session["sessionId"])
        guard id == expectedID, session.object != nil else { throw MuseMSPError(.protocolViolation) }
        let root = try optionalText(session["workspaceRoot"], maximum: 16_384)
        guard let root, sameWorkspaceRoot(root, workspaceRoot) else { throw MuseMSPError(.protocolViolation) }
        let provider = try optionalText(session["providerId"], maximum: 256)
        guard provider == nil || provider == "meta" else { throw MuseMSPError(.protocolViolation) }
        let active = try optionalText(session["activeTurnId"], maximum: 128)
        if let active { _ = try identity(.string(active)) }
        let profile = try optionalText(session["permissionState"]["profileId"], maximum: 256)
        if let requiredProfile, profile != requiredProfile { throw MuseMSPError(.profileUnproven) }
        return .init(sessionID: id, workspaceRoot: root, providerID: provider,
                     modelID: try optionalText(session["modelId"], maximum: 4_096), activeTurnID: active,
                     status: try text(session["status"], maximum: 128), profileID: profile,
                     approvalMode: try optionalText(session["approvalMode"]["mode"], maximum: 128),
                     viewCursor: try text(value["viewCursor"], maximum: 4_096))
    }

    public static func turnAdmission(_ value: JSONValue, expectedCommandID: String) throws -> MuseTurnAdmission {
        let command = try identity(value["commandId"], command: true)
        guard command == expectedCommandID, value["status"] == .string("accepted"),
              let disposition = value["disposition"].string, ["started", "queued", "steered"].contains(disposition),
              value["startedNewTurn"] == .bool(disposition == "started") else { throw MuseMSPError(.protocolViolation) }
        let turn = try identity(value["turnId"])
        guard disposition == "steered" || turn == command else { throw MuseMSPError(.protocolViolation) }
        return .init(commandID: command, turnID: turn, disposition: disposition)
    }

    public static func models(_ value: JSONValue) throws -> [ProviderModel] {
        guard value["providerId"] == .string("meta"), let rows = value["models"].array, rows.count <= 2_048 else { throw MuseMSPError(.protocolViolation) }
        var seen = Set<String>()
        return try rows.compactMap { row in
            guard row["providerId"] == .string("meta") else { return nil }
            let id = try text(row["modelId"], maximum: 4_096)
            guard seen.insert(id).inserted else { return nil }
            let selection = MuseModelSelection(providerID: "meta", modelID: id)
            let label = try text(row["displayLabel"], maximum: 4_096, empty: true)
            guard case .bool(let isDefault) = row["isDefault"] else { throw MuseMSPError(.protocolViolation) }
            let variants = row["variants"]
            let advertised: [String]?
            if row.object?["variants"] == nil || variants == .string("unknown") { advertised = nil }
            else {
                guard let values = variants.array, values.count <= 64 else { throw MuseMSPError(.protocolViolation) }
                let names = try values.map { try text($0, maximum: 128) }
                guard Set(names).count == names.count else { throw MuseMSPError(.protocolViolation) }
                advertised = names.filter(reasoningEfforts.contains)
            }
            let efforts = advertised ?? ["low", "medium", "high", "xhigh", "max"]
            let descriptions = row["reasoningEffortVariants"].array ?? []
            guard descriptions.count <= 64 else { throw MuseMSPError(.protocolViolation) }
            let options = try efforts.map { effort in
                let described = descriptions.first { $0["tier"] == .string(effort) }
                let detail = try optionalText(described?["description"] ?? .null, maximum: 4_096)
                let description = advertised == nil
                    ? ["Compatibility fallback; Muse did not advertise reasoning choices.", detail].compactMap { $0 }.joined(separator: " ")
                    : detail ?? effort.capitalized
                return ProviderReasoningEffortOption(id: effort, description: description)
            }
            let nativeDefault = advertised == nil ? nil : try optionalText(row["defaultReasoningEffort"], maximum: 128)
            let preferred = nativeDefault ?? (advertised == nil ? "high" : nil)
            let effectiveDefault = efforts.first { $0 == preferred } ?? efforts.first
            return ProviderModel(id: selection.catalogID, name: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? id : label,
                                 reasoningEfforts: options, defaultReasoningEffort: effectiveDefault, isDefault: isDefault,
                                 museSelection: selection, museReasoningEfforts: advertised == nil ? nil : options,
                                 museDefaultReasoningEffort: nativeDefault)
        }
    }

    public static func identity(_ value: JSONValue, command: Bool = false) throws -> String {
        let string = try text(value, maximum: 128)
        guard let uuid = UUID(uuidString: string), uuid.uuidString.caseInsensitiveCompare(string) == .orderedSame else { throw MuseMSPError(.protocolViolation) }
        if command {
            let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
            guard bytes[6] >> 4 == 7, bytes[8] & 0xc0 == 0x80 else { throw MuseMSPError(.invalidInput) }
        }
        return string
    }
    static func text(_ value: JSONValue, maximum: Int = 65_536, empty: Bool = false) throws -> String {
        guard let string = value.string, string.utf8.count <= maximum, !string.contains("\0"), empty || !string.isEmpty else { throw MuseMSPError(.protocolViolation) }
        return string
    }
    static func optionalText(_ value: JSONValue, maximum: Int = 65_536) throws -> String? {
        value == .null ? nil : try text(value, maximum: maximum)
    }
    static func integer(_ value: JSONValue, minimum: Int = 0, maximum: Int = Int.max) throws -> Int {
        guard case .number(let number) = value, let int = Int(exactly: number), (minimum...maximum).contains(int) else { throw MuseMSPError(.protocolViolation) }
        return int
    }
    private static func sameWorkspaceRoot(_ first: String, _ second: String) -> Bool {
        func clean(_ path: String) -> Bool {
            path.hasPrefix("/") && path.utf8.count <= 16_384 && !path.contains("\0") &&
                !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        }
        guard clean(first), clean(second) else { return false }
        if first == second { return true }
        func identity(_ path: String) -> (NSNumber, NSNumber)? {
            let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
            return (device, inode)
        }
        guard let left = identity(first), let right = identity(second) else { return false }
        return left.0 == right.0 && left.1 == right.1
    }
}

public struct MuseApprovalRequest: Sendable, Equatable {
    public struct Requirement: Sendable, Equatable { public let approvalID: String; public let sourceIndex: Int }
    public struct Choice: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let decision: String
        public let scope: String
        public let acceptsFeedback: Bool
        public let rulePreview: String?
    }
    public let sessionID: String
    public let approvalID: String
    public let turnID: String?
    public let itemID: String?
    public let subagentID: String?
    public let requirement: Requirement
    public let choices: [Choice]
    public let title: String
    public let detail: String

    public init(params: JSONValue) throws {
        sessionID = try MuseProtocol.identity(params["sessionId"])
        approvalID = try MuseProtocol.text(params["approvalId"], maximum: 4_096)
        turnID = try MuseProtocol.optionalText(params["turnId"], maximum: 128)
        if let turnID { _ = try MuseProtocol.identity(.string(turnID)) }
        itemID = try MuseProtocol.optionalText(params["itemId"], maximum: 4_096)
        subagentID = try MuseProtocol.optionalText(params["subagentOrigin"]["subagentId"], maximum: 4_096)
        guard params["currentRequirementId"]["approvalId"] == .string(approvalID),
              let offered = params["availableChoices"].array, !offered.isEmpty, offered.count <= 64 else { throw MuseMSPError(.protocolViolation) }
        requirement = .init(approvalID: approvalID, sourceIndex: try MuseProtocol.integer(params["currentRequirementId"]["sourceIndex"]))
        choices = try offered.map { choice in
            let accepts = choice["acceptsFeedback"]
            guard accepts == .null || accepts == .bool(true) || accepts == .bool(false) else { throw MuseMSPError(.protocolViolation) }
            return .init(id: try MuseProtocol.text(choice["choiceId"], maximum: 4_096), label: try MuseProtocol.text(choice["label"], maximum: 4_096),
                         decision: try MuseProtocol.text(choice["decision"], maximum: 128), scope: try MuseProtocol.text(choice["scope"], maximum: 128), acceptsFeedback: accepts == .bool(true),
                         rulePreview: try MuseProtocol.optionalText(choice["rulePreview"], maximum: 65_536))
        }
        guard Set(choices.map(\.id)).count == choices.count else { throw MuseMSPError(.protocolViolation) }
        let subject = params["subject"]
        let kind = try MuseProtocol.text(subject["kind"], maximum: 128)
        title = "Muse requests \(kind) permission"
        var details = try ["command", "path", "host", "target"].compactMap { try MuseProtocol.optionalText(subject[$0], maximum: 65_536) }
        for (key, label) in [("toolName", "Tool"), ("access", "Access"), ("protocol", "Protocol"), ("workspaceRoot", "Workspace")] {
            let value = subject[key] == .null && key == "toolName" ? params[key] : subject[key]
            if let text = try MuseProtocol.optionalText(value, maximum: 16_384) { details.append("\(label): \(text)") }
        }
        if subject["port"] != .null { details.append("Port: \(try MuseProtocol.integer(subject["port"], maximum: 65_535))") }
        detail = details.joined(separator: "\n")
    }
    public func decisionBody(choiceID: String) throws -> JSONValue {
        guard choices.contains(where: { $0.id == choiceID }) else { throw MuseMSPError(.invalidInput) }
        return .object(["approvalId": .string(approvalID), "requirementId": .object(["approvalId": .string(requirement.approvalID), "sourceIndex": .number(Double(requirement.sourceIndex))]), "choiceId": .string(choiceID)])
    }
    public func declineBody() throws -> JSONValue {
        let rejected = choices.first { ["denied", "deniedPolicyAmendment"].contains($0.decision) && $0.scope == "once" }
            ?? choices.first { $0.decision == "abort" }
            ?? choices.first { $0.decision == "denied" }
        guard let rejected else { throw MuseMSPError(.invalidInput) }
        return try decisionBody(choiceID: rejected.id)
    }
    public func approval(localID: JSONValue) -> ApprovalRequest {
        .init(id: localID, method: "muse/approval", params: .object(["title": .string(title), "detail": .string(detail),
            "choices": .array(choices.map { choice in
                var row: [String: JSONValue] = ["id": .string(choice.id), "label": .string(choice.label), "decision": .string(choice.decision), "scope": .string(choice.scope), "acceptsFeedback": .bool(choice.acceptsFeedback)]
                if let preview = choice.rulePreview { row["rulePreview"] = .string(preview) }; return .object(row)
            })]))
    }
    public static func presentation(_ request: ApprovalRequest) throws -> Self {
        guard request.method == "muse/approval", let params = request.params.object,
              Set(params.keys) == ["title", "detail", "choices"], let choices = params["choices"]?.array else { throw MuseMSPError(.invalidInput) }
        let rows: [JSONValue] = try choices.map { row in
            guard let values = row.object, Set(values.keys).isSubset(of: ["id", "label", "decision", "scope", "acceptsFeedback", "rulePreview"]),
                  Set(["id", "label", "decision", "scope", "acceptsFeedback"]).isSubset(of: Set(values.keys)) else { throw MuseMSPError(.invalidInput) }
            var choice: [String: JSONValue] = ["choiceId": row["id"], "label": row["label"], "decision": row["decision"], "scope": row["scope"], "acceptsFeedback": row["acceptsFeedback"]]
            if values["rulePreview"] != nil { choice["rulePreview"] = row["rulePreview"] }; return .object(choice)
        }
        let safeID = "00000000-0000-7000-8000-000000000000"
        var result = try Self(params: .object(["sessionId": .string(safeID), "approvalId": .string("presentation"), "currentRequirementId": .object(["approvalId": .string("presentation"), "sourceIndex": .number(0)]), "availableChoices": .array(rows), "subject": .object(["kind": .string("request")])]))
        result = .init(copy: result, title: try MuseProtocol.text(request.params["title"], maximum: 4_096), detail: try MuseProtocol.text(request.params["detail"], maximum: 400_000, empty: true))
        return result
    }
    private init(copy: Self, title: String, detail: String) {
        sessionID = copy.sessionID; approvalID = copy.approvalID; turnID = copy.turnID; itemID = copy.itemID; subagentID = copy.subagentID
        requirement = copy.requirement; choices = copy.choices; self.title = title; self.detail = detail
    }
}

public struct MuseUserInputRequest: Sendable, Equatable {
    public struct Option: Sendable, Equatable { public let label: String; public let description: String?; public let preview: String?; public let previewFormat: String? }
    public struct Question: Sendable, Equatable, Identifiable {
        public let id: String
        public let header: String
        public let question: String
        public let options: [Option]
        public let multiple: Bool
        public let minimumSelections: Int?
        public let maximumSelections: Int?
    }
    public let sessionID: String
    public let userInputID: String
    public let turnID: String
    public let itemID: String?
    public let questions: [Question]
    public init(params: JSONValue) throws {
        sessionID = try MuseProtocol.identity(params["sessionId"])
        userInputID = try MuseProtocol.text(params["userInputId"], maximum: 4_096)
        turnID = try MuseProtocol.identity(params["turnId"])
        itemID = try MuseProtocol.optionalText(params["itemId"], maximum: 4_096)
        guard let rows = params["questions"].array, !rows.isEmpty, rows.count <= 32 else { throw MuseMSPError(.protocolViolation) }
        questions = try rows.map { row in
            let mode = row["selection"]["mode"]
            guard [JSONValue.string("single"), .string("multiple")].contains(mode), let options = row["options"].array, options.count <= 128 else { throw MuseMSPError(.protocolViolation) }
            let low = row["selection"]["minSelections"] == .null ? nil : try MuseProtocol.integer(row["selection"]["minSelections"], maximum: 128)
            let high = row["selection"]["maxSelections"] == .null ? nil : try MuseProtocol.integer(row["selection"]["maxSelections"], maximum: 128)
            guard (low ?? 0) <= (high ?? 128), mode != .string("single") || (low ?? 0) <= 1 else { throw MuseMSPError(.protocolViolation) }
            let values = try options.map { option -> Option in
                let preview = option["preview"]
                // Exact SDK UserInputOptionPreview shape is {content,format}.
                let previewText = preview == .null ? nil : try MuseProtocol.text(preview["content"], maximum: 65_536, empty: true)
                let previewFormat = preview == .null ? nil : try MuseProtocol.text(preview["format"], maximum: 128)
                return .init(label: try MuseProtocol.text(option["label"], maximum: 4_096), description: try MuseProtocol.optionalText(option["description"], maximum: 16_384), preview: previewText, previewFormat: previewFormat)
            }
            guard Set(values.map(\.label)).count == values.count else { throw MuseMSPError(.protocolViolation) }
            return .init(id: try MuseProtocol.text(row["id"], maximum: 4_096), header: try MuseProtocol.text(row["header"], maximum: 4_096, empty: true), question: try MuseProtocol.text(row["question"], maximum: 65_536), options: values,
                         multiple: mode == .string("multiple"), minimumSelections: low, maximumSelections: high)
        }
        guard Set(questions.map(\.id)).count == questions.count else { throw MuseMSPError(.protocolViolation) }
    }
    public func answerBody(selections: [String: [String]], notes: [String: String] = [:]) throws -> JSONValue {
        let ids = Set(questions.map(\.id))
        guard Set(selections.keys).isSubset(of: ids), Set(notes.keys).isSubset(of: ids) else { throw MuseMSPError(.invalidInput) }
        let answers = try questions.map { question -> JSONValue in
            let selected = selections[question.id] ?? [], note = notes[question.id] ?? ""
            guard selected.count == Set(selected).count, selected.allSatisfy({ label in question.options.contains { $0.label == label } }),
                  question.multiple || selected.count <= 1, selected.isEmpty || selected.count >= (question.minimumSelections ?? 0),
                  selected.count <= (question.maximumSelections ?? 128), note.utf16.count <= 500, !note.contains("\0"),
                  !selected.isEmpty || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MuseMSPError(.invalidInput) }
            var answer: [String: JSONValue] = ["questionId": .string(question.id)]
            if !selected.isEmpty { answer[question.multiple ? "selectedLabels" : "selectedLabel"] = question.multiple ? .array(selected.map(JSONValue.string)) : .string(selected[0]) }
            if !note.isEmpty { answer[selected.isEmpty ? "freeText" : "note"] = .string(note) }
            return .object(answer)
        }
        return .object(["userInputId": .string(userInputID), "answers": .array(answers)])
    }
    public func answerBody(answers: [String: String]) throws -> JSONValue {
        var selections: [String: [String]] = [:], notes: [String: String] = [:]
        guard Set(answers.keys) == Set(questions.map(\.id)) else { throw MuseMSPError(.invalidInput) }
        for question in questions {
            let value = answers[question.id]!
            if question.options.contains(where: { $0.label == value }) { selections[question.id] = [value] } else { notes[question.id] = value }
        }
        return try answerBody(selections: selections, notes: notes)
    }
    public func cancelBody() -> JSONValue { .object(["userInputId": .string(userInputID)]) }
    public func approval(localID: JSONValue) -> ApprovalRequest {
        .init(id: localID, method: "muse/userInput", params: .object(["questions": .array(questions.map { question in
            var selection: [String: JSONValue] = ["mode": .string(question.multiple ? "multiple" : "single")]
            if let low = question.minimumSelections { selection["minSelections"] = .number(Double(low)) }
            if let high = question.maximumSelections { selection["maxSelections"] = .number(Double(high)) }
            return .object(["id": .string(question.id), "header": .string(question.header), "question": .string(question.question), "selection": .object(selection), "options": .array(question.options.map { option in
                var row: [String: JSONValue] = ["label": .string(option.label)]
                if let value = option.description { row["description"] = .string(value) }
                if let value = option.preview { row["preview"] = .object(["content": .string(value), "format": .string(option.previewFormat ?? "text")]) }
                return .object(row)
            })])
        })]))
    }
    public static func presentation(_ request: ApprovalRequest) throws -> Self {
        guard request.method == "muse/userInput", let params = request.params.object, Set(params.keys) == ["questions"] else { throw MuseMSPError(.invalidInput) }
        let safe = "00000000-0000-7000-8000-000000000000"
        return try .init(params: .object(["sessionId": .string(safe), "turnId": .string(safe), "userInputId": .string("presentation"), "questions": request.params["questions"]]))
    }
}
