import AppKit
import CoincideKit
import Foundation
import Testing

@testable import Coincide

/// `@` file mentions and `/` commands as the composer detects them, with cases from T3 Code's
/// `composerTrigger.test.ts` that apply to Coincide's commands.
struct ComposerTriggerTests {
    private func detect(_ text: String, cursor: Int? = nil) -> ComposerTrigger? {
        ComposerTrigger.detect(in: text, cursor: cursor ?? (text as NSString).length)
    }

    @Test(arguments: [
        ("Run /tmp/build.sh", "Run /tmp/build.sh".count),
        ("/etc/hosts", "/etc/hosts".count),
        ("Use /etc/hosts now", "Use /et".count),
    ])
    func aPathIsNotACommand(text: String, cursor: Int) {
        #expect(detect(text, cursor: cursor) == nil)
    }

    @Test func aSlashWordIsACommand() {
        #expect(detect("Use /") == ComposerTrigger(kind: .command, query: "", range: NSRange(location: 4, length: 1)))
        #expect(detect("Use /review") == ComposerTrigger(kind: .command, query: "review", range: NSRange(location: 4, length: 7)))
        #expect(detect("/plan") == ComposerTrigger(kind: .command, query: "plan", range: NSRange(location: 0, length: 5)))
        #expect(detect("first line\n/co") == ComposerTrigger(kind: .command, query: "co", range: NSRange(location: 11, length: 3)))
    }

    @Test(arguments: ["Use/review", "https://example.com/review", "Use /review ", "", "plain"])
    func otherWordsAreNoTrigger(text: String) {
        #expect(detect(text) == nil)
    }

    @Test func aDollarWordAsksForSkillsButAnAmountDoesNot() {
        #expect(detect("$") == ComposerTrigger(kind: .skill, query: "", range: NSRange(location: 0, length: 1)))
        #expect(detect("use $rev") == ComposerTrigger(kind: .skill, query: "rev", range: NSRange(location: 4, length: 4)))
        #expect(detect("costs $20") == nil)
    }

    @Test func anAtWordMentionsAFile() {
        #expect(detect("@") == ComposerTrigger(kind: .path, query: "", range: NSRange(location: 0, length: 1)))
        #expect(detect("see @src/ma") == ComposerTrigger(kind: .path, query: "src/ma", range: NSRange(location: 4, length: 7)))
        // Unlike a command, a mention may hold slashes.
        #expect(detect("@/usr/bin")?.kind == .path)
        // Only the word up to the caret counts.
        #expect(detect("a @foo bar", cursor: 6) == ComposerTrigger(kind: .path, query: "foo", range: NSRange(location: 2, length: 4)))
        #expect(detect("@abcdef", cursor: 3) == ComposerTrigger(kind: .path, query: "ab", range: NSRange(location: 0, length: 3)))
        #expect(detect("email me@x.com") == nil)
    }

    @Test func rangesAreUTF16AndTheCaretIsClamped() {
        #expect(detect("🎉 @fi") == ComposerTrigger(kind: .path, query: "fi", range: NSRange(location: 3, length: 3)))
        #expect(detect("x @y", cursor: 100) == ComposerTrigger(kind: .path, query: "y", range: NSRange(location: 2, length: 2)))
        #expect(detect("@y", cursor: -4) == nil)
        // Any whitespace, a tab or a non-breaking space too, ends a word.
        #expect(detect("a\t@b")?.range == NSRange(location: 2, length: 2))
        #expect(detect("a\u{00A0}/b")?.range == NSRange(location: 2, length: 2))
    }

    @Test func mentionsQuotePathsWithSpaces() {
        #expect(ComposerTrigger.mention("src/App.swift") == "@src/App.swift")
        #expect(ComposerTrigger.mention("docs/My File.md") == "@\"docs/My File.md\"")
        #expect(ComposerTrigger.mention("@scope/package.json") == "@@scope/package.json")
    }

    /// Amounts stay plain text; `$` words ask for skills (`aDollarWordAsksForSkillsButAnAmountDoesNot`).
    @Test(arguments: ["costs $1,200.50", "$5"])
    func anAmountIsPlainText(text: String) {
        #expect(detect(text) == nil)
    }
}

struct ComposerCommandTests {
    private let commands = ComposerCommand.available(agents: [.codex, .cursor, .opencode])

    @Test func builtInCommandsComeBeforeOnePerAgent() {
        #expect(commands == [.model, .plan, .build, .agent(.codex), .agent(.cursor), .agent(.opencode)])
        #expect(commands.map(\.title) == ["/model", "/plan", "/build", "/codex", "/cursor", "/opencode"])
        #expect(ComposerCommand.agent(.codex).summary == "Continue this thread with Codex")
        #expect(ComposerCommand.agent(.cursor).symbolName == ProviderKind.cursor.symbolName)
    }

