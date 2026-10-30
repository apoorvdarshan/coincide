import Foundation

/// What `coincide` was asked to do. Threads are named by id (or a unique start of it), exact title, or `this` for the
/// thread whose agent runs the command; projects by id, name, path or `chats`.
nonisolated enum CLICommand: Equatable, Sendable {
    case help
    case projects
    case threads(project: String?, includeArchived: Bool, runningOnly: Bool)
    case agents
    case new(NewThread)
    case send(thread: String, message: String, wait: Bool, timeout: TimeInterval, alternate: Bool)
    case wait(thread: String, timeout: TimeInterval)
    case read(thread: String, count: Int?)
    case status(thread: String)
    case stop(thread: String)
    case approve(thread: String, item: String?, always: Bool)
    case deny(thread: String, item: String?, message: String?)
    case questions(thread: String)
    case answer(thread: String, item: String?, text: String?, answers: [String: [String]])
    case archive(thread: String, archived: Bool)
    case open(thread: String)

    struct NewThread: Equatable, Sendable {
        /// Nil starts a chat (no project).
        var project: String?
        var agent: String?
        var model: String?
        var effort: String?
        var access: String?
        var plan = false
        var title: String?
        var message: String?
        var wait = false
        var timeout: TimeInterval = CLICommand.defaultTimeout
        var open = false
    }

    /// How long `wait` and `--wait` wait by default, in seconds.
    static let defaultTimeout: TimeInterval = 1800
}

nonisolated struct CLIInvocation: Equatable, Sendable {
    var command: CLICommand
    /// Print JSON instead of text.
    var json = false
    /// The control socket, instead of `COINCIDE_CONTROL_SOCKET` or the default.
    var socket: String?
}

nonisolated struct CLIUsageError: Error, Equatable, CustomStringConvertible {
    var message: String
    var description: String { message }
}

nonisolated enum CLIParser {
    /// Parses the arguments after the program name. `stdin` supplies a message given as `-`.
    static func parse(_ arguments: [String], stdin: () -> String = { "" }) throws -> CLIInvocation {
        var args = Arguments(arguments)
        var invocation = CLIInvocation(command: .help)
        invocation.json = args.flag("--json")
        invocation.socket = try args.value("--socket")
        guard let name = args.next() else { return invocation }
        func message(_ words: [String]) -> String? {
            if words == ["-"] { return stdin() }
            let text = words.joined(separator: " ")
            return text.isEmpty ? nil : text
        }
        func timeout() throws -> TimeInterval {
            guard let text = try args.value("--timeout") else { return CLICommand.defaultTimeout }
            guard let seconds = TimeInterval(text), seconds >= 0 else {
                throw CLIUsageError(message: "--timeout takes seconds (0 waits as long as it takes).")
            }
            return seconds
        }
        switch name {
        case "help", "-h", "--help":
            invocation.command = .help
        case "projects":
            invocation.command = .projects
        case "threads":
            let project = try args.value("--project")
            invocation.command = .threads(
                project: args.flag("--chats") ? "chats" : project, includeArchived: args.flag("--archived"),
                runningOnly: args.flag("--running"))
        case "agents":
            invocation.command = .agents
        case "new":
            var thread = CLICommand.NewThread()
            let chat = args.flag("--chat")
            thread.project = try args.value("--project")
            if chat, thread.project != nil { throw CLIUsageError(message: "Use --chat or --project, not both.") }
            thread.agent = try args.value("--agent")
            thread.model = try args.value("--model")
            thread.effort = try args.value("--effort")
            thread.access = try args.value("--access")
            if let access = thread.access, !["full", "fullAccess", "approval", "ask"].contains(access) {
                throw CLIUsageError(message: "--access is full or approval.")
            }
            thread.plan = args.flag("--plan")
            thread.title = try args.value("--title")
            thread.wait = args.flag("--wait")
            thread.timeout = try timeout()
            thread.open = args.flag("--open")
            thread.message = message(try args.rest())
            if thread.wait, thread.message == nil { throw CLIUsageError(message: "--wait needs a message to send.") }
            invocation.command = .new(thread)
        case "send":
            let wait = args.flag("--wait")
            let alternate = args.flag("--alternate")
            let seconds = try timeout()
            let thread = try args.thread()
            guard let text = message(try args.rest()) else { throw CLIUsageError(message: "send needs a message.") }
            invocation.command = .send(thread: thread, message: text, wait: wait, timeout: seconds, alternate: alternate)
        case "wait":
            let seconds = try timeout()
            invocation.command = .wait(thread: try args.thread(), timeout: seconds)
        case "read":
            let count = try args.value("--count").map { text -> Int in
                guard let value = Int(text), value > 0 else { throw CLIUsageError(message: "--count takes a number above 0.") }
                return value
            }
            invocation.command = .read(thread: try args.thread(), count: count)
        case "status":
            invocation.command = .status(thread: try args.thread())
        case "stop":
            invocation.command = .stop(thread: try args.thread())
        case "approve":
            let item = try args.value("--item")
            let always = args.flag("--always")
            invocation.command = .approve(thread: try args.thread(), item: item, always: always)
        case "deny":
            let item = try args.value("--item")
            let reason = try args.value("--message")
            invocation.command = .deny(thread: try args.thread(), item: item, message: reason)
        case "questions":
            invocation.command = .questions(thread: try args.thread())
        case "answer":
            let item = try args.value("--item")
            var answers: [String: [String]] = [:]
            while let pair = try args.value("--answer") {
                guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                    throw CLIUsageError(message: "--answer takes question=answer.")
                }
                answers[String(pair[..<equals]), default: []].append(String(pair[pair.index(after: equals)...]))
            }
            let thread = try args.thread()
            let text = message(try args.rest())
            guard text != nil || !answers.isEmpty else { throw CLIUsageError(message: "answer needs an answer.") }
            invocation.command = .answer(thread: thread, item: item, text: text, answers: answers)
        case "archive", "unarchive":
            invocation.command = .archive(thread: try args.thread(), archived: name == "archive")
        case "open":
            invocation.command = .open(thread: try args.thread())
        default:
            throw CLIUsageError(message: "Unknown command “\(name)”. Run coincide help.")
        }
        if let extra = args.leftover { throw CLIUsageError(message: "Unexpected “\(extra)”. Run coincide help.") }
        return invocation
    }

    /// The arguments, with options taken out wherever they appear.
    private struct Arguments {
        private var items: [String]
        private var positional: [String] = []

        init(_ items: [String]) { self.items = items }

        mutating func flag(_ name: String) -> Bool {
            guard let index = items.firstIndex(of: name) else { return false }
            items.remove(at: index)
            return true
        }

        mutating func value(_ name: String) throws -> String? {
            if let index = items.firstIndex(where: { $0.hasPrefix(name + "=") }) {
                let item = items.remove(at: index)
                return String(item.dropFirst(name.count + 1))
            }
            guard let index = items.firstIndex(of: name) else { return nil }
            guard index + 1 < items.count else { throw CLIUsageError(message: "\(name) needs a value.") }
            let value = items[index + 1]
            items.removeSubrange(index...index + 1)
            return value
        }

        /// The next word that isn't an option.
        mutating func next() -> String? {
            guard let index = items.firstIndex(where: { !$0.hasPrefix("--") || $0 == "--" }) else { return nil }
            if items[index] == "--" { return nil }
            return items.remove(at: index)
        }

        mutating func thread() throws -> String {
            guard let thread = next() else { throw CLIUsageError(message: "Name a thread: its id, title or this.") }
            return thread
        }

        /// Everything left, as words; after `--`, options are words too.
        mutating func rest() throws -> [String] {
            var words: [String] = []
            while !items.isEmpty {
                let item = items.removeFirst()
                if item == "--" {
                    words += items
                    items.removeAll()
                } else if item.hasPrefix("--") {
                    throw CLIUsageError(message: "Unknown option “\(item)”. Run coincide help.")
                } else {
                    words.append(item)
                }
            }
            return words
        }

        var leftover: String? { items.first }
    }
}

