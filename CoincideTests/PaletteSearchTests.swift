import AppKit
import Foundation
import Testing

@testable import Coincide

/// Cases ported from T3 Code's `packages/shared/src/paletteSearch.test.ts`, for the parts Coincide's
/// palette has: titles, branches and projects, word starts, typos, words typed together and group ranking.
/// (T3's pull request, environment, message and pick history searches have no counterpart here.)
struct PaletteSearchTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let day: TimeInterval = 24 * 3600

    private struct Subject {
        var title: String
        var branch: String?
        var project: String?
        var updatedAt = PaletteSearchTests.now.addingTimeInterval(-30 * PaletteSearchTests.day)
    }

    private func thread(_ title: String, branch: String? = nil, project: String? = nil, daysAgo: Double = 30) -> Subject {
        Subject(title: title, branch: branch, project: project, updatedAt: Self.now.addingTimeInterval(-daysAgo * Self.day))
    }

    private func score(_ query: String, _ subject: Subject, typos: Bool = false, branchPrefix: String = "") -> PaletteSearch.Match? {
        PaletteSearch.scoreThread(
            PaletteSearch.Query(query), title: subject.title, branch: subject.branch, project: subject.project,
            updatedAt: subject.updatedAt, typos: typos, branchPrefix: branchPrefix, now: Self.now)
    }

    /// Thread titles in the order the palette lists them for `query`.
    private func rankTitles(_ query: String, _ threads: [Subject], branchPrefix: String = "") -> [String] {
        let parsed = PaletteSearch.Query(query)
        let ranked = PaletteSearch.rank([(group: "threads", items: threads)]) { subject, typos in
            PaletteSearch.scoreThread(
                parsed, title: subject.title, branch: subject.branch, project: subject.project, updatedAt: subject.updatedAt,
                typos: typos, branchPrefix: branchPrefix, now: Self.now)
        }
        return ranked.flatMap { $0.items.map(\.item.title) }
    }

    // MARK: Word starts

    @Test func wholeWordsRankOverPrefixesOverNewerMidWordMatches() {
        #expect(
            rankTitles("auth", [
                thread("Fix oauth redirect", daysAgo: 0), thread("Authentication cleanup"), thread("Share auth across worktrees"),
            ]) == ["Share auth across worktrees", "Authentication cleanup", "Fix oauth redirect"])
    }

    @Test func camelCaseKebabPathAndDigitBoundariesStartWords() {
        #expect(score("search", thread("useThreadSearch hook"))?.ranges == [NSRange(location: 9, length: 6)])
        #expect(score("perf", thread("fix/sidebar-perf"))?.ranges == [NSRange(location: 12, length: 4)])
        #expect(score("12", thread("Upgrade to pnpm12"))?.ranges == [NSRange(location: 15, length: 2)])
        #expect(score("sch", thread("Fix JSONSchema parsing"))?.ranges == [NSRange(location: 8, length: 3)])
        #expect(score("ser", thread("Fix HTTPServer crash"))?.ranges == [NSRange(location: 8, length: 3)])
        #expect(score(".ts", thread("Rename index.ts"))?.ranges == [NSRange(location: 12, length: 3)])
        // A match is whole only where a word ends: "githuba" does not fill "GitHubActions".
        #expect((score("githuba", thread("GitHubActions setup"))?.quality ?? 1) < 1)
        #expect(rankTitles(".ts", [thread("Fix parser.tsx"), thread("Rename index.ts")]) == ["Rename index.ts", "Fix parser.tsx"])
        // Short tokens never match inside a word.
        #expect(score("ci", thread("Decision log")) == nil)
    }

    @Test func recentActivityDecidesBetweenEqualMatches() {
        #expect(
            rankTitles("goldbug", [thread("Goldbug epilogue", daysAgo: 20), thread("Goldbug processes", daysAgo: 1)])
                == ["Goldbug processes", "Goldbug epilogue"])
    }

    @Test func insideWordMatchesCountOnlyInTitles() {
        #expect(score("arch", thread("Research notes"))?.quality == 0.3)
        #expect(score("arch", thread("Notes", branch: "research-extension-system")) == nil)
        #expect(PaletteSearch.scoreTerms(PaletteSearch.Query("arch"), name: "Search project contents", keywords: [], typos: false) == nil)
    }

    // MARK: Typos

    @Test func oneTypoIsForgivenOnlyWhenNothingMatchesExactly() {
        let threads = [thread("Hosting alternatives to Railway"), thread("Trim MCP model lists")]
        #expect(rankTitles("railwya", threads) == ["Hosting alternatives to Railway"])
        #expect(rankTitles("trim mpc", threads) == ["Trim MCP model lists"])
        #expect(rankTitles("drga", [thread("Restore drag handles"), thread("Organize indicators")]) == ["Restore drag handles"])
        // Words with digits still forgive one.
        #expect(rankTitles("t3coed", [thread("t3code perf audit"), thread("Other")]) == ["t3code perf audit"])
        #expect(rankTitles("oath2", [thread("Fix oauth2 redirect")]) == ["Fix oauth2 redirect"])
        // A typo beats a mid-word accident: "ilde" is "idle", not the middle of "Builder".
        #expect(
            rankTitles("ilde", [thread("Typesafe App Builder"), thread("De-risk idle tunnel cleanup")])
                == ["De-risk idle tunnel cleanup", "Typesafe App Builder"])
        // "ing" is not "Nightly": a three-letter typo keeps the first letter.
        #expect(rankTitles("ing", [thread("Nightly build fix")]) == [])
        // A short word may miss one letter while it is typed, but not change one.
        #expect(rankTitles("srv", [thread("Server restart"), thread("Other")]) == ["Server restart"])
        #expect(rankTitles("sidb", [thread("Fix sidebar lag")]) == ["Fix sidebar lag"])
        #expect(rankTitles("cron", [thread("Config cleanup")]) == [])
        // Typos count across camelCase joins.
        #expect(rankTitles("githbu", [thread("GitHub API usage"), thread("Other")]) == ["GitHub API usage"])
        #expect(rankTitles("macso", [thread("Fix macOS window"), thread("Other")]) == ["Fix macOS window"])
        // "enter" is not "external" when the right thread is already there.
        #expect(rankTitles("cmd enter", [thread("Fix Cmd+Enter"), thread("Open links external")]) == ["Fix Cmd+Enter"])
    }

    @Test func typosAreForgivenInNamesButNotInHiddenKeywords() {
        let query = PaletteSearch.Query("keybindngs")
        let groups: [(group: String, items: [(name: String, keywords: [String])])] = [
            ("actions", [("Open settings", ["preferences", "keybindings"])]),
            ("settings", [("Keybindings", ["General"])]),
        ]
        let ranked = PaletteSearch.rank(groups) { item, typos in
            PaletteSearch.scoreTerms(query, name: item.name, keywords: item.keywords, typos: typos)
        }
        #expect(ranked.map(\.group) == ["settings"])
        #expect(PaletteSearch.scoreTerms(PaletteSearch.Query("duckdb"), name: "Search engine", keywords: ["duckduckgo"], typos: true) == nil)
        #expect(PaletteSearch.scoreTerms(PaletteSearch.Query("rust"), name: "GitHub sharing", keywords: ["trusted"], typos: false) == nil)
        // Filler words do not make a short query long enough for keyword prefixes.
        #expect(
            PaletteSearch.scoreTerms(PaletteSearch.Query("the ci"), name: "Context window indicator", keywords: ["circle"], typos: false)
                == nil)
    }

    // MARK: Loose input

    @Test func fillerWordsAreOptionalInPhrasesButNotAlone() {
        #expect(rankTitles("fix the sidebar", [thread("Fix Sidebar Lag")]) == ["Fix Sidebar Lag"])
        #expect(rankTitles("the", [thread("Fix sidebar lag")]) == [])
    }

    @Test func quotesApostrophesAccentsAndMarksFold() {
        #expect(rankTitles("don't", [thread("Don’t merge yet")]) == ["Don’t merge yet"])
        #expect(rankTitles("\"sidebar lag\"", [thread("Fix sidebar lag")]) == ["Fix sidebar lag"])
        #expect(rankTitles("cafe\u{0301}", [thread("Café menu")]) == ["Café menu"])
        #expect(rankTitles("CAFE", [thread("Le café")]) == ["Le café"])
        #expect(PaletteSearch.normalize("  \"Fix   the\tbug\"  ") == "fix the bug")
    }

    @Test func queriesThatFoldToNothingFindNothing() {
        // (T3 also strips a leading "#" for its pull request numbers, which Coincide's palette does not search.)
        #expect(rankTitles("#", [thread("Fix sidebar lag")]) == [])
        #expect(rankTitles("´´´", [thread("Fix sidebar lag")]) == [])
        #expect(rankTitles("   ", [thread("Fix sidebar lag")]) == [])
        #expect(PaletteSearch.Query("  ").isEmpty)
    }

    @Test func lettersAndNumbersTypedTogetherMatchWithoutForgivingNumberTypos() {
        let threads = [thread("Upgrade to pnpm 12"), thread("GPT-5 eval"), thread("iOS 26 support"), thread("Other")]
        #expect(rankTitles("pnpm12", threads) == ["Upgrade to pnpm 12"])
        #expect(rankTitles("gpt5", threads) == ["GPT-5 eval"])
        #expect(rankTitles("ios26", threads) == ["iOS 26 support"])
        #expect(rankTitles("pnpm13", threads) == [])
    }

    @Test func wholeWordsTypedTogetherMatchButScatteredLettersDoNot() {
        let threads = [
            thread("VS Code extension settings"), thread("Fix UI bug in sidebar"),
            thread("I plan to open source all of lakebed in the next few weeks"),
        ]
        #expect(rankTitles("vscode", threads) == ["VS Code extension settings"])
        #expect(rankTitles("fixuibug", threads) == ["Fix UI bug in sidebar"])
        #expect(rankTitles("lint", threads) == [])
        // Short words before a mere prefix are a coincidence.
        #expect(rankTitles("inth", [thread("Show skill names in thread overview")]) == [])
        #expect(rankTitles("tos", [thread("Move Client State to Server")]) == [])
        #expect(rankTitles("t3co", [thread("T3 Code vs Gemini")]) == ["T3 Code vs Gemini"])
        // Three letters of the last word are enough, as it is typed.
        #expect(rankTitles("gomod", [thread("Migrate to Go modules")]) == ["Migrate to Go modules"])
        // Joined words beat an earlier match inside a word.
        #expect(score("vscode", thread("Fixvscode and VS Code"))?.quality == 0.6)
    }

    @Test func aWordAndTheStartOfTheNextHighlightEachPart() {
        let threads = [thread("Fix sidebar lag"), thread("Unrelated work")]
        #expect(rankTitles("fixsid", threads) == ["Fix sidebar lag"])
        #expect(rankTitles("fixsid", [thread("Feature: Fix sidebar lag")]) == ["Feature: Fix sidebar lag"])
        #expect(score("fixsid", threads[0])?.ranges == [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)])
        // Initials are not words typed together.
        #expect(rankTitles("fsl", threads) == [])
    }

    @Test func nothingIsFoundRatherThanAnUnrelatedThread() {
        let threads = [
            thread("Projectless threads without Git"), thread("Concern about connection setup"),
            thread("Simplify worktree thread creation"), thread("Start a new conversation"), thread("Setting up the sentinel"),
            thread("I plan to open source all of lakebed in the next few weeks"), thread("Design notes"),
            thread("Link pull request to thread"),
        ]
        for query in ["posthog", "cron", "stripe", "gpu", "fxsb", "lint", "deno"] {
            #expect(rankTitles(query, threads) == [], "\(query)")
        }
    }

    @Test func emojiAndChineseOrJapaneseCharactersMatch() {
        #expect(rankTitles("🚀", [thread("🚀 Launch checklist"), thread("Launch notes")]) == ["🚀 Launch checklist"])
        #expect(score("搜索", thread("实现全文搜索")) != nil)
        #expect(score("検索", thread("新しい検索機能")) != nil)
    }

    // MARK: Branches and projects

    @Test func branchesAndProjectsMatchButCountLessThanTitles() throws {
        let subject = thread("Trim model lists", branch: "trim-mcp-models", project: "t3code")
        for query in ["trim mcp", "models trim", "trim t3code"] {
            #expect(score(query, subject) != nil, "\(query)")
        }
        #expect(score("trim lakebed", subject) == nil)
        let title = try #require(score("lists", subject))
        let branch = try #require(score("mcp", subject))
        let project = try #require(score("t3code", subject))
        #expect(title.quality > branch.quality)
        #expect(branch.quality > project.quality)
        // The project only helps a match; it never makes it strong.
        #expect(!project.strong)
        #expect(title.strong && branch.strong)
        // Only the title is highlighted.
        #expect(branch.ranges.isEmpty)
    }

    @Test func theWorktreeBranchPrefixIsNotPartOfWhatTheBranchSays() throws {
        let subject = thread("Cmd+K search", branch: "coincide/cmdk-search-v2")
        #expect(score("coincide", subject, branchPrefix: "coincide/") == nil)
        #expect(score("coincide", subject) != nil)
        #expect(score("cmdk", subject, branchPrefix: "coincide/") != nil)
        // A branch that is only the prefix keeps it.
        #expect(score("coincide", thread("x", branch: "coincide/"), branchPrefix: "coincide/") != nil)
    }

    @Test func aTitleHoldingTheWordsRanksAboveTheWorktreePrefixAndProjectName() {
        let busy = thread("Diagnose Connect provisioning failures", branch: "t3/diagnose-connect", project: "t3code", daysAgo: 0)
        let named = thread("T3 Connect Tunnel Lifecycle Review", project: "t3code")
        #expect(rankTitles("t3 connect", [busy, named], branchPrefix: "t3/").first == "T3 Connect Tunnel Lifecycle Review")
        let sidebar = thread("Fix sidebar lag", branch: "t3code/sidebar", project: "t3code", daysAgo: 0)
        let gemini = thread("T3 Code vs Gemini Token Volume", project: "slophouse")
        #expect(rankTitles("t3code", [sidebar, gemini], branchPrefix: "t3code/").first == "T3 Code vs Gemini Token Volume")
    }

    // MARK: Groups

    @Test func groupsAreOrderedByTheirBestMatchAndKeepTheirOrderOnTies() {
        let query = PaletteSearch.Query("settings")
        let ranked = PaletteSearch.rank([
            (group: "actions", items: ["Open settings", "New thread"]),
            (group: "threads", items: ["Settings sync rewrite", "Thread settings"]),
            (group: "projects", items: ["Settings app"]),
        ]) { name, typos in PaletteSearch.scoreTerms(query, name: name, keywords: [], typos: typos) }
        #expect(ranked.map(\.group) == ["actions", "threads", "projects"])
        #expect(ranked.map { $0.items.map(\.item) } == [["Open settings"], ["Settings sync rewrite", "Thread settings"], ["Settings app"]])
    }

    @Test func aThreadNamedForTheQueryRanksAboveACommandWithItAsAKeyword() {
        enum Item {
            case command(String, [String])
            case thread(String)
        }
        func groups(_ command: Item, _ thread: Item, query raw: String) -> [String] {
            let query = PaletteSearch.Query(raw)
            return PaletteSearch.rank([(group: "actions", items: [command]), (group: "threads", items: [thread])]) { item, typos in
                switch item {
                case .command(let name, let keywords):
                    PaletteSearch.scoreTerms(query, name: name, keywords: keywords, typos: typos)
                case .thread(let title):
                    PaletteSearch.scoreThread(query, title: title, branch: nil, project: nil, updatedAt: Self.now, typos: typos, now: Self.now)
                }
            }.map(\.group)
        }
        let named = Item.thread("Trim MCP model lists")
        #expect(groups(.command("Restart agent session", ["reload", "mcp"]), named, query: "mcp") == ["threads", "actions"])
        // A command named for the query stays first.
        #expect(groups(.command("Reload MCP servers", []), named, query: "mcp") == ["actions", "threads"])
        // A thread titled exactly like a command never lifts its group above the command's.
        #expect(groups(.command("Settings", []), .thread("Settings"), query: "settings") == ["actions", "threads"])
    }

    @Test func typosAreTriedOnlyWhenNothingMatchesAtAWordStart() {
        var calls: [Bool] = []
        _ = PaletteSearch.rank([(group: "g", items: ["Fix sidebar"])]) { name, typos in
            calls.append(typos)
            return PaletteSearch.scoreTerms(PaletteSearch.Query("sidebar"), name: name, keywords: [], typos: typos)
        }
        #expect(calls == [false])
        calls = []
        let ranked = PaletteSearch.rank([(group: "g", items: ["Fix sidebar"])]) { name, typos in
            calls.append(typos)
            return PaletteSearch.scoreTerms(PaletteSearch.Query("sidbear"), name: name, keywords: [], typos: typos)
        }
        #expect(calls == [false, true])
        #expect(ranked.first?.items.first?.match.strong == false)
    }

    @Test func secondaryItemsNeverDecideWhereTheirGroupSits() throws {
        var item = PaletteItem(id: "x", title: "Settings", behavior: .run({}))
        let query = PaletteSearch.Query("settings")
        #expect(try #require(item.score(query, typos: false)).groupQuality == nil)
        item.isSecondary = true
        #expect(try #require(item.score(query, typos: false)).groupQuality == 0)
    }

    @Test func keywordOnlyMatchesRankBelowNameMatchesAsAGroup() throws {
        let query = PaletteSearch.Query("preferences")
        let match = try #require(PaletteSearch.scoreTerms(query, name: "Open Settings", keywords: ["preferences"], typos: false))
        #expect(match.ranges.isEmpty)
        #expect(try #require(match.groupQuality) <= 0.65)
    }

    // MARK: Scoring helpers

    @Test func matchClassesSeparateWholeNamesWordStartsTyposAndInsideWords() {
        #expect(PaletteSearch.matchClass(1.5) == 3)
        #expect(PaletteSearch.matchClass(1.0) == 2)
        #expect(PaletteSearch.matchClass(0.7) == 2)
        #expect(PaletteSearch.matchClass(0.45) == 1)
        #expect(PaletteSearch.matchClass(0.3) == 0)
    }

    @Test func aWholeNameMatchScoresHighest() throws {
        let exact = try #require(PaletteSearch.scoreTerms(PaletteSearch.Query("open settings"), name: "Open Settings", keywords: [], typos: false))
        #expect(exact.quality == 1.5)
        let contained = try #require(
            PaletteSearch.scoreTerms(PaletteSearch.Query("open settings"), name: "Open Settings Now", keywords: [], typos: false))
        #expect(contained.quality == 1.25)
    }

    @Test func shortQueriesNeedWholeKeywords() {
        #expect(PaletteSearch.Query("co").isShort)
        #expect(PaletteSearch.Query("the ci").isShort)
        #expect(PaletteSearch.Query("a b").isShort)
        #expect(!PaletteSearch.Query("abcd").isShort)
        #expect(!PaletteSearch.Query("ab cd").isShort)
        #expect(PaletteSearch.scoreTerms(PaletteSearch.Query("co"), name: "Show Diff", keywords: ["commit"], typos: false) == nil)
        #expect(PaletteSearch.scoreTerms(PaletteSearch.Query("git"), name: "Show Diff", keywords: ["git"], typos: false) != nil)
    }

    @Test func highlightRangesAreInUTF16AndSkipAccentedLetters() {
        #expect(score("resume", thread("🎉 Résumé ready"))?.ranges == [NSRange(location: 3, length: 6)])
    }
}

