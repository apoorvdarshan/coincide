import Foundation
import Testing

@testable import CoincideKit

/// A thread file written by a newer version must survive being opened and changed in this one.
@MainActor
struct ThreadFileTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-thread-file-\(UUID().uuidString)")

    private var threadsDirectory: URL { directory.appendingPathComponent("threads") }

    private func copiesAside() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: threadsDirectory.path).filter { $0.contains(".unreadable-") }
    }

    private func decode(_ json: String, checkingFields: Bool = true) throws -> ThreadFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if checkingFields { decoder.userInfo[.checksUnreadContent] = true }
        return try decoder.decode(ThreadFile.self, from: Data(json.utf8))
    }

    /// Names of the optional fields of `value` that hold nothing.
    private static func unsetFields(of value: Any) -> [String] {
        Mirror(reflecting: value).children.compactMap { child in
            let field = Mirror(reflecting: child.value)
            return field.displayStyle == .optional && field.children.isEmpty ? child.label : nil
        }
    }

    private static func fieldNames(of value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label))
    }

    @Test func aFileANewerVersionWroteIsCopiedAsideBeforeItsFirstSave() throws {
        let store = AppStore(directory: directory)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let thread = store.createThread(in: project.id)
        store.flush()
        let json = """
            {"id":"\(thread.id.uuidString)","projectID":"\(project.id.uuidString)","title":"Later",
             "createdAt":"2026-10-01T10:00:00Z","updatedAt":"2026-10-01T10:00:00Z",
             "selection":{"provider":"future","modelID":"x"},
             "items":[
               {"id":"\(UUID().uuidString)","kind":"user","text":"hello","createdAt":"2026-10-01T10:00:00Z"},
               {"id":"\(UUID().uuidString)","kind":"hologram","text":"?","createdAt":"2026-10-01T10:00:00Z"}
             ],
             "sessions":["claude",{"sessionID":"c1","seenItemCount":2},"future",{"sessionID":"f1","seenItemCount":2}]}
            """
        let file = threadsDirectory.appendingPathComponent("\(thread.id.uuidString).json")
        try Data(json.utf8).write(to: file)

        let older = AppStore(directory: directory)
        // Opening it changes nothing on disk.
        #expect(try copiesAside().isEmpty)
        older.append(TranscriptItem(kind: .user, text: "from the older version"), to: thread.id)
        older.flush()
        let copies = try copiesAside()
        #expect(copies.count == 1)
        let copy = try #require(copies.first)
        #expect(copy.hasPrefix("\(thread.id.uuidString).json.unreadable-"))
        #expect(try String(contentsOf: threadsDirectory.appendingPathComponent(copy), encoding: .utf8) == json)
        // The saved file keeps what this version reads.
        #expect(AppStore(directory: directory).thread(thread.id)?.items.map(\.text) == ["hello", "from the older version"])

        // What this version wrote itself is not copied again.
        let again = AppStore(directory: directory)
        again.updateThread(thread.id) { $0.title = "Renamed" }
        again.flush()
        #expect(try copiesAside().count == 1)
    }

    @Test func skippedItemsDoNotShiftWhatASessionHasSeen() throws {
        let ids = (0..<6).map { _ in UUID().uuidString }
        let json = """
            {"id":"\(UUID().uuidString)","projectID":"\(UUID().uuidString)",
             "items":[
               {"id":"\(ids[0])","kind":"user","text":"one"},
               "junk",
               {"id":"\(ids[1])","kind":"hologram"},
               {"id":"\(ids[2])","kind":"assistant","text":"two"},
               42,
               {"id":"\(ids[3])","kind":"user","text":"three"}
             ],
             "sessions":["claude",{"sessionID":"c","seenItemCount":6},"codex",{"sessionID":"x","seenItemCount":3}]}
            """
        // Loading (which skips the field check) and the check before a save agree.
        for checkingFields in [false, true] {
            let file = try decode(json, checkingFields: checkingFields)
            #expect(file.thread.items.map(\.text) == ["one", "two", "three"])
            #expect(file.thread.sessions[.claude]?.seenItemCount == 3)
            #expect(file.thread.sessions[.codex]?.seenItemCount == 1)
            #expect(file.hasUnreadContent)
        }
    }

    @Test func aFieldANewerVersionAddedIsKeptInTheCopy() throws {
        let store = AppStore(directory: directory)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let thread = store.createThread(in: project.id)
        store.append(TranscriptItem(kind: .user, text: "hello"), to: thread.id)
        store.flush()
        let file = threadsDirectory.appendingPathComponent("\(thread.id.uuidString).json")
        let original = try String(contentsOf: file, encoding: .utf8)
        // Every item is readable; one carries a field this version does not know.
        let newer = original.replacingOccurrences(of: #""kind":"user""#, with: #""kind":"user","reactions":["+1"]"#)
        #expect(newer != original)
        try Data(newer.utf8).write(to: file)

        let older = AppStore(directory: directory)
        older.updateThread(thread.id) { $0.draft = "typing" }
        older.flush()
        let copy = try #require(try copiesAside().first)
        #expect(try String(contentsOf: threadsDirectory.appendingPathComponent(copy), encoding: .utf8) == newer)
    }

    @Test func fieldsThisVersionCannotReadOrDoesNotKnowAreNoticed() throws {
        let base = #""id":"\#(UUID().uuidString)","projectID":"\#(UUID().uuidString)""#
        let bare = #""id":"\#(UUID().uuidString)","kind":"tool""#
        let item = #"\#(bare),"text":"out""#
        let session = #""claude",{"sessionID":"c","seenItemCount":1}"#
        let cases: [(String, Bool)] = [
            ("{\(base),\"items\":[{\(item)}],\"sessions\":[\(session)]}", false),
            ("{\(base),\"items\":[{\(item)}],\"draft\":null}", false),
            ("{\(base),\"items\":[{\(item),\"status\":\"paused\"}]}", true),
            ("{\(base),\"items\":[{\(item),\"provider\":\"future\"}]}", true),
            ("{\(base),\"items\":[{\(item),\"reactions\":[\"+1\"]}]}", true),
            ("{\(base),\"items\":[{\(bare),\"text\":{\"rich\":true}}]}", true),
            ("{\(base),\"items\":[{\(bare),\"text\":\"\"}]}", false),
            ("{\(base),\"accessMode\":\"readOnly\"}", true),
            ("{\(base),\"selection\":{\"provider\":\"claude\",\"modelID\":\"m\",\"variant\":\"fast\"}}", true),
            ("{\(base),\"selection\":{\"provider\":\"claude\",\"modelID\":\"m\",\"speed\":\"fast\",\"effort\":null}}", false),
            // The selection loads without an effort or speed it cannot read, which saving would drop.
            ("{\(base),\"selection\":{\"provider\":\"claude\",\"modelID\":\"m\",\"speed\":{\"tier\":\"fast\"}}}", true),
            ("{\(base),\"selection\":{\"provider\":\"claude\",\"modelID\":\"m\",\"effort\":3}}", true),
            ("{\(base),\"folder\":\"later\"}", true),
            ("{\(base),\"sessions\":[\"future\",{\"sessionID\":\"f\",\"seenItemCount\":1}]}", true),
            ("{\(base),\"sessions\":[\"claude\",{\"sessionID\":\"c\",\"seenItemCount\":1,\"cost\":3}]}", true),
            ("{\(base),\"items\":{\"not\":\"a list\"}}", true),
            ("{\(base),\"items\":[{\(item),\"context\":[{\"id\":\"\(UUID().uuidString)\",\"kind\":\"file\",\"path\":\"/a\"}]}]}", false),
            // Context of a kind added later is left out, so the file is copied aside before it is saved.
            ("{\(base),\"items\":[{\(item),\"context\":[{\"id\":\"\(UUID().uuidString)\",\"kind\":\"sketch\"}]}]}", true),
        ]
        for (json, unread) in cases {
            #expect(try decode(json).hasUnreadContent == unread, "\(json)")
        }
    }

    @Test func futureFieldsOnKnownContextAreKeptInTheBackup() throws {
        let json = """
            {"id":"\(UUID().uuidString)","projectID":"\(UUID().uuidString)","items":[
              {"id":"\(UUID().uuidString)","kind":"user","context":[
                {"id":"\(UUID().uuidString)","kind":"file","path":"/tmp/a.pdf","checksum":"future"}
              ]}
            ]}
            """
        let file = try decode(json)
        #expect(file.thread.items.first?.context?.first?.filePath == "/tmp/a.pdf")
        #expect(file.hasUnreadContent)
    }

    @Test func aSteeredMessageKeepsItsMarkAndOtherItemsAreWrittenAsBefore() throws {
        let store = AppStore(directory: directory)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let thread = store.createThread(in: project.id)
        store.append(TranscriptItem(kind: .user, text: "fix it"), to: thread.id)
        store.append(TranscriptItem(kind: .user, text: "also the docs", steered: true), to: thread.id)
        store.flush()
        let json = try String(contentsOf: threadsDirectory.appendingPathComponent("\(thread.id.uuidString).json"), encoding: .utf8)
        // Only the steered message carries the field.
        #expect(json.components(separatedBy: #""steered""#).count == 2)
        #expect(try !decode(json).hasUnreadContent)
        let items = try #require(AppStore(directory: directory).thread(thread.id)?.items)
        #expect(items.map(\.isSteered) == [false, true])
        #expect(items.map(\.opensUserTurn) == [true, false])

        // A file from before steering reads as it did; an unreadable mark is noticed, and reads as not steered.
        let base = #""id":"\#(UUID().uuidString)","projectID":"\#(UUID().uuidString)""#
        let user = #""id":"\#(UUID().uuidString)","kind":"user","text":"hi""#
        let old = try decode("{\(base),\"items\":[{\(user)}]}")
        #expect(old.thread.items.first?.steered == nil && !old.hasUnreadContent)
        let odd = try decode("{\(base),\"items\":[{\(user),\"steered\":\"yes\"}]}")
        #expect(odd.thread.items.first?.isSteered == false && odd.hasUnreadContent)
    }

    @Test func unreadableOrFutureModelPreferencesArePreservedBeforeSaving() throws {
        let base = #""id":"\#(UUID().uuidString)","projectID":"\#(UUID().uuidString)""#
        for bank in [
            #"{"future/default":{"effort":"high"}}"#,
            #"{"claude/default":{"effort":7}}"#,
            #"{"claude/default":{"speed":true}}"#,
            #"{"claude/default":{"speed":"fast","futureSetting":true}}"#,
            #"{"claude/default":5}"#,
        ] {
            #expect(try decode("{\(base),\"modelPreferences\":\(bank)}").hasUnreadContent)
        }
        let standard = try decode("{\(base),\"modelPreferences\":{\"claude/default\":{}}}")
        #expect(!standard.hasUnreadContent)
        #expect(standard.thread.modelPreferences?["claude/default"] == ProviderModelPreferences())
    }

    @Test func aThreadThisVersionWroteIsNeverCopied() throws {
        let store = AppStore(directory: directory)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let thread = store.createThread(
            in: project.id, selection: ModelSelection(provider: .codex, modelID: "gpt", effort: "high", speed: "fast"))
        let full = TranscriptItem(
            kind: .approval, text: "body", title: "Run", detail: "ls", category: .command, status: .completed,
            provider: .codex, modelID: "gpt", externalID: "call-1",
            approval: ApprovalInfo(
                requestID: "r", options: [ApprovalOption(id: "a", label: "Allow", kind: .allowOnce)], resolution: "Allow",
                textInput: TextInputSpec(placeholder: "p", initialText: "i", isMultiline: true), responseText: "ok"),
            questions: UserInputRequest(
                id: "q", title: "Pick", questions: [UserQuestion(id: "q1", header: "H", prompt: "P", options: [.init(label: "L", detail: "D")])]),
            answers: ["q1": ["L"]], attachments: ["/tmp/a.png"],
            context: [
                MessageContext(.quote(.init(text: "quoted", provider: .claude))),
                MessageContext(.terminal(.init(terminal: "Terminal 1", directory: "/tmp", lineStart: 1, lineEnd: 1, text: "ok"))),
                MessageContext(
                    .diffComment(.init(path: "a.swift", lineStart: 2, lineEnd: 3, isBeforeChange: false, diff: "+x", comment: "why"))),
                MessageContext(.file(.init(path: "/tmp/spec.pdf"))),
            ], steered: true, schedule: TranscriptItem.ScheduleMark(id: UUID(), name: "Standup"), completedAt: Date())
        store.append(full, to: thread.id)
        // Fields that fall back to a value when unreadable, holding that value.
        store.append(TranscriptItem(kind: .user, text: "", createdAt: .distantPast), to: thread.id)
        let bot = store.addBot(
            Bot(name: "Bot", avatar: BotAvatar(shape: .alien, tint: .sky), persona: "", selection: ModelSelection(provider: .claude, modelID: "m")))
        store.updateThread(thread.id) {
            $0.title = "Everything"
            $0.modelPreferences = ["claude/default": ProviderModelPreferences(effort: "high", speed: "fast"), "codex/work": .init()]
            $0.accessMode = .approval
            $0.interactionMode = .plan
            $0.sessions = [.codex: ProviderSessionRef(sessionID: "x", seenItemCount: 2), .claude: ProviderSessionRef(sessionID: "c", seenItemCount: 0)]
            $0.selection.accountID = "work"
            $0.accountSessions = [
                "claude/work": ProviderSessionRef(sessionID: "w", seenItemCount: 1, accountID: "work", foreignItemsBefore: 2)
            ]
            $0.isPinned = true
            $0.isArchived = true
            $0.worktreePath = "/tmp/worktree"
            $0.branch = "feature"
            $0.draft = "unsent"
            $0.draftContext = full.context
            $0.snoozedUntil = Date()
            $0.importedSession = ImportedSession(provider: .codex, sessionID: "native", sourcePath: "/tmp/session.jsonl")
            $0.titledByUser = true
            $0.titleRefreshes = TitleRefresh.allCases
            $0.titleCheckTurns = 1
            $0.titleCheckedAt = Date()
            $0.botID = bot.id
        }
        store.flush()
        // Every field holds a value, so a field added to the model later must be added here (and to ThreadFile).
        let saved = try #require(store.thread(thread.id))
        #expect(Self.unsetFields(of: saved).isEmpty)
        #expect(Self.unsetFields(of: full).isEmpty)
        #expect(Self.unsetFields(of: saved.selection).isEmpty)
        #expect(Self.fieldNames(of: saved.selection) == ThreadFile.selectionKeys)
        #expect(Self.fieldNames(of: ProviderSessionRef(sessionID: "", seenItemCount: 0)) == ThreadFile.sessionKeys)

        let file = try decode(String(decoding: try Data(contentsOf: threadsDirectory.appendingPathComponent("\(thread.id.uuidString).json")), as: UTF8.self))
        #expect(!file.hasUnreadContent)
        let reloaded = AppStore(directory: directory)
        reloaded.updateThread(thread.id) { $0.draft = "changed" }
        reloaded.flush()
        #expect(try copiesAside().isEmpty)
        #expect(reloaded.thread(thread.id)?.items.count == 2)
    }
}
