import AppKit
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private func cursorQuestionFixture(long: Bool = false) -> CursorACPQuestionRequest {
    .init(toolCallID: "cursor-question-call", title: long ? String(repeating: "Review the agent's complete question title. ", count: 12) : "Choose a direction",
        questions: [
            .init(id: "tools", prompt: long ? String(repeating: "Which tools should the plan include? ", count: 12) : "Which tools?",
                options: [.init(id: "option-a", label: "Same label; keep literal punctuation"),
                          .init(id: "option-b", label: "Same label; keep literal punctuation"),
                          .init(id: "option-unicode", label: "Café λ — native tools")], allowMultiple: true),
            .init(id: "destination", prompt: "Where should the next work happen?",
                options: [.init(id: "first-id", label: "Use the current workspace"),
                          .init(id: "second-id", label: "Prepare another workspace")], allowMultiple: false)
        ])
}

private func cursorPlanFixture(long: Bool = false) -> CursorACPPlanRequest {
    .init(toolCallID: "cursor-plan-call", name: long ? String(repeating: "Review the complete plan title ", count: 20) : "Native implementation plan",
        overview: "Review this plan before authorizing the agent to continue.",
        plan: long ? String(repeating: "## Implementation\n\nKeep the user's work intact and validate the selected approach.\n\n```swift\nlet action = \"explicit approval\"\n```\n\n", count: 24)
            : "## Implementation\n\n1. Preserve the workspace.\n2. Apply the reviewed change.\n3. Run the focused checks.",
        todos: [.init(id: "todo-open", content: "Inspect the selected workspace", status: .pending),
                .init(id: "todo-running", content: "Review captured inputs", status: .inProgress),
                .init(id: "todo-done", content: "Retain the original draft", status: .completed),
                .init(id: "todo-cancelled", content: "An abandoned alternative", status: .cancelled)],
        phases: [.init(name: "Verification", todos: [.init(id: "phase-check", content: "Check the final result", status: .pending)]),
                 .init(name: "Verification", todos: [.init(id: "phase-second-check", content: "Inspect another verification step", status: .pending)])], isProject: true)
}

@Test func nativeCursorQuestionSelectionsRetainIDsAndProviderOrderAcrossSingleAndMultipleOptions() throws {
    let request = cursorQuestionFixture(), multi = request.questions[0], single = request.questions[1]
    var selection = CursorQuestionSelection()
    #expect(selection.answers(for: request) == nil, "No first option may be accepted by default.")
    selection.set(true, optionID: "option-b", question: multi)
    selection.set(true, optionID: "option-a", question: multi)
    selection.set(true, optionID: "option-unicode", question: multi)
    #expect(selection.answers(for: request) == nil, "Every question must have an explicit answer before submission.")
    selection.set(true, optionID: "first-id", question: single)
    selection.set(true, optionID: "second-id", question: single)
    let answer = try #require(selection.answers(for: request))
    #expect(answer["tools"] == ["option-a", "option-b", "option-unicode"])
    #expect(answer["destination"] == ["second-id"])
    #expect(!selection.contains(optionID: "first-id", questionID: "destination"))
    #expect(answer.values.flatMap { $0 }.allSatisfy { !$0.contains("Same label") && !$0.contains(";") })
    selection.set(false, optionID: "option-b", question: multi)
    selection.set(true, optionID: "unadvertised-id", question: multi)
    #expect(selection.answers(for: request)?["tools"] == ["option-a", "option-unicode"])
    selection.set(false, optionID: "second-id", question: single)
    #expect(selection.answers(for: request) == nil)
    let invalid = CursorACPQuestionRequest(toolCallID: request.toolCallID, questions: [multi, multi])
    #expect(selection.answers(for: invalid) == nil, "Malformed programmatic inputs must not crash or produce a response.")
}

@MainActor @Test func nativeCursorQuestionSkipAndPlanDecisionsAreExplicitAndIgnoreRepeatedRespondingActions() {
    var skips = 0, answers: [[String: [String]]] = [], decisions: [Bool] = []
    let question = CursorQuestionApprovalView(request: cursorQuestionFixture(), isResponding: false,
        onSelections: { answers.append($0) }, onSkip: { skips += 1 })
    let plan = CursorPlanApprovalView(request: cursorPlanFixture(), isResponding: false, onDecision: { decisions.append($0) })
    #expect(skips == 0 && answers.isEmpty && decisions.isEmpty, "Constructing or rendering a request never sends a response.")
    question.skip(); plan.decide(false); plan.decide(true)
    #expect(skips == 1 && answers.isEmpty && decisions == [false, true])
    let pendingQuestion = CursorQuestionApprovalView(request: cursorQuestionFixture(), isResponding: true,
        onSelections: { answers.append($0) }, onSkip: { skips += 1 })
    let pendingPlan = CursorPlanApprovalView(request: cursorPlanFixture(), isResponding: true, onDecision: { decisions.append($0) })
    pendingQuestion.skip(); pendingPlan.decide(false); pendingPlan.decide(true)
    #expect(skips == 1 && answers.isEmpty && decisions == [false, true])
}

@MainActor private final class CursorApprovalGeometry {
    var frames: [String: CGRect] = [:]
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCursorQuestionAndLongMarkdownPlanKeepExplicitActionsInsideNarrowAndWideCards() async throws {
    _ = NSApplication.shared
    for scheme in [ColorScheme.light, .dark] {
        for width in [CGFloat(320), 680] {
            let questions = CursorApprovalGeometry(), plan = CursorApprovalGeometry()
            try await captureCursorApproval(CursorQuestionApprovalView(request: cursorQuestionFixture(long: true), isResponding: false,
                onSelections: { _ in Issue.record("Rendering must not answer Cursor questions.") },
                onSkip: { Issue.record("Rendering must not skip Cursor questions.") },
                reportGeometry: { questions.frames[$0] = $1 }), geometry: questions, name: "questions", width: width, scheme: scheme)
            try await captureCursorApproval(CursorPlanApprovalView(request: cursorPlanFixture(long: true), isResponding: false,
                onDecision: { _ in Issue.record("Rendering must not accept or reject a Cursor plan.") },
                reportGeometry: { plan.frames[$0] = $1 }), geometry: plan, name: "plan", width: width, scheme: scheme)
        }
    }
}

@MainActor private func captureCursorApproval<Content: View>(_ content: Content, geometry: CursorApprovalGeometry,
    name: String, width: CGFloat, scheme: ColorScheme) async throws {
    let root = content.padding(16).coincideSurface().environment(\.colorScheme, scheme)
    let controller = NSHostingController(rootView: root)
    let size = controller.sizeThatFits(in: .init(width: width, height: 520))
    #expect(size.width <= width + 1 && size.height <= 520 && size.height > 0)
    let hosting = NSHostingView(rootView: root.frame(width: width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: width, height: size.height),
        styleMask: .borderless, backing: .buffered, defer: false)
    let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
    window.appearance = appearance; hosting.appearance = appearance
    window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
    let bounds = try #require(geometry.frames["bounds"]), header = try #require(geometry.frames["header"]), actions = try #require(geometry.frames["actions"])
    #expect(bounds.insetBy(dx: -1, dy: -1).contains(header))
    #expect(actions.height > 0 && bounds.insetBy(dx: -1, dy: -1).contains(actions), "Long provider content must scroll without clipping the decision controls.")
    guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_CURSOR"] == "1" else { return }
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-cursor-\(name)-\(Int(width))-\(scheme == .light ? "light" : "dark").png")
    try data.write(to: url)
    print("Native Cursor approval preview: \(url.path)")
}