    @Test func matchingRanksExactThenPrefixThenContainedThenSummary() {
        #expect(ComposerCommand.matching("", in: commands) == commands)
        #expect(ComposerCommand.matching("PLAN", in: commands) == [.plan])
        #expect(ComposerCommand.matching("cod", in: commands) == [.agent(.codex), .agent(.opencode)])
        #expect(ComposerCommand.matching("mode", in: commands) == [.model, .plan, .build])
        #expect(ComposerCommand.matching("pencode", in: commands) == [.agent(.opencode)])
        #expect(ComposerCommand.matching("thread back", in: commands) == [.build])
        #expect(ComposerCommand.matching("zzz", in: commands) == [])
    }

    @Test func defaultIsT3CodesNameForBuildMode() {
        #expect(ComposerCommand.matching("default", in: commands) == [.build])
        #expect(ComposerCommand.standalone("/default", in: commands) == .build)
    }

    @Test func aMessageThatIsOnlyACommandRunsIt() {
        #expect(ComposerCommand.standalone("/plan", in: commands) == .plan)
        #expect(ComposerCommand.standalone("  /PLAN \n", in: commands) == .plan)
        #expect(ComposerCommand.standalone("/codex", in: commands) == .agent(.codex))
        #expect(ComposerCommand.standalone("/plan the work", in: commands) == nil)
        #expect(ComposerCommand.standalone("plan", in: commands) == nil)
        // Only agents the user can switch to.
        #expect(ComposerCommand.standalone("/claude", in: commands) == nil)
        #expect(ComposerCommand.standalone("/", in: commands) == nil)
    }
}

/// Files listed for `@` mentions and how they rank.
struct ComposerFileIndexTests {
    private func makeProject() throws -> TemporaryDirectory {
        let project = TemporaryDirectory("files")
        for path in [
            "README.md", "src/main.swift", "src/util/Helpers.swift", "src/util/Strings.swift", "docs/guide.md", "docs/My Notes.md",
            "node_modules/pkg/index.js", ".hidden/secret.txt", "build/out.o",
        ] {
            try project.file(path, "x")
        }
        return project
    }

    @Test func anEmptyQueryListsTheTopLevelFoldersFirst() async throws {
        let project = try makeProject()
        let entries = await ComposerFileIndex().search("", in: project.url)
        #expect(entries.map(\.path) == ["src", "docs", "README.md"])
        #expect(entries.map(\.isDirectory) == [true, true, false])
    }

    @Test func dependencyBuildAndHiddenFoldersAreSkippedOutsideGit() async throws {
        let project = try makeProject()
        let all = await ComposerFileIndex().search("x", in: project.url, limit: 500)
        #expect(!all.contains { $0.path.hasPrefix("node_modules") || $0.path.hasPrefix(".hidden") || $0.path.hasPrefix("build") })
        let index = await ComposerFileIndex().search("index", in: project.url)
        #expect(index.isEmpty)
    }

    @Test func nameMatchesRankAbovePathAndScatteredMatches() async throws {
        let project = try makeProject()
        let index = ComposerFileIndex()
        #expect(await index.search("main", in: project.url).first?.path == "src/main.swift")
        #expect(await index.search("HELPERS.SWIFT", in: project.url).first?.path == "src/util/Helpers.swift")
        // The folder's own name beats a file inside it whose path holds it.
        #expect(await index.search("util", in: project.url).map(\.path).prefix(3) == ["src/util", "src/util/Helpers.swift", "src/util/Strings.swift"])
        // A path prefix before a name that merely contains the query.
        #expect(await index.search("docs/", in: project.url).map(\.path) == ["docs/guide.md", "docs/My Notes.md"])
        // Letters in order, scattered through the name.
        #expect(await index.search("hlp", in: project.url).map(\.path) == ["src/util/Helpers.swift"])
        #expect(await index.search("smw", in: project.url).map(\.path) == ["src/main.swift"])
        #expect(await index.search("qqq", in: project.url).isEmpty)
    }

    @Test func fewerShallowerShorterPathsWinTies() async throws {
        let project = TemporaryDirectory("files")
        try project.file("a/b/c/file.txt")
        try project.file("a/file.txt")
        try project.file("file.txt")
        let entries = await ComposerFileIndex().search("file.txt", in: project.url)
        #expect(entries.map(\.path) == ["file.txt", "a/file.txt", "a/b/c/file.txt"])
        let limited = await ComposerFileIndex().search("file", in: project.url, limit: 1)
        #expect(limited.map(\.path) == ["file.txt"])
    }

