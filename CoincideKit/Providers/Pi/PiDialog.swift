import Foundation

/// A dialog a Pi extension raised (`extension_ui_request` with `confirm`, `select`, `input` or `editor`),
/// presented as an approval. Coincide's own extension raises a `confirm` for every tool call that needs one.
struct PiDialog {
    static let allowAlwaysID = "allow_always"

    let request: ApprovalRequest
    /// For confirmations "Always allow" can remember: the tool call's subject, or the dialog's text.
    let rememberKey: String?
    /// How long until Pi answers the dialog itself with its default.
    let timeout: Duration?
    /// Fields of the `extension_ui_response` for each option id.
    private let responses: [String: [String: JSONValue]]

    /// Nil for fire-and-forget requests (`notify`, `setStatus`, `setWidget`, …) and malformed ones.
    init?(_ record: JSONValue, tool: (String) -> PiTurnMapper.Tool?) {
        guard let id = record["id"]?.string, let method = record["method"]?.string else { return nil }
        let title = PiText.nonEmpty(record["title"]?.string)
        let message = PiText.nonEmpty(record["message"]?.string)
        switch method {
        case "confirm":
            let allow: [String: JSONValue] = ["confirmed": true]
            responses = ["allow": allow, Self.allowAlwaysID: allow, "deny": ["confirmed": false]]
            if let marker = record["message"]?.string.flatMap(JSONValue.parse), marker["coincide"]?.string == PiExtension.approvalMarker,
                let toolCallID = marker["toolCallId"]?.string
            {
                let known = tool(toolCallID)
                let name = known?.name ?? marker["toolName"]?.string ?? "tool"
                let info = known?.info ?? PiTools.info(id: toolCallID, name: name, args: known?.args)
                request = ApprovalRequest(
                    id: id, category: info.category, title: info.title, detail: info.detail,
                    options: ApprovalRequest.standardOptions, toolCallID: toolCallID)
                rememberKey = "tool\u{0}" + PiTools.approvalKey(name: name, args: known?.args)
            } else {
                request = ApprovalRequest(
                    id: id, category: .other, title: title ?? String(localized: "Pi asks for confirmation"), detail: message,
                    options: ApprovalRequest.standardOptions)
                rememberKey = "confirm\u{0}\(title ?? "")\u{0}\(message ?? "")"
            }
        case "select":
            let choices = (record["options"]?.array ?? []).compactMap(\.string)
            var responses: [String: [String: JSONValue]] = ["cancel": ["cancelled": true]]
            var options: [ApprovalOption] = []
            for (index, choice) in choices.enumerated() {
                let optionID = "option.\(index)"
                responses[optionID] = ["value": .string(choice)]
                options.append(
                    ApprovalOption(id: optionID, label: choice.isEmpty ? String(localized: "Empty value") : choice, kind: .allowOnce))
            }
            options.append(ApprovalOption(id: "cancel", label: String(localized: "Cancel"), kind: .cancel))
            self.responses = responses
            request = ApprovalRequest(
                id: id, category: .other, title: title ?? String(localized: "Pi asks you to choose"), detail: message,
                options: options)
            rememberKey = nil
        case "input":
            // Approvals have no text field, so an input dialog can be answered empty or dismissed.
            responses = ["empty": ["value": ""], "cancel": ["cancelled": true]]
            request = ApprovalRequest(
                id: id, category: .other, title: title ?? String(localized: "Pi asks for input"),
                detail: message ?? PiText.nonEmpty(record["placeholder"]?.string),
                options: [
                    ApprovalOption(id: "empty", label: String(localized: "Answer empty"), kind: .allowOnce),
                    ApprovalOption(id: "cancel", label: String(localized: "Cancel"), kind: .cancel),
                ])
            rememberKey = nil
        case "editor":
            let prefill = record["prefill"]?.string ?? ""
            responses = ["keep": ["value": .string(prefill)], "cancel": ["cancelled": true]]
            request = ApprovalRequest(
                id: id, category: .other, title: title ?? String(localized: "Pi asks you to edit text"),
                detail: prefill.isEmpty ? nil : prefill,
                options: [
                    ApprovalOption(id: "keep", label: String(localized: "Keep text"), kind: .allowOnce),
                    ApprovalOption(id: "cancel", label: String(localized: "Cancel"), kind: .cancel),
                ])
            rememberKey = nil
        default:
            return nil
        }
        // Pi treats a zero timeout as none and a negative one as already expired.
        timeout = record["timeout"]?.number.flatMap { $0 == 0 ? nil : Duration.milliseconds(max(0, $0)) }
    }

    /// The `extension_ui_response` for an option; anything unknown dismisses the dialog.
    func response(for optionID: String) -> JSONValue {
        var fields = responses[optionID] ?? ["cancelled": true]
        fields["type"] = "extension_ui_response"
        fields["id"] = .string(request.id)
        return .object(fields)
    }

    /// Whether the option refuses the dialog, which blocks the tool call it guards.
    func declines(_ optionID: String) -> Bool {
        guard let fields = responses[optionID] else { return true }
        return fields["confirmed"]?.bool == false || fields["cancelled"] != nil
    }
}