/// The palette's folder browsing (T3's add-project path queries) and its fixed lists.
struct PaletteCatalogTests {
    @Test func slashOrTildeStartsAPathQuery() {
        #expect(PaletteCatalog.isPathQuery("/Users"))
        #expect(PaletteCatalog.isPathQuery("~/code"))
        #expect(!PaletteCatalog.isPathQuery("code"))
        #expect(!PaletteCatalog.isPathQuery(""))
    }

    @Test func aFolderPathListsItsMatchingSubfolders() throws {
        let scratch = TemporaryDirectory("palette")
        try scratch.folder("Alpha")
        try scratch.folder("alpine")
        try scratch.folder("beta")
        try scratch.folder(".alcove")
        try scratch.file("alfa.txt")
        let catalog = PaletteCatalog(windowController: nil)

        let prefixed = catalog.folderItems(for: scratch.url.path + "/al")
        #expect(prefixed.map(\.id) == ["folders"])
        #expect(prefixed.first?.items.map(\.title) == ["Alpha", "alpine"])
        let alpha = try #require(prefixed.first?.items.first)
        #expect(alpha.completion == scratch.url.appendingPathComponent("Alpha").path + "/")
        #expect(alpha.id == "folder:" + scratch.url.appendingPathComponent("Alpha").path)

        // Hidden folders only when asked for.
        #expect(catalog.folderItems(for: scratch.url.path + "/.a").first?.items.map(\.title) == [".alcove"])
        #expect(catalog.folderItems(for: scratch.url.path + "/zzz").isEmpty)
    }

