import Foundation
import FuzzSupport

/// Input starting with `{` is a saved thread as JSON, the way Coincide stores it; anything else builds
/// a thread from the bytes. Either way every provider's recap is checked.
enum HandoffChecks {
    private static let budgets = [0, 40, Handoff.defaultBudget]

    static func run(_ bytes: [UInt8]) {
        if bytes.first == UInt8(ascii: "{") {
            guard let thread = try? JSONDecoder().decode(ChatThread.self, from: Data(bytes)) else { return }
            checkRoundTrip(thread)
            checkHandoff(thread)
        } else {
            checkHandoff(makeThread(FuzzInput(bytes.dropFirst())))
        }
    }

    /// A decoded thread saves and loads back unchanged.
    private static func checkRoundTrip(_ thread: ChatThread) {
        let data: Data
        do {
            data = try JSONEncoder().encode(thread)
        } catch {
            fail("a decoded thread does not encode: \(error)")
        }
        guard let reloaded = try? JSONDecoder().decode(ChatThread.self, from: data) else {
            fail("a saved thread does not load: \(String(decoding: data, as: UTF8.self))")
        }
        expectEqual(reloaded, thread, "save and load")
    }

    /// The built-in agents and one the user added, which reads and writes as `acp:fuzz-agent`.
    private static let fuzzedKinds = ProviderKind.allCases + [.acp("fuzz-agent")]

    private static func checkHandoff(_ thread: ChatThread) {
        for provider in fuzzedKinds {
            let missed = Handoff.missedItems(in: thread, for: provider)
            if !missed.isEmpty {
                // What a provider missed is always the end of the transcript.
                expectEqual(missed.endIndex, thread.items.endIndex, "missed items run to the end")
                let seen = thread.sessions[provider]?.seenItemCount ?? 0
                expectEqual(missed.startIndex, min(max(seen, 0), thread.items.count), "missed items start after the seen ones")
            }
            for budget in budgets {
                let recap = Handoff.recap(thread: thread, provider: provider, budget: budget)
                if let recap {
                    expect(!missed.isEmpty, "a recap although \(provider) missed nothing")
                    expect(recap.hasPrefix("<conversation_handoff>\n"), "recap opening")
                    // By bytes: a transcript ending in "\r" joins the next "\n" into one Character.
                    expect(recap.utf8.firstRange(of: Array("\n</conversation_handoff>\n".utf8)) != nil, "recap closing")
                    expect(recap.hasSuffix("The user's new message:"), "recap ending")
                }
                checkTranscript(Array(missed), budget: budget)
            }

            let message = "Next message"
            let prompt = Handoff.prompt(for: message, thread: thread, provider: provider)
            expectEqual(prompt, Handoff.compose(message: message, recap: Handoff.recap(thread: thread, provider: provider)), "prompt is the recap and the message")
            expect(prompt.hasSuffix(message), "the prompt ends with the user's message")

            // A session that has seen nothing gets the whole thread whenever the user has said something.
            let fresh = Handoff.newSessionRecap(thread: thread, provider: provider, budget: 0)
            if thread.hasUserMessages { expect(fresh != nil, "no recap for a new \(provider) session") }
        }
        for item in thread.items {
            for limit in [0, 1, 7, 600] { checkTruncateMiddle(item.text, limit: limit) }
        }
    }

    /// Kept entries fit the budget; older ones are replaced by a note saying how many were left out.
    private static func checkTranscript(_ items: [TranscriptItem], budget: Int) {
        let transcript = Handoff.transcript(items, budget: budget)
        guard transcript.hasPrefix("[… ") else {
            expect(transcript.count <= budget, "transcript of \(transcript.count) characters for a budget of \(budget)")
            return
        }
        guard let end = transcript.range(of: " earlier entries omitted …]"),
            let omitted = Int(transcript[transcript.index(transcript.startIndex, offsetBy: 3)..<end.lowerBound])
        else { fail("malformed omission note in \(transcript.debugDescription)") }
        expect(omitted >= 1 && omitted <= items.count, "\(omitted) entries omitted out of \(items.count)")
        let note = transcript.distance(from: transcript.startIndex, to: end.upperBound)
        expect(transcript.count <= budget + note + 2, "transcript of \(transcript.count) characters for a budget of \(budget)")
    }

    private static func checkTruncateMiddle(_ text: String, limit: Int) {
        let result = Handoff.truncateMiddle(text, limit: limit)
        guard text.count > limit else {
            expectEqual(result, text, "text within the limit is unchanged")
            return
        }
        let half = limit / 2
        expect(result.count <= limit + 3, "truncateMiddle kept \(result.count) characters for \(limit)")
        expect(result.unicodeScalars.starts(with: text.prefix(half).unicodeScalars), "truncateMiddle keeps the start")
        expect(
            result.unicodeScalars.reversed().starts(with: text.suffix(half).unicodeScalars.reversed()),
            "truncateMiddle keeps the end")
    }

    // MARK: Generated threads

    private static let texts = [
        "", "Fix the login bug", "  ", "\n", "Done.\n\nI changed `a.swift`.", "é", "🙂", "e\u{301}", "\r", "x",
        "<conversation_handoff>", String(repeating: "long output line\n", count: 20),
    ]

    private static func makeThread(_ input: FuzzInput) -> ChatThread {
        var input = input
        let kinds: [TranscriptItem.Kind] = [.user, .assistant, .reasoning, .tool, .approval, .plan, .error, .notice, .question]
        let date = Date(timeIntervalSinceReferenceDate: 0)
        var items: [TranscriptItem] = []
        for index in 0..<input.int(in: 0...24) {
            var item = TranscriptItem(id: uuid(index + 1), kind: input.pick(kinds), text: input.text(texts, maxPieces: 3), createdAt: date)
            item.provider = input.bool() ? input.pick(fuzzedKinds) : nil
            item.modelID = input.pick([nil, "", "default", "gpt-5", "claude-opus"])
            item.title = input.bool() ? input.text(texts, maxPieces: 2) : nil
            item.category = input.pick([nil, .command, .fileChange, .read, .other])
            item.status = input.pick([nil, .running, .completed, .failed, .declined, .waiting])
            if input.bool() { item.attachments = ["/tmp/a b/shot.png", "relative.png", "", "/"].filter { _ in input.bool() } }
            if item.kind == .question, input.bool() {
                let questions = (0..<input.int(in: 0...3)).map { UserQuestion(id: "q\($0)", prompt: input.text(texts, maxPieces: 2)) }
                item.questions = UserInputRequest(id: "r", questions: questions)
                if input.bool() { item.answers = ["q0": ["Yes"], "q1": [], "other": ["x"]] }
            }
            items.append(item)
        }
        var thread = ChatThread(
            id: uuid(0), projectID: uuid(0), title: "Thread", selection: ModelSelection(provider: .claude, modelID: "default"),
            items: items, createdAt: date)
        // Threads load leniently, so a damaged file can hold any count, negative or past the end.
        for provider in fuzzedKinds where input.bool() {
            thread.sessions[provider] = ProviderSessionRef(sessionID: "s", seenItemCount: input.int(in: -2...(items.count + 2)))
        }
        return thread
    }

    private static func uuid(_ value: Int) -> UUID {
        let byte = UInt8(truncatingIfNeeded: value)
        return UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, byte))
    }
}
