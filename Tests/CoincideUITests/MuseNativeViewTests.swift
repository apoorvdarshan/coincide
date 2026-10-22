import AppKit
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private func museApprovalFixture(long: Bool = false) throws -> MuseApprovalRequest {
    try .init(params: .object([
        "sessionId": .string("00000000-0000-7000-8000-000000000001"),
        "approvalId": .string("permission-native"),
        "currentRequirementId": .object(["approvalId": .string("permission-native"), "sourceIndex": .number(2)]),
        "subject": .object(["kind": .string("write"), "path": .string(long ? String(repeating: "Review exact 工作 🌍 /source/file.swift\n", count: 100) : "/source/file.swift")]),
        "availableChoices": .array([
            .object(["choiceId": .string("once-exact"), "label": .string("Allow"), "decision": .string("approved"), "scope": .string("once")]),
            .object(["choiceId": .string("session-exact"), "label": .string("Allow"), "decision": .string("approvedForSession"), "scope": .string("session")]),
            .object(["choiceId": .string("persistent-exact"), "label": .string(long ? String(repeating: "Save the reviewed local permission rule 工作. ", count: 10) : "Save rule"), "decision": .string("approvedPolicyAmendment"), "scope": .string("localPersistent"),
                "rulePreview": .string(long ? String(repeating: "Allow writes only within /source/reviewed/工作\n", count: 80) : "Allow writes only within /source/reviewed")]),
            .object(["choiceId": .string("decline-exact"), "label": .string("Decline"), "decision": .string("denied"), "scope": .string("once"), "acceptsFeedback": .bool(true)])
        ])
    ]))
}

private func museQuestionFixture(long: Bool = false) throws -> MuseUserInputRequest {
    let question = long ? String(repeating: "Review the exact choices before answering. مرحبًا 工作 🌍\n", count: 40) : "Which changes should the agent make?"
    return try .init(params: .object([
        "sessionId": .string("00000000-0000-7000-8000-000000000001"),
        "turnId": .string("00000000-0000-7000-8000-000000000002"),
        "userInputId": .string("questions-native"),
        "questions": .array([
            .object(["id": .string("scope"), "header": .string("Choose the scope"), "question": .string(question),
                "selection": .object(["mode": .string("multiple"), "minSelections": .number(2), "maxSelections": .number(2)]),
                "options": .array([
                    .object(["label": .string("A/B"), "description": .string("Keep punctuation literal."), "preview": .object(["content": .string("let original = \"A/B\""), "format": .string("text")])]),
                    .object(["label": .string("A B"), "description": .string("A distinct offered option.")]),
                    .object(["label": .string("Café 工作 🌍")])])]),
            .object(["id": .string("approach"), "header": .string("Approach"), "question": .string("Which approach?"),
                "selection": .object(["mode": .string("single"), "minSelections": .number(1), "maxSelections": .number(1)]),
                "options": .array([.object(["label": .string("Small change")]), .object(["label": .string("Complete change")])])]),
            .object(["id": .string("written"), "header": .string("Your answer"), "question": .string("What should stay unchanged?"),
                "selection": .object(["mode": .string("single")]), "options": .array([])])
        ])
    ]))
}

private func museAnswered(_ request: MuseUserInputRequest) -> MuseUserInputSelection {
    var selection = MuseUserInputSelection()
    selection.set(true, label: "A B", question: request.questions[0])
    selection.set(true, label: "A/B", question: request.questions[0])
    selection.setNote(" Keep exact whitespace 工作 🌍\n", question: request.questions[0])
    selection.set(true, label: "Small change", question: request.questions[1])
    selection.setNote("Preserve my unsent draft.", question: request.questions[2])
    return selection
}