    @Test func anExistingFolderIsOfferedAsAProjectFirst() throws {
        let scratch = TemporaryDirectory("palette")
        try scratch.folder("one")
        try scratch.folder("two")
        let catalog = PaletteCatalog(windowController: nil)
        let items = try #require(catalog.folderItems(for: scratch.url.path + "/").first?.items)
        #expect(items.map(\.title) == ["Add “\(scratch.url.lastPathComponent)” as a Project", "one", "two"])
        #expect(items[0].completion == scratch.url.path + "/")
        // Typing a folder's whole name offers it once, as the project to add.
        let exact = try #require(catalog.folderItems(for: scratch.url.appendingPathComponent("one").path).first?.items)
        #expect(exact.map(\.title) == ["Add “one” as a Project"])
    }

    @Test func homeFolderPathsKeepTheirTildeForCompletion() throws {
        let item = try #require(PaletteCatalog(windowController: nil).folderItems(for: "~").first?.items.first)
        #expect(item.completion == "~/")
    }

    @Test func settingsSectionsAreListed() {
        let items = PaletteCatalog(windowController: nil).settings()
        #expect(items.map(\.id) == ["setting:general", "setting:providers", "setting:models", "setting:instructions", "setting:keyboard", "setting:voice", "setting:about"])
        #expect(items.allSatisfy { $0.subtitle == "Settings" })
    }

