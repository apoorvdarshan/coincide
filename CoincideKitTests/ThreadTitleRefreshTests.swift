import Foundation
import Testing

@testable import CoincideKit

/// Naming ends with one look at a thread's title after its first reply. Only with titles kept up to date does the agent
/// look again, every few turns and minutes of a thread in use, up to a cap; never once the user named it. Threads from
/// before looks were counted join in at their next completed turn; imports and forks keep their titles.
@MainActor
struct ThreadTitleRefreshTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-titles-\(UUID().uuidString)")
    private let store: AppStore
    private let projectID: UUID
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var later: Date { now.addingTimeInterval(ThreadTitles.updateInterval) }

    init() {
        store = AppStore(directory: directory)
        store.updateSettings { $0.checkpointsEnabled = false }
        projectID = store.addProject(at: URL(fileURLWithPath: "/tmp")).id
    }

    private func makeThread(userTurns: Int, refreshes: [TitleRefresh]?) -> ChatThread {
        var thread = ChatThread(projectID: projectID, title: "hi", selection: ModelSelection(provider: .claude, modelID: "m"))
        addTurns(userTurns, to: &thread)
        thread.titleRefreshes = refreshes
        return thread
    }

    private func addTurns(_ count: Int, to thread: inout ChatThread) {
        let start = thread.items.count(where: \.opensUserTurn)
        for turn in start..<(start + count) {
            thread.items.append(TranscriptItem(kind: .user, text: "message \(turn)"))
            thread.items.append(TranscriptItem(kind: .assistant, text: "reply \(turn)"))
        }
    }

    private func addTurns(_ range: Range<Int>, to id: UUID) {
        for turn in range {
            store.append(TranscriptItem(kind: .user, text: "message \(turn)"), to: id)
            store.append(TranscriptItem(kind: .assistant, text: "reply \(turn)"), to: id)
        }
    }

    /// A thread with `turns` turns whose last look came after turn `checked` at `at`.
    private func lookedAt(turns: Int, checked: Int, at: Date, refreshes: [TitleRefresh] = [.firstReply]) -> ChatThread {
        var thread = makeThread(userTurns: turns, refreshes: refreshes)
        thread.titleCheckTurns = checked
        thread.titleCheckedAt = at
        return thread
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private static func decoder(checkingFields: Bool = true) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if checkingFields { decoder.userInfo[.checksUnreadContent] = true }
        return decoder
    }

    // MARK: Who named the thread

    @Test func renamingMarksTheTitleTheUsersAndSurvivesARelaunch() throws {
        let id = store.createThread(in: projectID).id
        #expect(store.summary(id)?.isTitleCustom == false)
        store.renameThread(id, to: "Login screen")
        #expect(store.thread(id)?.title == "Login screen")
        #expect(store.thread(id)?.isTitleCustom == true)
        #expect(store.summary(id)?.isTitleCustom == true)
        store.flush()
        let reloaded = AppStore(directory: directory)
        #expect(reloaded.summary(id)?.isTitleCustom == true)
        #expect(reloaded.thread(id)?.isTitleCustom == true)
    }

    @Test func theAgentsTitleIsNotTheUsers() throws {
        let id = store.createThread(in: projectID).id
        store.updateThread(id) { $0.title = "hi" }
        #expect(ThreadTitles.apply(#"{"title": "Login screen email"}"#, to: id, replacing: "hi", store: store))
        let thread = try #require(store.thread(id))
        #expect(thread.title == "Login screen email")
        #expect(thread.titledByUser == nil && !thread.isTitleCustom)
        #expect(store.summary(id)?.isTitleCustom == false)
    }

    // MARK: Naming only, by default

    @Test func byDefaultTheOnlyLookIsNamingsAfterTheFirstReply() {
        #expect(!AppSettings().updatesThreadTitles)
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 1, refreshes: [])) == .firstReply)
        // However long and however long ago, nothing more once naming is done.
        for turns in [1, 2, 5, 6, 12, 60] {
            #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: turns, refreshes: [.firstReply])) == nil)
            #expect(ThreadTitles.dueRefresh(for: lookedAt(turns: turns, checked: 1, at: .distantPast)) == nil)
        }
        // A thread whose first turns failed gets naming's look at its first completed one.
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 3, refreshes: [])) == .firstReply)
        // One past its first few turns is no longer being named.
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: ThreadTitles.namingTurns, refreshes: [])) == nil)
        // A thread an older version looked at after its fifth turn has had its looks.
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 9, refreshes: [.firstReply, .fifthTurn])) == nil)
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 3, refreshes: [.fifthTurn])) == nil)
    }

    @Test func threadsFromBeforeLooksWereCountedAreNamedOnlyWhileYoung() {
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 1, refreshes: nil)) == .firstReply)
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 3, refreshes: nil)) == .firstReply)
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 5, refreshes: nil)) == nil)
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 40, refreshes: nil)) == nil)
        // With titles kept up to date, an old thread gets one look at its next completed turn.
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 40, refreshes: nil), updates: true, now: now) == .update)
        var named = makeThread(userTurns: 8, refreshes: nil)
        named.titledByUser = true
        #expect(ThreadTitles.dueRefresh(for: named, updates: true, now: now) == nil)
        var archived = makeThread(userTurns: 8, refreshes: nil)
        archived.isArchived = true
        #expect(ThreadTitles.dueRefresh(for: archived, updates: true, now: now) == nil)
    }

    @Test func importsAndForksAreNotNamedAgainButKeepUpWithTheThread() {
        var imported = makeThread(userTurns: 1, refreshes: nil)
        imported.importedSession = ImportedSession(provider: .claude, sessionID: "s", sourcePath: "/tmp/s.jsonl")
        #expect(ThreadTitles.dueRefresh(for: imported) == nil)
        #expect(ThreadTitles.dueRefresh(for: imported, updates: true, now: now) == nil)
        addTurns(10, to: &imported)
        #expect(ThreadTitles.dueRefresh(for: imported) == nil)
        #expect(ThreadTitles.dueRefresh(for: imported, updates: true, now: now) == .update)
        // A young fork isn't named again; one with turns enough gets the looks other threads do.
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 1, refreshes: nil), isFork: true, updates: true, now: now) == nil)
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 12, refreshes: nil), isFork: true, updates: false, now: now) == nil)
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 12, refreshes: nil), isFork: true, updates: true, now: now) == .update)
        // After its first look, a young fork still isn't named.
        let looked = lookedAt(turns: 3, checked: 2, at: .distantPast, refreshes: [.update])
        #expect(ThreadTitles.dueRefresh(for: looked, isFork: true, updates: true, now: now) == nil)
        #expect(ThreadTitles.dueRefresh(for: looked, isFork: false, updates: true, now: now) == nil)
    }

    @Test func aThreadTheUserNamedOrArchivedIsLeftAlone() {
        var named = lookedAt(turns: 12, checked: 1, at: .distantPast, refreshes: [])
        named.titledByUser = true
        #expect(ThreadTitles.dueRefresh(for: named, updates: true, now: now) == nil)
        named.titleRefreshes = nil
        #expect(ThreadTitles.dueRefresh(for: named, updates: true, now: now) == nil)
        var archived = lookedAt(turns: 12, checked: 1, at: .distantPast, refreshes: [])
        archived.isArchived = true
        #expect(ThreadTitles.dueRefresh(for: archived, updates: true, now: now) == nil)
    }

    // MARK: Keeping titles up to date

    @Test func keptUpToDateTheAgentLooksEveryFewTurnsAndMinutes() {
        let every = ThreadTitles.updateTurns
        // Naming still comes first.
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 1, refreshes: []), updates: true, now: now) == .firstReply)
        // Too few turns since the last look, however long ago it was.
        for turns in 1..<(1 + every) {
            #expect(ThreadTitles.dueRefresh(for: lookedAt(turns: turns, checked: 1, at: .distantPast), updates: true, now: now) == nil)
        }
        // Enough turns, but too soon.
        let recent = now.addingTimeInterval(-ThreadTitles.updateInterval + 1)
        #expect(ThreadTitles.dueRefresh(for: lookedAt(turns: 1 + every, checked: 1, at: recent), updates: true, now: now) == nil)
        // Enough of both.
        let longAgo = now.addingTimeInterval(-ThreadTitles.updateInterval)
        #expect(ThreadTitles.dueRefresh(for: lookedAt(turns: 1 + every, checked: 1, at: longAgo), updates: true, now: now) == .update)
        #expect(ThreadTitles.dueRefresh(for: lookedAt(turns: 30, checked: 1, at: longAgo), updates: true, now: now) == .update)
        // Counted from the last look, not from the start.
        #expect(ThreadTitles.dueRefresh(for: lookedAt(turns: 9, checked: 6, at: longAgo, refreshes: [.firstReply, .update]), updates: true, now: now) == nil)
        #expect(ThreadTitles.dueRefresh(for: lookedAt(turns: 11, checked: 6, at: longAgo, refreshes: [.firstReply, .update]), updates: true, now: now) == .update)
        // A thread whose looks were not recorded counts from naming's look, or an older version's fifth-turn one.
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 5, refreshes: [.firstReply]), updates: true, now: now) == nil)
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 6, refreshes: [.firstReply]), updates: true, now: now) == .update)
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 9, refreshes: [.firstReply, .fifthTurn]), updates: true, now: now) == nil)
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 10, refreshes: [.firstReply, .fifthTurn]), updates: true, now: now) == .update)
    }

    @Test func keptUpToDateALongThreadKeepsGettingLooks() {
        // However many looks it had, a thread in use is looked at again once enough turns and time have passed.
        let done = [TitleRefresh.firstReply] + Array(repeating: .update, count: 60)
        #expect(ThreadTitles.dueRefresh(for: lookedAt(turns: 600, checked: 590, at: .distantPast, refreshes: done), updates: true, now: now) == .update)
        #expect(ThreadTitles.dueRefresh(for: lookedAt(turns: 600, checked: 598, at: .distantPast, refreshes: done), updates: true, now: now) == nil)
        #expect(ThreadTitles.dueRefresh(for: lookedAt(turns: 600, checked: 590, at: now, refreshes: done), updates: true, now: now) == nil)
    }

    @Test func messagesSteeredIntoATurnDoNotCountAsTurns() {
        var steered = lookedAt(turns: 5, checked: 1, at: .distantPast)
        steered.items.append(TranscriptItem(kind: .user, text: "also this", steered: true))
        #expect(ThreadTitles.dueRefresh(for: steered, updates: true, now: now) == nil)
    }

    @Test func aLookIsCountedWhenAskedAndOnlyWhenTitlingIsOn() throws {
        let registry = ProviderRegistry(store: store, providers: [ScriptedProvider(kind: .claude)])
        let id = store.createThread(in: projectID, selection: ModelSelection(provider: .claude, modelID: "m")).id
        store.append(TranscriptItem(kind: .user, text: "hi"), to: id)
        store.append(TranscriptItem(kind: .assistant, text: "Hello"), to: id)
        store.updateThread(id) { $0.titleRefreshes = [] }

        store.updateSettings { $0.generatesThreadTitles = false }
        #expect(ThreadTitles.refreshIfDue(threadID: id, store: store, registry: registry, now: now) == nil)
        #expect(store.thread(id)?.titleRefreshes == [])

        store.updateSettings { $0.generatesThreadTitles = true }
        #expect(ThreadTitles.refreshIfDue(threadID: id, store: store, registry: registry, now: now) == .firstReply)
        let thread = try #require(store.thread(id))
        #expect(thread.titleRefreshes == [.firstReply])
        #expect(thread.titleCheckTurns == 1 && thread.titleCheckedAt == now)
        store.flush()
        let reloaded = try #require(AppStore(directory: directory).thread(id))
        #expect(reloaded.titleRefreshes == [.firstReply] && reloaded.titleCheckTurns == 1)
        #expect(reloaded.titleCheckedAt.map { abs($0.timeIntervalSince(now)) < 1 } == true)
    }

    @Test func loadingABusyThreadLooksAtNothingUntilATurnCompletes() async throws {
        store.updateSettings { $0.updatesThreadTitles = true }
        let registry = ProviderRegistry(store: store, providers: [ScriptedProvider(kind: .claude)])
        let id = store.createThread(in: projectID, selection: ModelSelection(provider: .claude, modelID: "m")).id
        addTurns(0..<12, to: id)
        store.updateThread(id) {
            $0.titleRefreshes = [.firstReply]
            $0.titleCheckTurns = 1
            $0.titleCheckedAt = .distantPast
        }
        store.flush()
        // A relaunch loads the thread and asks nothing: only the runner asks, when a turn completes.
        let reloaded = AppStore(directory: directory)
        try await Task.sleep(for: .milliseconds(100))
        #expect(reloaded.thread(id)?.titleRefreshes == [.firstReply])
        #expect(!ThreadTitles.isRefreshing(id))
        #expect(ThreadTitles.refreshIfDue(threadID: id, store: store, registry: registry, now: now) == .update)
    }

    @Test func aThreadNeverHasTwoLooksAtOnce() async throws {
        store.updateSettings { $0.updatesThreadTitles = true }
        let registry = ProviderRegistry(store: store, providers: [ScriptedProvider(kind: .claude)])
        let id = store.createThread(in: projectID, selection: ModelSelection(provider: .claude, modelID: "m")).id
        addTurns(0..<1, to: id)
        store.updateThread(id) { $0.titleRefreshes = [] }
        #expect(ThreadTitles.refreshIfDue(threadID: id, store: store, registry: registry, now: now) == .firstReply)
        #expect(ThreadTitles.isRefreshing(id))
        // Due again before the first look finished: it waits.
        addTurns(1..<12, to: id)
        #expect(ThreadTitles.refreshIfDue(threadID: id, store: store, registry: registry, now: later) == nil)
        #expect(store.thread(id)?.titleRefreshes == [.firstReply])
        #expect(await eventually { !ThreadTitles.isRefreshing(id) })
        #expect(ThreadTitles.refreshIfDue(threadID: id, store: store, registry: registry, now: later) == .update)
        #expect(store.thread(id)?.titleRefreshes == [.firstReply, .update])
        #expect(store.thread(id)?.titleCheckTurns == 12)
    }

    @Test func turningUpdatesOffDropsALookNotYetAskedOrAnswered() async throws {
        let claude = ScriptedProvider(kind: .claude)
        let recorder = PromptRecorder()
        let gate = Gate()
        claude.configure = { session in
            session.onSend = { session, input in
                recorder.prompts.append(input.message)
                await gate.wait()
                session.emit(.assistantText(itemID: UUID().uuidString, text: #"{"title": "Something else"}"#))
                session.emit(.turnCompleted(.completed))
            }
        }
        let registry = ProviderRegistry(store: store, providers: [claude])
        await registry.refresh()
        store.updateSettings { $0.updatesThreadTitles = true }
        let id = store.createThread(in: projectID, selection: ModelSelection(provider: .claude, modelID: "m")).id
        addTurns(0..<8, to: id)
        store.updateThread(id) {
            $0.title = "Original"
            $0.titleRefreshes = [.firstReply]
            $0.titleCheckTurns = 1
            $0.titleCheckedAt = .distantPast
        }

        // Turned off before the look started: the agent is never asked.
        #expect(ThreadTitles.refreshIfDue(threadID: id, store: store, registry: registry, now: now) == .update)
        store.updateSettings { $0.updatesThreadTitles = false }
        #expect(await eventually { !ThreadTitles.isRefreshing(id) })
        #expect(recorder.prompts.isEmpty)
        #expect(store.summary(id)?.title == "Original")

        // Turned off while the agent thinks: its answer is dropped.
        store.updateSettings { $0.updatesThreadTitles = true }
        addTurns(8..<14, to: id)
        #expect(ThreadTitles.refreshIfDue(threadID: id, store: store, registry: registry, now: later) == .update)
        #expect(await eventually { recorder.prompts.count == 1 })
        store.updateSettings { $0.updatesThreadTitles = false }
        gate.open()
        #expect(await eventually { !ThreadTitles.isRefreshing(id) })
        #expect(store.summary(id)?.title == "Original")
        // Naming's own look is not affected by the option.
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 1, refreshes: [])) == .firstReply)
    }

    // MARK: Applying an answer

    @Test func anAnswerToAnOutdatedTitleOrARenamedThreadIsIgnored() throws {
        let id = store.createThread(in: projectID).id
        store.updateThread(id) { $0.title = "Login screen" }
        // The title changed while the agent thought.
        #expect(!ThreadTitles.apply(#"{"title": "Remember the email"}"#, to: id, replacing: "hi", store: store))
        #expect(store.summary(id)?.title == "Login screen")
        // Unusable answers change nothing.
        #expect(!ThreadTitles.apply(nil, to: id, replacing: "Login screen", store: store))
        #expect(!ThreadTitles.apply("no json here", to: id, replacing: "Login screen", store: store))
        // The user named it, even with the same text.
        store.renameThread(id, to: "Login screen")
        #expect(!ThreadTitles.apply(#"{"title": "Remember the email"}"#, to: id, replacing: "Login screen", store: store))
        #expect(store.summary(id)?.title == "Login screen")
    }

    // MARK: What a refresh sends

    @Test func aRefreshSendsOnlyTrimmedPartsOfTheThread() throws {
        let long = String(repeating: "word ", count: 400)
        var thread = makeThread(userTurns: 0, refreshes: [])
        thread.items = [
            TranscriptItem(kind: .user, text: "First " + long),
            TranscriptItem(kind: .assistant, text: "Old reply " + long),
            TranscriptItem(kind: .user, text: "Latest\n\n" + long),
            TranscriptItem(kind: .tool, text: "tool output " + long),
            TranscriptItem(kind: .assistant, text: "New   reply\nstarts " + long),
            TranscriptItem(kind: .assistant, text: "and goes on"),
        ]
        let parts = try #require(ThreadTitles.RefreshParts(thread))
        #expect(parts.firstMessage.count == ThreadTitles.refreshMessageLimit && parts.firstMessage.hasPrefix("First word"))
        let latest = try #require(parts.latestMessage)
        #expect(latest.count == ThreadTitles.refreshMessageLimit && latest.hasPrefix("Latest word"))
        #expect(parts.latestReply.count == ThreadTitles.refreshReplyLimit && parts.latestReply.hasPrefix("New reply starts"))
        #expect(!parts.latestReply.contains("Old") && !parts.latestReply.contains("tool"))

        let title = String(repeating: "t", count: 500)
        let prompt = ThreadTitles.refreshPrompt(title: title, parts: parts)
        #expect(prompt.contains("<title>\n\(String(repeating: "t", count: ThreadTitles.refreshTitleLimit - 1))…\n</title>"))
        #expect(prompt.contains("answer with it unchanged") && prompt.contains("what the thread is about now"))
        #expect(prompt.contains("\"title\"") && prompt.contains("fewer than 40 characters"))
        #expect(prompt.contains("<message>\n\(parts.firstMessage)\n</message>"))
        #expect(prompt.contains("<message>\n\(latest)\n</message>"))
        #expect(prompt.contains("<reply>\n\(parts.latestReply)\n</reply>"))
        // Short of the brief itself, the whole request stays small.
        #expect(prompt.count < ThreadTitles.prompt(message: "").count + 1_800)

        // After the first turn, the first message is the latest one and is sent once.
        let first = try #require(ThreadTitles.RefreshParts(makeThread(userTurns: 1, refreshes: [])))
        #expect(first == ThreadTitles.RefreshParts(firstMessage: "message 0", latestMessage: nil, latestReply: "reply 0"))
        let onePrompt = ThreadTitles.refreshPrompt(title: "hi", parts: first)
        #expect(onePrompt.components(separatedBy: "<message>").count == 2)
        #expect(!onePrompt.contains("latest message"))
        // A thread with no message to go by is not looked at.
        #expect(ThreadTitles.RefreshParts(makeThread(userTurns: 0, refreshes: [])) == nil)
    }

    // MARK: Files

    @Test func newFieldsRoundTripAndOldFilesReadAsNotCustom() throws {
        let id = store.createThread(in: projectID).id
        store.renameThread(id, to: "Mine")
        store.updateThread(id) {
            $0.titleRefreshes = [.firstReply, .fifthTurn, .update]
            $0.titleCheckTurns = 7
            $0.titleCheckedAt = now
        }
        store.flush()
        let file = directory.appendingPathComponent("threads/\(id.uuidString).json")
        let data = try Data(contentsOf: file)
        let read = try Self.decoder().decode(ThreadFile.self, from: data)
        #expect(!read.hasUnreadContent)
        #expect(read.thread.isTitleCustom && read.thread.titleRefreshes == [.firstReply, .fifthTurn, .update])
        #expect(read.thread.titleCheckTurns == 7 && read.thread.titleCheckedAt == now)
        #expect(try Self.decoder().decode(ThreadSummaryFile.self, from: data).summary.isTitleCustom)

        // A thread never renamed nor looked at again is written as before.
        let plain = store.createThread(in: projectID).id
        store.flush()
        let plainJSON = try String(contentsOf: directory.appendingPathComponent("threads/\(plain.uuidString).json"), encoding: .utf8)
        #expect(!plainJSON.contains("titledByUser") && !plainJSON.contains("titleRefreshes"))
        #expect(!plainJSON.contains("titleCheckTurns") && !plainJSON.contains("titleCheckedAt"))

        let base = #""id":"\#(UUID().uuidString)","projectID":"\#(UUID().uuidString)","title":"Old""#
        let old = try Self.decoder().decode(ThreadFile.self, from: Data("{\(base)}".utf8))
        #expect(!old.thread.isTitleCustom && old.thread.titledByUser == nil && old.thread.titleRefreshes == nil)
        #expect(old.thread.titleCheckTurns == nil && old.thread.titleCheckedAt == nil)
        #expect(!old.hasUnreadContent)

        let cases: [(json: String, custom: Bool, refreshes: [TitleRefresh]?, turns: Int?, unread: Bool)] = [
            ("{\(base),\"titledByUser\":true}", true, nil, nil, false),
            ("{\(base),\"titledByUser\":false,\"titleRefreshes\":[]}", false, [], nil, false),
            ("{\(base),\"titledByUser\":null,\"titleRefreshes\":null}", false, nil, nil, false),
            ("{\(base),\"titleRefreshes\":[\"firstReply\",\"update\"],\"titleCheckTurns\":6}", false, [.firstReply, .update], 6, false),
            // What this version cannot read is left out, and the file is copied aside before it is saved.
            ("{\(base),\"titledByUser\":\"yes\"}", false, nil, nil, true),
            ("{\(base),\"titleRefreshes\":[\"firstReply\",\"tenthTurn\"]}", false, [.firstReply], nil, true),
            ("{\(base),\"titleCheckTurns\":\"six\"}", false, nil, nil, true),
            ("{\(base),\"titleCheckedAt\":12}", false, nil, nil, true),
        ]
        for entry in cases {
            let data = Data(entry.json.utf8)
            let file = try Self.decoder().decode(ThreadFile.self, from: data)
            #expect(file.thread.isTitleCustom == entry.custom, "\(entry.json)")
            #expect(file.thread.titleRefreshes == entry.refreshes, "\(entry.json)")
            #expect(file.thread.titleCheckTurns == entry.turns, "\(entry.json)")
            #expect(file.hasUnreadContent == entry.unread, "\(entry.json)")
            // Reading only the summary agrees with reading the thread.
            let summary = try Self.decoder(checkingFields: false).decode(ThreadSummaryFile.self, from: data).summary
            #expect(summary == ThreadSummary(file.thread), "\(entry.json)")
        }
    }

    // MARK: Settings

    @Test func keepingTitlesUpToDateStartsOffAndReadsLeniently() throws {
        #expect(AppSettings().generatesThreadTitles && !AppSettings().updatesThreadTitles)
        func decode(_ json: String) throws -> AppSettings { try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)) }
        // Settings saved before the option existed leave it off, even with naming on.
        let old = try decode(#"{"generatesThreadTitles": true, "fontSize": 15}"#)
        #expect(old.generatesThreadTitles && !old.updatesThreadTitles && old.fontSize == 15)
        for value in ["null", "3", #""yes""#, "[]"] {
            let settings = try decode(#"{"updatesThreadTitles": \#(value), "sendOnReturn": false}"#)
            #expect(!settings.updatesThreadTitles && !settings.sendOnReturn, "\(value)")
        }
        var on = AppSettings()
        on.updatesThreadTitles = true
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(on)).updatesThreadTitles)
    }

    // MARK: Through the runner

    @Test func theRunnerNamesAThreadAfterItsFirstReplyAndThenLeavesItByDefault() async throws {
        let (runner, recorder) = await makeRunner()
        let id = store.createThread(in: projectID, selection: ModelSelection(provider: .claude, modelID: "m")).id

        await runner.send(threadID: id, text: "hi")
        #expect(await eventually { store.summary(id)?.title == "Fix the login bug" })
        #expect(recorder.prompts.count == 1)
        // The look waited for the first title and looked at it.
        #expect(recorder.prompts.first?.contains("<title>\nGreeting\n</title>") == true)
        #expect(store.thread(id)?.titleRefreshes == [.firstReply])

        // A busy thread, its last look long ago: still nothing more by default.
        store.updateThread(id) { $0.titleCheckedAt = .distantPast }
        for turn in 2...12 {
            await runner.send(threadID: id, text: "message \(turn)")
            #expect(await eventually { !runner.isRunning(id) })
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.prompts.count == 1)
        #expect(store.thread(id)?.titleRefreshes == [.firstReply])

        // A thread the user named before its first message keeps the name, and the agent never titles it.
        let named = store.createThread(in: projectID, selection: ModelSelection(provider: .claude, modelID: "m")).id
        store.renameThread(named, to: "My name")
        await runner.send(threadID: named, text: "hi")
        #expect(await eventually { !runner.isRunning(named) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.summary(named)?.title == "My name")
        #expect(recorder.prompts.count == 1)
        #expect(store.thread(named)?.titleRefreshes == nil)
    }

    @Test func keptUpToDateTheRunnerLooksAgainOnlyAfterEnoughTurnsAndTime() async throws {
        store.updateSettings { $0.updatesThreadTitles = true }
        let (runner, recorder) = await makeRunner()
        let id = store.createThread(in: projectID, selection: ModelSelection(provider: .claude, modelID: "m")).id

        await runner.send(threadID: id, text: "hi")
        #expect(await eventually { store.summary(id)?.title == "Fix the login bug" })
        #expect(await eventually { !ThreadTitles.isRefreshing(id) })
        #expect(recorder.prompts.count == 1)

        // Five more turns, all within minutes of naming: no look yet.
        for turn in 2...(1 + ThreadTitles.updateTurns) {
            await runner.send(threadID: id, text: "message \(turn)")
            #expect(await eventually { !runner.isRunning(id) })
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.prompts.count == 1)

        // Once the last look is long enough ago, the next completed turn brings one.
        store.updateThread(id) { $0.titleCheckedAt = Date().addingTimeInterval(-ThreadTitles.updateInterval) }
        await runner.send(threadID: id, text: "now ship it")
        #expect(await eventually { store.summary(id)?.title == "Ship the login fix" })
        #expect(recorder.prompts.count == 2 && recorder.prompts.last?.contains("now ship it") == true)
        #expect(store.thread(id)?.titleRefreshes == [.firstReply, .update])
        #expect(store.thread(id)?.titleCheckTurns == 2 + ThreadTitles.updateTurns)

        // The very next turn is too soon after it.
        await runner.send(threadID: id, text: "one more")
        #expect(await eventually { !runner.isRunning(id) })
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.prompts.count == 2)
    }

    /// A runner whose agent names threads "Greeting", answers looks with two titles in turn, and replies to the rest.
    private func makeRunner() async -> (ThreadRunner, PromptRecorder) {
        let claude = ScriptedProvider(kind: .claude)
        let recorder = PromptRecorder()
        claude.configure = { session in
            session.onSend = { session, input in
                let reply: String
                if input.message.contains("Check the title of a coding thread") {
                    recorder.prompts.append(input.message)
                    reply = recorder.prompts.count == 1 ? #"{"title": "Fix the login bug"}"# : #"{"title": "Ship the login fix"}"#
                } else if input.message.contains("Generate a title") {
                    reply = #"{"title": "Greeting"}"#
                } else {
                    reply = "Let's fix the login bug."
                }
                session.emit(.assistantText(itemID: UUID().uuidString, text: reply))
                session.emit(.turnCompleted(.completed))
            }
        }
        let registry = ProviderRegistry(store: store, providers: [claude])
        await registry.refresh()
        return (ThreadRunner(store: store, registry: registry), recorder)
    }
}

/// The title prompts a scripted agent was sent.
@MainActor
private final class PromptRecorder {
    var prompts: [String] = []
}

private extension ThreadTitles {
    /// A thread that is not a fork, with titles named only.
    static func dueRefresh(for thread: ChatThread) -> TitleRefresh? {
        dueRefresh(for: thread, isFork: false, updates: false, now: Date())
    }

    static func dueRefresh(for thread: ChatThread, updates: Bool, now: Date) -> TitleRefresh? {
        dueRefresh(for: thread, isFork: false, updates: updates, now: now)
    }
}
