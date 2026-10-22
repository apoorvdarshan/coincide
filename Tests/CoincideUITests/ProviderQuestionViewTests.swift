import AppKit
import CoincideCore
import Foundation
import SwiftUI
import Testing
@testable import Coincide

private func providerQuestionValue(_ raw: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) }

@Test @MainActor func nativeOpenCodeQuestionControlsKeepExactLabelsAndMultipleCustomAnswers() throws {
    let question = try OpenCodeV1Protocol.question(providerQuestionValue(#"{"id":"q-native","sessionID":"ses-native","questions":[{"header":"Pick","question":"Choose labels","options":[{"label":"a/b","description":"Slash"},{"label":"a b","description":"Space"}],"multiple":true}]}"#))
    let field = try #require(question.questions.first)
    var selection = OpenCodeQuestionSelection()
    #expect(selection.answers(for: question) == nil)
    selection.toggle(true, value: "a/b", question: field)
    selection.toggle(true, value: "a b", question: field)
    selection.toggle(true, value: " custom 工作 🌍 ", question: field)
    let answers = try #require(selection.answers(for: question))
    #expect(answers[field.key] == ["a/b", "a b", " custom 工作 🌍 "])
    #expect(try question.answerBody(selections: answers)["answers"] == .array([.array([.string("a/b"), .string("a b"), .string(" custom 工作 🌍 ")])]))
    selection.toggle(false, value: "a/b", question: field)
    #expect(selection.answers(for: question)?[field.key] == ["a b", " custom 工作 🌍 "])
}

@Test @MainActor func nativeGrokQuestionControlsSubmitSelectedIDsAndNotesTogetherWithPreview() throws {
    let question = try GrokACPQuestionRequest(params: providerQuestionValue(#"{"sessionId":"ses-native","toolCallId":"call-native","mode":"default","questions":[{"id":"q","question":"Which version?","options":[{"id":"one","label":"Same label / one","preview":"Exact preview"},{"id":"two","label":"Same label / two"}]}]}"#))
    let field = try #require(question.questions.first), option = try #require(field.options.first)
    var selection = GrokQuestionSelection()
    #expect(selection.validated(for: question) == nil)
    selection.toggle(true, option: option, question: field); selection.notes[field.id] = "Keep this note"
    let combined = try #require(selection.validated(for: question))
    let body = try question.response(selections: combined.choices, notes: combined.notes)
    #expect(body["answers"][field.question] == .array([.string(option.label)]))
    #expect(body["annotations"][field.question]["notes"] == .string("Keep this note"))
    #expect(body["annotations"][field.question]["preview"] == .string("Exact preview"))
    selection.toggle(false, option: option, question: field)
    let other = try #require(selection.validated(for: question))
    #expect(try question.response(selections: other.choices, notes: other.notes)["answers"][field.question] == .array([.string("Other")]))
}

@Test @MainActor func nativeProviderQuestionViewsBoundLongContentWithoutSubmittingOnRender() throws {
    var submitted = 0, cancelled = 0
    let longQuestion = String(repeating: "Choose the exact native option, preserving 工作 and 🌍. ", count: 40)
    let openCode = try OpenCodeV1Protocol.question(.object([
        "id": .string("q"), "sessionID": .string("ses"), "questions": .array([.object([
            "header": .string("Header"), "question": .string(longQuestion),
            "options": .array((0..<24).map { .object(["label": .string("Option \($0)"), "description": .string(longQuestion)]) })
        ])])
    ]))
    let grok = try GrokACPQuestionRequest(params: .object([
        "sessionId": .string("ses"), "toolCallId": .string("call"), "mode": .string("default"), "questions": .array([.object([
            "id": .string("q"), "question": .string(longQuestion),
            "options": .array((0..<24).map { .object(["id": .string("option-\($0)"), "label": .string("Option \($0)"), "description": .string(longQuestion), "preview": .string(longQuestion)]) })
        ])])
    ]))
    let views: [AnyView] = [
        AnyView(OpenCodeQuestionApprovalView(request: openCode, isResponding: false, onSelections: { _ in submitted += 1 }, onCancel: { cancelled += 1 })),
        AnyView(GrokQuestionApprovalView(request: grok, isResponding: false, onSubmit: { _, _ in submitted += 1 }, onCancel: { cancelled += 1 }))
    ]
    for view in views {
        let host = NSHostingView(rootView: view.frame(width: 320))
        host.frame = .init(x: 0, y: 0, width: 320, height: 500); host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 321 && host.fittingSize.height < 720)
    }
    #expect(submitted == 0 && cancelled == 0)
}