    @Test func withoutAWindowOnlyGlobalCommandsAreOffered() {
        let (core, more) = PaletteCatalog(windowController: nil).actions()
        #expect(core.map(\.id).contains("action:add-project"))
        #expect(!core.contains { ["action:terminal", "action:diff", "action:find", "action:stop"].contains($0.id) })
        #expect(more.map(\.id).suffix(3) == ["action:appearance", "action:refresh-agents", "action:settings"])
        #expect(!more.contains { $0.id == "action:pin" || $0.id == "action:sidebar" })
    }
}

struct ProjectTextSearchTests {
    @Test func grepAndRipgrepLinesParseIntoMatches() {
        let output = "./Sources/App.swift:12:    let email = defaults.string(forKey: \"login:last\")\nREADME.md:3:Login\nnot a match\n"
        #expect(
            TextSearch.parse(output) == [
                .init(path: "Sources/App.swift", line: 12, text: "let email = defaults.string(forKey: \"login:last\")"),
                .init(path: "README.md", line: 3, text: "Login"),
            ])
    }

    @Test func aSearchFindsTextInTheFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-text-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "one\nthe needle is here\nthree\n".write(to: root.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        try "nothing\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let matches = await TextSearch.run("needle", in: root)
        #expect(matches == [.init(path: "src/a.txt", line: 2, text: "the needle is here")])
    }
}