    @Test func entriesKnowTheirNameAndParent() {
        let entry = ComposerFileEntry(path: "src/util/Helpers.swift", isDirectory: false)
        #expect(entry.name == "Helpers.swift")
        #expect(entry.parent == "src/util")
        #expect(ComposerFileEntry(path: "README.md", isDirectory: false).parent == "")
    }

    @Test func aGitRepositoryListsTrackedAndUntrackedFilesButNotIgnoredOnes() async throws {
        let project = TemporaryDirectory("repo")
        try project.file(".gitignore", "ignored.txt\nlogs/\n")
        try project.file("tracked.swift")
        try project.file("untracked.swift")
        try project.file("ignored.txt")
        try project.file("logs/today.log")
        // Inside a repository the folders git keeps are listed too, `node_modules` and all.
        try project.file("node_modules/kept.js")
        try git(["init", "-q"], in: project.url)
        // The index runs git with the user's configuration; keep their global ignore rules out of this repository.
        try git(["config", "core.excludesFile", "/dev/null"], in: project.url)
        try git(["add", "tracked.swift"], in: project.url)
        let paths = await ComposerFileIndex().search("", in: project.url, limit: 500).map(\.path)
        #expect(Set(paths) == [".gitignore", "tracked.swift", "untracked.swift", "node_modules"])
        let all = await ComposerFileIndex().search(".", in: project.url, limit: 500).map(\.path)
        #expect(!all.contains("ignored.txt") && !all.contains("logs/today.log"))
        #expect(all.contains("node_modules/kept.js"))
    }

    /// Runs git with the user's global and system configuration shut out.
    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
    }
}

/// Small composer helpers: token counts, costs and the pickers' labels.
struct ComposerLabelTests {
    @Test func tokenCountsAreShortened() {
        #expect(ComposerContextMeter.formatTokens(0) == "0")
        #expect(ComposerContextMeter.formatTokens(999) == "999")
        #expect(ComposerContextMeter.formatTokens(1_000) == "1k")
        #expect(ComposerContextMeter.formatTokens(1_500) == "1.5k")
        #expect(ComposerContextMeter.formatTokens(9_999) == "10k")
        #expect(ComposerContextMeter.formatTokens(123_456) == "123k")
        #expect(ComposerContextMeter.formatTokens(999_499) == "999k")
        #expect(ComposerContextMeter.formatTokens(999_500) == "1M")
        #expect(ComposerContextMeter.formatTokens(1_260_000) == "1.3M")
    }

    @Test func tinyCostsKeepFourDecimals() {
        #expect(ComposerContextMeter.formatCost(0.0042).contains("0042"))
        #expect(!ComposerContextMeter.formatCost(1.5).contains("5000"))
        #expect(ComposerContextMeter.formatCost(1.5).contains("50"))
        #expect(!ComposerContextMeter.formatCost(0).contains("0000"))
    }

    @Test func theContextSummarySaysHowFullTheWindowIs() {
        let percent = { (value: Double) in value.formatted(.percent.precision(.fractionLength(0))) }
        #expect(
            ComposerContextMeter.summary(usage: TokenUsage(inputTokens: 100_000), contextWindow: 200_000)
                == "Context window: \(percent(0.5)) used (100k of 200k tokens)")
        // A window reported too small never reads past full.
        #expect(
            ComposerContextMeter.summary(usage: TokenUsage(inputTokens: 300_000), contextWindow: 200_000)
                == "Context window: \(percent(1)) used (300k of 200k tokens)")
        #expect(ComposerContextMeter.summary(usage: TokenUsage(inputTokens: 1_200), contextWindow: nil) == "Context window: 1.2k tokens used")
        #expect(ComposerContextMeter.summary(usage: TokenUsage(), contextWindow: 0) == "Context window: 0 tokens used")
    }

    @Test func effortNamesReadAsTitles() {
        #expect(ComposerMenus.effortTitle("none") == "Off")
        #expect(ComposerMenus.effortTitle("OFF") == "Off")
        #expect(ComposerMenus.effortTitle("minimal") == "Minimal")
        #expect(ComposerMenus.effortTitle("xhigh") == "Extra High")
        #expect(ComposerMenus.effortTitle("extra_high") == "Extra High")
        #expect(ComposerMenus.effortTitle("maximum") == "Max")
        #expect(ComposerMenus.effortTitle("auto") == "Auto")
        #expect(ComposerMenus.effortTitle("turbo") == "Turbo")
        #expect(ComposerMenus.effortTitle("") == "")
    }

    @Test func accessModesHaveTheirOwnSymbolAndSummary() {
        #expect(ComposerMenus.symbolName(for: .fullAccess) == "lock.open")
        #expect(ComposerMenus.symbolName(for: .approval) == "lock")
        #expect(ComposerMenus.summary(for: .fullAccess) != ComposerMenus.summary(for: .approval))
    }

    /// The menu offers every access mode, with the thread's checked.
    @Test func theAccessMenuOffersEveryModeWithTheThreadsChecked() {
        let action = Selector(("chooseAccess:"))
        let menu = ComposerMenus.accessMenu(current: .approval, target: NSObject(), action: action)
        #expect(menu.items.map { $0.representedObject as? AccessMode } == [.fullAccess, .approval])
        #expect(menu.items.map(\.state) == [.off, .on])
    }
}