@Test func nativeMuseQuestionAnswersKeepOfferedOrderNotesAndCustomTextWithinExactLimits() throws {
    let request = try museQuestionFixture(), scope = request.questions[0], approach = request.questions[1], written = request.questions[2]
    var selection = MuseUserInputSelection()
    #expect(selection.validated(for: request) == nil, "A question must never submit a preselected answer.")
    selection = museAnswered(request)
    selection.set(true, label: "Complete change", question: approach)
    selection.set(true, label: "unoffered", question: scope)
    let result = try #require(selection.validated(for: request))
    #expect(result.choices["scope"] == ["A/B", "A B"])
    #expect(result.choices["approach"] == ["Complete change"])
    #expect(result.notes["scope"] == " Keep exact whitespace 工作 🌍\n")
    let answers = try #require(request.answerBody(selections: result.choices, notes: result.notes)["answers"].array)
    #expect(answers[0]["selectedLabels"] == .array([.string("A/B"), .string("A B")]))
    #expect(answers[0]["note"] == .string(" Keep exact whitespace 工作 🌍\n") && answers[0]["freeText"] == .null)
    #expect(answers[2]["freeText"] == .string("Preserve my unsent draft.") && answers[2]["selectedLabel"] == .null)
    #expect(request.questions[0].options[0].preview == "let original = \"A/B\"")

    selection.set(true, label: "Café 工作 🌍", question: scope)
    #expect(selection.validated(for: request) == nil, "An extra option exceeds the captured maximum.")
    selection.set(false, label: "Café 工作 🌍", question: scope)
    selection.set(false, label: "A B", question: scope)
    #expect(selection.validated(for: request) == nil, "Notes do not override a minimum when options remain selected.")
    selection.clear(question: scope)
    #expect(selection.validated(for: request) != nil, "A written answer can replace all selected options, including a constrained question.")
    selection.setNote(String(repeating: "🌍", count: 250), question: written)
    #expect(selection.validated(for: request) != nil)
    selection.setNote(String(repeating: "🌍", count: 250) + "x", question: written)
    #expect(selection.validated(for: request) == nil, "The limit is exactly 500 UTF16 units; do not silently truncate input.")
    selection.setNote(" \n\t ", question: written)
    #expect(selection.validated(for: request) == nil)
    selection.setNote("Valid\0invalid", question: written)
    #expect(selection.validated(for: request) == nil)
}

@MainActor @Test func nativeMuseApprovalAndQuestionsRequireExplicitActionsAndRespectPendingResponse() throws {
    let approval = try museApprovalFixture(), questions = try museQuestionFixture()
    let displayedApproval = try MuseApprovalRequest.presentation(approval.approval(localID: .string("native-local-request")))
    #expect(displayedApproval.choices.first(where: { $0.id == "persistent-exact" })?.rulePreview == "Allow writes only within /source/reviewed")
    var choiceIDs: [String] = [], submissions: [[String: [String]]] = [], submittedNotes: [[String: String]] = [], cancellations = 0
    let choices = MuseApprovalView(request: approval, isResponding: false, onOption: { choiceIDs.append($0) })
    let input = MuseUserInputView(request: questions, isResponding: false,
        onAnswer: { submissions.append($0); submittedNotes.append($1) }, onCancel: { cancellations += 1 })
    #expect(choiceIDs.isEmpty && submissions.isEmpty && cancellations == 0)
    choices.choose("session-exact"); choices.choose("unoffered"); choices.choose("once-exact")
    #expect(choiceIDs == ["session-exact", "once-exact"], "Identical display labels must retain their different scope and exact offered IDs.")
    input.submit(.init())
    #expect(submissions.isEmpty)
    let answered = museAnswered(questions)
    input.submit(answered)
    #expect(submissions == [["scope": ["A/B", "A B"], "approach": ["Small change"]]])
    #expect(submittedNotes.first?["scope"] == " Keep exact whitespace 工作 🌍\n")
    input.cancel()
    let pendingChoices = MuseApprovalView(request: approval, isResponding: true, onOption: { choiceIDs.append($0) })
    let pendingInput = MuseUserInputView(request: questions, isResponding: true,
        onAnswer: { submissions.append($0); submittedNotes.append($1) }, onCancel: { cancellations += 1 })
    pendingChoices.choose("persistent-exact"); pendingInput.submit(answered); pendingInput.cancel()
    #expect(choiceIDs == ["session-exact", "once-exact"] && submissions.count == 1 && cancellations == 1)
    #expect(MuseApprovalView.scopeDescription("once") != MuseApprovalView.scopeDescription("session"))
    #expect(MuseApprovalView.scopeDescription("localPersistent") != MuseApprovalView.scopeDescription("session"))
}