nonisolated enum CLIHelp {
    static let text = """
        coincide: drive Coincide from the command line. Coincide must be running, with Settings › General ›
        Command-line control on.

        Threads are named by id (or a unique start of it), exact title, or `this` (the thread whose agent runs the
        command). Projects are named by id, name, folder path, or `chats`.

          coincide projects                      List projects.
          coincide threads [--project P | --chats] [--archived] [--running]
                                                 List threads, newest first.
          coincide agents                        List agents and their models.
          coincide new [--chat | --project P] [--agent A] [--model M] [--effort E] [--access full|approval]
                       [--plan] [--title T] [--wait] [--timeout S] [--open] [MESSAGE…]
                                                 Start a chat (the default) or a thread in a project, send MESSAGE,
                                                 and with --wait print the reply when the turn ends.
          coincide send THREAD [--wait] [--timeout S] [--alternate] MESSAGE…
                                                 Send a message (steers or queues while a turn runs, as Coincide's
                                                 follow-up setting says; --alternate does the other).
          coincide wait THREAD [--timeout S]      Wait until the thread's turn ends or it needs you.
          coincide read THREAD [--count N]        Print the latest turn's replies (or the last N replies).
          coincide status THREAD                  Show whether it runs and what waits for an answer.
          coincide stop THREAD                    Stop the running turn.
          coincide approve THREAD [--item ID] [--always]
          coincide deny THREAD [--item ID] [--message TEXT]
                                                 Answer the agent's waiting approval request.
          coincide questions THREAD               Show the agent's waiting questions.
          coincide answer THREAD [--item ID] [--answer QUESTION=ANSWER …] [ANSWER…]
                                                 Answer them (one question: just the answer).
          coincide archive THREAD | unarchive THREAD
          coincide open THREAD                    Show the thread in Coincide's window.
          coincide help

        Options: --json prints JSON. --socket PATH talks to another socket than COINCIDE_CONTROL_SOCKET or
        ~/Library/Application Support/Coincide/control.sock. A MESSAGE of - is read from standard input.

        Exit status: 0 done, 1 failed, 2 wrong usage, 3 the thread waits for an approval or answer, 4 timed out.
        """
}