/// What a send does while a turn runs, with the cases of T3 Code's `composerDispatch` tests: the follow-up behavior
/// picks steer or queue, and the alternate send does the other.
struct ComposerDispatchTests {
    @Test(arguments: FollowUpBehavior.allCases, [false, true])
    func withNoTurnRunningEverySendStartsOne(behavior: FollowUpBehavior, alternate: Bool) {
        for canSteer in [false, true] {
            #expect(ComposerDispatch.resolve(running: false, canSteer: canSteer, alternate: alternate, behavior: behavior) == .send)
        }
    }

    @Test func theMainSendFollowsTheBehaviorAndTheAlternateDoesTheOther() {
        #expect(ComposerDispatch.resolve(running: true, canSteer: true, alternate: false, behavior: .steer) == .steer)
        #expect(ComposerDispatch.resolve(running: true, canSteer: true, alternate: true, behavior: .steer) == .queue)
        #expect(ComposerDispatch.resolve(running: true, canSteer: true, alternate: false, behavior: .queue) == .queue)
        #expect(ComposerDispatch.resolve(running: true, canSteer: true, alternate: true, behavior: .queue) == .steer)
    }

    @Test(arguments: FollowUpBehavior.allCases, [false, true])
    func aTurnThatCantTakeAMessageGetsItQueued(behavior: FollowUpBehavior, alternate: Bool) {
        #expect(ComposerDispatch.resolve(running: true, canSteer: false, alternate: alternate, behavior: behavior) == .queue)
    }

    @Test func aShownApprovalMakesTheMainSendSteer() {
        #expect(ComposerDispatch.followUpBehavior(.queue, approvalShown: true) == .steer)
        #expect(ComposerDispatch.followUpBehavior(.steer, approvalShown: true) == .steer)
        #expect(ComposerDispatch.followUpBehavior(.queue, approvalShown: false) == .queue)
        #expect(ComposerDispatch.followUpBehavior(.steer, approvalShown: false) == .steer)
        // The alternate send then queues, and an agent that can't take the message still gets it queued.
        let behavior = ComposerDispatch.followUpBehavior(.queue, approvalShown: true)
        #expect(ComposerDispatch.resolve(running: true, canSteer: true, alternate: false, behavior: behavior) == .steer)
        #expect(ComposerDispatch.resolve(running: true, canSteer: true, alternate: true, behavior: behavior) == .queue)
        #expect(ComposerDispatch.resolve(running: true, canSteer: false, alternate: false, behavior: behavior) == .queue)
    }
}

/// The composer's send keys and the send button's tooltip, for both "Send messages with" settings and both follow-up
/// behaviors.
struct ComposerSendKeysTests {
    private let commandReturn = KeyShortcut("mod+enter")
    private let shiftCommandReturn = KeyShortcut("mod+shift+enter")

    @Test func theKeysFollowTheSendSetting() {
        let returnSends = ComposerSendKeys(sendOnReturn: true)
        #expect(returnSends.send?.displayString == "↩")
        #expect(returnSends.alternate == commandReturn)
        #expect(returnSends.steerQueued == shiftCommandReturn)
        let commandReturnSends = ComposerSendKeys(sendOnReturn: false)
        #expect(commandReturnSends.send == commandReturn)
        #expect(commandReturnSends.alternate == shiftCommandReturn)
        // ⇧⌘↩ is the alternate send then.
        #expect(commandReturnSends.steerQueued == nil)
    }