@MainActor private final class MuseViewGeometry { var frames: [String: CGRect] = [:] }

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeMuseLongRequestsKeepExplicitControlsInsideNarrowCardsInBothDirectionsAndAppearances() async throws {
    _ = NSApplication.shared
    for scheme in [ColorScheme.light, .dark] {
        for width in [CGFloat(320), 680] {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                let approval = MuseViewGeometry(), questions = MuseViewGeometry()
                try await captureMuseView(MuseApprovalView(request: museApprovalFixture(long: true), isResponding: false,
                    onOption: { _ in Issue.record("Rendering must not answer a Muse permission request.") }, reportGeometry: { approval.frames[$0] = $1 }),
                    geometry: approval, regions: ["header", "details", "choices"], name: "approval", width: width, scheme: scheme, direction: direction)
                try await captureMuseView(MuseUserInputView(request: museQuestionFixture(long: true), isResponding: false,
                    onAnswer: { _, _ in Issue.record("Rendering must not answer Muse questions.") },
                    onCancel: { Issue.record("Rendering must not cancel Muse questions.") }, reportGeometry: { questions.frames[$0] = $1 }),
                    geometry: questions, regions: ["header", "questions", "actions"], name: "questions", width: width, scheme: scheme, direction: direction)
            }
        }
    }
}

@MainActor private func captureMuseView<Content: View>(_ content: Content, geometry: MuseViewGeometry, regions: [String],
    name: String, width: CGFloat, scheme: ColorScheme, direction: LayoutDirection) async throws {
    let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
    let originalAppearance = NSApp.appearance
    NSApp.appearance = appearance
    defer { NSApp.appearance = originalAppearance }
    let root = content.padding(16).coincideSurface().environment(\.colorScheme, scheme)
        .environment(\.layoutDirection, direction).environment(\.controlActiveState, .active)
    var size = CGSize.zero
    var preparedHosting: NSHostingView<AnyView>?
    var preparedWindow: NSWindow?
    appearance.performAsCurrentDrawingAppearance {
        let controller = NSHostingController(rootView: root)
        size = controller.sizeThatFits(in: .init(width: width, height: 540))
        guard size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 else { return }
        let hosting = NSHostingView(rootView: AnyView(root.frame(width: width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))))
        let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: width, height: size.height),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance; hosting.appearance = appearance
        window.isReleasedWhenClosed = false; window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        preparedHosting = hosting; preparedWindow = window
    }
    #expect(size.width > 0 && size.width <= width + 1 && size.height > 0 && size.height <= 540)
    let hosting = try #require(preparedHosting), window = try #require(preparedWindow)
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(100))
    appearance.performAsCurrentDrawingAppearance {
        hosting.layoutSubtreeIfNeeded(); hosting.needsDisplay = true; hosting.displayIfNeeded()
    }
    let bounds = try #require(geometry.frames["bounds"])
    for region in regions {
        let frame = try #require(geometry.frames[region])
        #expect(frame.width > 0 && frame.height > 0 && bounds.insetBy(dx: -1, dy: -1).contains(frame),
            "Long request text must scroll while the native controls remain inside the card.")
    }
    if name == "approval" {
        let label = try #require(geometry.frames["choice-label-persistent-exact"])
        let choices = try #require(geometry.frames["choices"])
        #expect(label.width <= choices.width + 1 && label.height > 30,
            "The complete offered choice label must wrap outside the native one-line action button.")
    }
    guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_MUSE"] == "1" else { return }
    var preparedBitmap: NSBitmapImageRep?
    appearance.performAsCurrentDrawingAppearance {
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap); preparedBitmap = bitmap
        }
    }
    let bitmap = try #require(preparedBitmap)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-muse-\(name)-\(Int(width))-\(scheme == .light ? "light" : "dark")-\(direction == .leftToRight ? "ltr" : "rtl").png")
    try data.write(to: url)
    print("Native Muse preview: \(url.path)")
}
