import AppKit
@testable import CoincideCore
import SwiftUI
import Testing
@testable import Coincide

private func nativeClaudeQuestions(long: Bool = false) throws -> ClaudeQuestionRequest {
    let prompt = long ? String(repeating: "Choose the exact native option, preserving 工作 and 🌍. ", count: 40) : " Which path / 工作? "
    let detail = long ? String(repeating: "Native description and preview content. ", count: 100) : "Exact explanation"
    return try ClaudeQuestionRequest(request: .init(id: .string("question-1"), method: "can_use_tool", params: .object([
        "tool_name": .string("AskUserQuestion"), "input": .object(["questions": .array([
            .object(["header": .string("Single"), "question": .string(prompt), "multiSelect": .bool(false), "options": .array([
                .object(["label": .string("a/b"), "description": .string(detail), "preview": .string(detail)]),
                .object(["label": .string("a b"), "description": .string(detail)])])]),
            .object(["header": .string("Multiple"), "question": .string("Which features, exactly?"), "multiSelect": .bool(true), "options": .array([
                .object(["label": .string("First, literal"), "description": .string(detail)]),
                .object(["label": .string("Second 🌍"), "description": .string(detail)])])])
        ])])
    ])))
}

@Test func nativeClaudeQuestionControlsKeepSingleMultipleAndCustomAnswersExplicit() throws {
    let request = try nativeClaudeQuestions(), single = request.questions[0], multiple = request.questions[1]
    var selection = ClaudeQuestionSelection()
    #expect(selection.validated(for: request) == nil)
    selection.toggle(true, option: single.options[0], question: single)
    selection.toggle(true, option: single.options[1], question: single)
    #expect(selection.choices[single.question] == ["a b"])
    selection.toggle(true, option: multiple.options[1], question: multiple)
    selection.toggle(true, option: multiple.options[0], question: multiple)
    selection.setCustom(" custom, 工作 🌍 ", question: multiple)
    selection.notes[single.question] = " exact notes "
    let answers = try #require(selection.validated(for: request))
    #expect(answers.selections[single.question] == ["a b"])
    #expect(answers.selections[multiple.question] == ["First, literal", "Second 🌍", " custom, 工作 🌍 "])
    #expect(answers.notes[single.question] == " exact notes ")
    selection.setCustom(" single custom ", question: single)
    #expect(selection.choices[single.question] == nil)
    #expect(selection.validated(for: request)?.selections[single.question] == [" single custom "])
    selection.toggle(true, option: single.options[0], question: single)
    #expect(selection.custom[single.question] == nil)
    #expect(selection.validated(for: request)?.selections[single.question] == ["a/b"])
    selection.toggle(false, option: single.options[0], question: single)
    #expect(selection.validated(for: request) == nil)
}

@Test @MainActor func nativeClaudeQuestionCancellationIsExplicitAndDisabledDuringResponse() throws {
    var submitted = 0, cancelled = 0
    let request = try nativeClaudeQuestions()
    let view = ClaudeQuestionApprovalView(request: request, isResponding: false,
        onSubmit: { _, _ in submitted += 1 }, onCancel: { cancelled += 1 })
    #expect(submitted == 0 && cancelled == 0)
    view.cancel()
    #expect(cancelled == 1 && submitted == 0)
    let responding = ClaudeQuestionApprovalView(request: request, isResponding: true,
        onSubmit: { _, _ in submitted += 1 }, onCancel: { cancelled += 1 })
    responding.cancel()
    #expect(cancelled == 1 && submitted == 0)
}

@Test @MainActor func nativeClaudeQuestionLongContentFitsNarrowCardsWithoutSubmittingOnRender() throws {
    var submitted = 0, cancelled = 0
    let request = try nativeClaudeQuestions(long: true)
    for width in [CGFloat(320), 680] {
        for scheme in [ColorScheme.light, .dark] {
            let view = ClaudeQuestionApprovalView(request: request, isResponding: false,
                onSubmit: { _, _ in submitted += 1 }, onCancel: { cancelled += 1 })
            let host = NSHostingView(rootView: view.frame(width: width).environment(\.colorScheme, scheme))
            host.frame = .init(x: 0, y: 0, width: width, height: 500); host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width <= width + 1 && host.fittingSize.height < 720)
        }
    }
    #expect(submitted == 0 && cancelled == 0)
}