    @Test func aKeyAMenuItemHasIsLeftOut() {
        let returnSends = ComposerSendKeys(sendOnReturn: true) { $0 == commandReturn }
        #expect(returnSends.send?.displayString == "↩")
        #expect(returnSends.alternate == nil)
        #expect(returnSends.steerQueued == shiftCommandReturn)
        let commandReturnSends = ComposerSendKeys(sendOnReturn: false) { $0 == commandReturn || $0 == shiftCommandReturn }
        #expect(commandReturnSends.send == nil && commandReturnSends.alternate == nil)
        #expect(ComposerSendKeys(sendOnReturn: true) { $0 == shiftCommandReturn }.steerQueued == nil)
    }

    @Test(arguments: FollowUpBehavior.allCases)
    func idleSendNamesItsKey(behavior: FollowUpBehavior) {
        #expect(ComposerSendKeys(sendOnReturn: true).sendToolTip(running: false, canSteer: false, behavior: behavior) == "Send (↩)")
        #expect(ComposerSendKeys(sendOnReturn: false).sendToolTip(running: false, canSteer: true, behavior: behavior) == "Send (⌘↩)")
        let taken = ComposerSendKeys(sendOnReturn: false) { _ in true }
        #expect(taken.sendToolTip(running: false, canSteer: false, behavior: behavior) == "Send")
    }

    @Test func whileATurnRunsTheTooltipSaysWhatEachKeyDoes() {
        let returnSends = ComposerSendKeys(sendOnReturn: true)
        let commandReturnSends = ComposerSendKeys(sendOnReturn: false)
        #expect(
            returnSends.sendToolTip(running: true, canSteer: true, behavior: .steer)
                == "Steer: send into the current turn (↩). ⌘↩ or ⌘-click queues it for after the turn.")
        #expect(
            commandReturnSends.sendToolTip(running: true, canSteer: true, behavior: .steer)
                == "Steer: send into the current turn (⌘↩). ⇧⌘↩ or ⌘-click queues it for after the turn.")
        #expect(
            returnSends.sendToolTip(running: true, canSteer: true, behavior: .queue)
                == "Queue: send when the current turn finishes (↩). ⌘↩ or ⌘-click sends it into the current turn instead.")
        #expect(
            commandReturnSends.sendToolTip(running: true, canSteer: true, behavior: .queue)
                == "Queue: send when the current turn finishes (⌘↩). ⇧⌘↩ or ⌘-click sends it into the current turn instead.")
    }

    @Test(arguments: [false, true], FollowUpBehavior.allCases)
    func aTurnThatCantTakeMessagesOnlyQueues(sendOnReturn: Bool, behavior: FollowUpBehavior) {
        #expect(
            ComposerSendKeys(sendOnReturn: sendOnReturn).sendToolTip(running: true, canSteer: false, behavior: behavior)
                == "Queue message. It is sent when the current turn finishes.")
    }

    @Test func keysAMenuCommandTookAreNotOffered() {
        let returnSends = ComposerSendKeys(sendOnReturn: true) { $0 == commandReturn }
        #expect(
            returnSends.sendToolTip(running: true, canSteer: true, behavior: .steer)
                == "Steer: send into the current turn (↩). ⌘-click queues it for after the turn.")
        let commandReturnSends = ComposerSendKeys(sendOnReturn: false) { $0 == commandReturn }
        #expect(
            commandReturnSends.sendToolTip(running: true, canSteer: true, behavior: .steer)
                == "Steer: send into the current turn. ⇧⌘↩ or ⌘-click queues it for after the turn.")
        #expect(
            commandReturnSends.sendToolTip(running: true, canSteer: true, behavior: .queue)
                == "Queue: send when the current turn finishes. ⇧⌘↩ or ⌘-click sends it into the current turn instead.")
    }
}

struct ComposerMenuPlacementTests {
    private let screen = NSRect(x: 0, y: 0, width: 1920, height: 1050)

    @Test func aMenuThatFitsOpensJustAboveTheControl() {
        let origin = ComposerControlButton.menuOrigin(above: NSRect(x: 600, y: 100, width: 120, height: 28), menuHeight: 300, screen: screen)
        #expect(origin == NSPoint(x: 600, y: 432))
    }

    @Test func aTallMenuStaysOnTheControlsScreen() {
        // Taller than the room above: the top would land on a display arranged above this one.
        let origin = ComposerControlButton.menuOrigin(above: NSRect(x: 600, y: 100, width: 120, height: 28), menuHeight: 1400, screen: screen)
        #expect(origin == NSPoint(x: 600, y: 1050))
        // A screen with a non-zero origin, such as a second display.
        let second = NSRect(x: -227, y: 956, width: 1920, height: 1050)
        let placed = ComposerControlButton.menuOrigin(above: NSRect(x: -300, y: 1000, width: 120, height: 28), menuHeight: 1200, screen: second)
        #expect(placed == NSPoint(x: -227, y: 2006))
    }
}
