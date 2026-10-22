import AppKit
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private func nativeFormFixture(unsupported: Bool = false, longTitle: Bool = false) throws -> OpenCodeV2Form {
    try OpenCodeV2Protocol.form(.object([
        "id": .string("frm_native_ui"), "sessionID": .string("ses_native_ui"),
        "title": .string(longTitle ? String(repeating: "Read the complete native form title. ", count: 300) : "Choose native options"),
        "fields": .array([
            .object(["key": .string("tools"), "type": .string("multiselect"), "title": .string("Tools"), "required": .bool(true), "minItems": .number(1), "maxItems": .number(2),
                "options": .array([.object(["value": .string("wire-a"), "label": .string("Same display label")]), .object(["value": .string("wire-b"), "label": .string("Same display label")])])]),
            .object(["key": .string("note"), "type": .string(unsupported ? "external" : "string"), "title": .string("Native note"), "required": .bool(true), "maxLength": .number(3)]),
            .object(["key": .string("optional"), "type": .string("string"), "title": .string("Optional note")])
        ])
    ]))
}

@Test func nativeOpenCodeFormSelectionKeepsDistinctWireValuesAndUTF16Constraints() throws {
    let form = try nativeFormFixture(), multi = form.fields[0], note = form.fields[1]
    var selection = OpenCodeFormSelection(form: form)
    #expect(selection.answers(for: form) == nil)
    selection.select(true, value: "Same display label", field: multi)
    #expect(selection.values.isEmpty)
    selection.select(true, value: "wire-b", field: multi); selection.select(true, value: "wire-a", field: multi)
    selection.select(true, value: "wire-b", field: multi)
    selection.text("猫🌍", field: note)
    let answer = try #require(selection.answers(for: form))
    #expect(answer["tools"] == ["wire-b", "wire-a"] && answer["note"] == ["猫🌍"] && answer["optional"] == nil)
    #expect(try form.answerBody(selections: answer)["answer"]["tools"] == .array([.string("wire-b"), .string("wire-a")]))
    selection.text("猫🌍x", field: note); #expect(selection.answers(for: form) == nil)
    selection.text("", field: note); #expect(selection.answers(for: form) == nil)
    selection.text("ok", field: note); selection.select(false, value: "wire-a", field: multi)
    #expect(selection.answers(for: form)?["tools"] == ["wire-b"])
}

@Test func nativeOpenCodeFormPresentationRoundTripPreservesUnsupportedAndOptionalState() throws {
    let original = try nativeFormFixture(), request = original.approval(localID: .string("local-native-form"))
    let presented = try #require(request.openCodeForm)
    #expect(request.isQuestion && request.title == original.title)
    #expect(presented.fields.map(\.key) == original.fields.map(\.key) && presented.unsupportedReason == nil)
    let values = ["tools": ["wire-a"], "note": ["ok"]]
    #expect(try presented.answerBody(selections: values) == original.answerBody(selections: values))
    #expect(presented.sessionID != original.sessionID && presented.id != original.id)
    let unsupported = try nativeFormFixture(unsupported: true)
    #expect(unsupported.unsupportedReason != nil)
    #expect(unsupported.approval(localID: .string("local-unsupported")).openCodeForm?.unsupportedReason == unsupported.unsupportedReason)
    #expect(OpenCodeFormSelection().answers(for: unsupported) == nil)
    var forged = request; forged.params = .object(["title": .string("Wrong form"), "questions": .array([]), "unexpected": .bool(true)])
    #expect(forged.openCodeForm == nil)
}

@Test func nativeOpenCodeClearingOptionalDefaultDoesNotResubmitItsUnselectedValue() throws {
    let option: JSONValue = .object(["value": .string("a"), "label": .string("Default choice")])
    let field: JSONValue = .object(["key": .string("choice"), "type": .string("multiselect"),
        "default": .array([.string("a")]), "options": .array([option])])
    let form = try OpenCodeV2Protocol.form(.object([
        "id": .string("frm_defaults"), "sessionID": .string("ses_defaults"), "title": .string("Optional choices"),
        "fields": .array([field])
    ]))
    var selection = OpenCodeFormSelection(form: form)
    #expect(selection.contains("a", field: form.fields[0]))
    selection.select(false, value: "a", field: form.fields[0])
    let observed = selection.answers(for: form), answers = try #require(observed)
    #expect(answers["choice"] == [])
    #expect(try form.answerBody(selections: answers)["answer"]["choice"] == .array([]))
}

@MainActor @Test func nativeOpenCodeFormsRenderInApprovalCardWithoutSendingResponses() throws {
    var sent = 0
    for unsupported in [false, true] {
      for longTitle in [false, true] {
        let request = try nativeFormFixture(unsupported: unsupported, longTitle: longTitle).approval(localID: .string("local-render-form"))
        for width in [CGFloat(320), 720] {
            let view = ApprovalView(request: request, onDecision: { _ in sent += 1 }, onAnswer: { _ in sent += 1 }, onSelections: { _ in sent += 1 })
                .frame(width: width).environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 560); host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            #expect(size.width.isFinite && size.height.isFinite && size.width <= width + 1 && size.height < 700)
        }
      }
    }
    #expect(sent == 0)
}
