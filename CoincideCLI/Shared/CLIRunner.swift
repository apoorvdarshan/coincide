import CoincideRemoteKit
import Foundation

/// Runs a `coincide` command against Coincide through the Remote protocol and prints the result, as text or JSON.
/// Returns the exit status: 0 done, 3 the thread waits for an approval or answer, 4 timed out.
nonisolated struct CLIRunner: Sendable {
    let connection: ControlConnection
    /// For `this`: `COINCIDE_THREAD_ID`, which Coincide gives the agents it starts.
    let environment: [String: String]
    var json = false
    var output: @Sendable (String) -> Void = { print($0) }
    /// How long `wait` sleeps between looks; tests shorten it.
    var pollInterval: TimeInterval = 1
    var sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var now: @Sendable () -> Date = Date.init

    static let needsInput: Int32 = 3
    static let timedOut: Int32 = 4

    func run(_ command: CLICommand) throws -> Int32 {
        switch command {
        case .help:
            output(CLIHelp.text)
        case .projects:
            let workspace = try self.workspace(includeArchived: false)
            emit(.array(workspace.projects.map(Self.project))) {
                workspace.projects.map { "\($0.id.uuidString)  \($0.isChats ? "Chats" : $0.name)  \($0.isChats ? "" : $0.path)" }
                    .joined(separator: "\n")
            }
        case .threads(let project, let includeArchived, let runningOnly):
            let workspace = try self.workspace(includeArchived: includeArchived)
            var threads = workspace.threads
            if let project {
                let found = try Self.resolveProject(project, in: workspace)
                threads = threads.filter { $0.projectID == found.id }
            }
            if runningOnly { threads = threads.filter { $0.isRunning || $0.isStarting } }
            threads.sort { $0.updatedAt > $1.updatedAt }
            emit(.array(threads.map { Self.thread($0, workspace: workspace) })) {
                threads.map { thread in
                    let project = workspace.projects.first { $0.id == thread.projectID }.map { $0.isChats ? "Chats" : $0.name } ?? ""
                    return "\(thread.id.uuidString)  \(Self.state(thread))  \(project) › \(thread.title)"
                }.joined(separator: "\n")
            }
        case .agents:
            let workspace = try self.workspace(includeArchived: false)
            emit(.array(workspace.providers.map(Self.agent))) {
                workspace.providers.map { provider in
                    let models = provider.models.map { model in
                        "    \(model.id)  \(model.name)" + (model.efforts.isEmpty ? "" : "  (effort: \(model.efforts.joined(separator: ", ")))")
                    }
                    return (["\(provider.id)  \(provider.name)  \(provider.state)"] + models).joined(separator: "\n")
                }.joined(separator: "\n")
            }
        case .new(let options):
            return try newThread(options)
        case .send(let thread, let message, let wait, let timeout, let alternate):
            let id = try resolveThread(thread)
            let before = try transcript(id, limit: 1).thread.itemCount
            let delivery = try deliver(message, to: id, alternate: alternate)
            guard wait else {
                emit(["threadID": .string(id.uuidString), "delivery": .string(delivery)]) { "\(delivery.capitalized) to \(id.uuidString)." }
                return 0
            }
            return try waitAndReport(id, since: before, timeout: timeout, extra: ["delivery": .string(delivery)])
        case .wait(let thread, let timeout):
            return try waitAndReport(try resolveThread(thread), since: nil, timeout: timeout, extra: [:])
        case .read(let thread, let count):
            let id = try resolveThread(thread)
            let transcript = try transcript(id, limit: 400)
            let replies = Self.replies(transcript.items, count: count)
            emit(["threadID": .string(id.uuidString), "running": .bool(transcript.turn.isRunning || transcript.turn.isStarting),
                  "replies": .array(replies.map { .string($0) })]) {
                replies.isEmpty ? "No replies yet." : replies.joined(separator: "\n\n")
            }
        case .status(let thread):
            let id = try resolveThread(thread)
            let transcript = try transcript(id, limit: 400)
            let waiting = transcript.items.filter { $0.status == "waiting" && ($0.kind == .approval || $0.kind == .question) }
            emit(Self.status(transcript, waiting: waiting)) {
                var lines = ["\(transcript.thread.title)  \(Self.state(transcript.thread))",
                             "\(transcript.thread.selection.provider) · \(transcript.thread.selection.modelName)"]
                if !transcript.turn.queued.isEmpty { lines.append("Queued messages: \(transcript.turn.queued.count)") }
                for item in waiting {
                    lines.append("Waiting \(item.kind == .approval ? "approval" : "question") \(item.id.uuidString): \(Self.oneLine(item))")
                }
                return lines.joined(separator: "\n")
            }
        case .stop(let thread):
            let id = try resolveThread(thread)
            _ = try connection.request(.stop(threadID: id))
            emit(["stopped": .string(id.uuidString)]) { "Stopped \(id.uuidString)." }
        case .approve(let thread, let item, let always):
            let id = try resolveThread(thread)
            let request = try waitingItem(.approval, item: item, in: id)
            let options = request.approval?.options ?? []
            let kinds = always ? ["allowAlways", "allowOnce"] : ["allowOnce", "allowAlways"]
            guard let option = kinds.lazy.compactMap({ kind in options.first { $0.kind == kind } }).first else {
                throw ControlError(message: "That request offers no way to approve it.")
            }
            _ = try connection.request(.respond(threadID: id, itemID: request.id, optionID: option.id, text: nil))
            emit(["approved": .string(request.id.uuidString), "option": .string(option.label)]) { "Approved: \(option.label)." }
        case .deny(let thread, let item, let message):
            let id = try resolveThread(thread)
            let request = try waitingItem(.approval, item: item, in: id)
            let options = request.approval?.options ?? []
            guard let option = options.first(where: { $0.kind == "deny" }) ?? options.first(where: { $0.kind == "cancel" }) else {
                throw ControlError(message: "That request offers no way to deny it.")
            }
            let text = request.approval?.acceptsText == true ? message : nil
            _ = try connection.request(.respond(threadID: id, itemID: request.id, optionID: option.id, text: text))
            emit(["denied": .string(request.id.uuidString), "option": .string(option.label)]) { "Denied: \(option.label)." }
        case .questions(let thread):
            let id = try resolveThread(thread)
            let waiting = try transcript(id, limit: 400).items.filter { $0.kind == .question && $0.status == "waiting" }
            emit(.array(waiting.map(Self.questions))) {
                waiting.isEmpty ? "No questions are waiting." : waiting.map { item in
                    (["Item \(item.id.uuidString)" + (item.questions?.title.map { ": \($0)" } ?? "")]
                        + (item.questions?.questions ?? []).map { question in
                            let options = question.options.map(\.label).joined(separator: " / ")
                            return "  \(question.id): \(question.prompt)" + (options.isEmpty ? "" : "  [\(options)]")
                        }).joined(separator: "\n")
                }.joined(separator: "\n")
            }
        case .answer(let thread, let item, let text, let answers):
            let id = try resolveThread(thread)
            let request = try waitingItem(.question, item: item, in: id)
            var all = answers
            if let text {
                let questions = request.questions?.questions ?? []
                guard questions.count == 1, let only = questions.first else {
                    throw ControlError(message: "There are several questions; answer each with --answer QUESTION=ANSWER.")
                }
                all[only.id, default: []].append(text)
            }
            _ = try connection.request(.answer(threadID: id, itemID: request.id, answers: all))
            emit(["answered": .string(request.id.uuidString)]) { "Answered." }
        case .archive(let thread, let archived):
            let id = try resolveThread(thread)
            _ = try connection.request(.threadAction(threadID: id, action: .archive(archived)))
            emit([archived ? "archived" : "unarchived": .string(id.uuidString)]) { "\(archived ? "Archived" : "Unarchived") \(id.uuidString)." }
        case .open(let thread):
            let id = try resolveThread(thread)
            _ = try connection.request(.showThread(threadID: id))
            emit(["opened": .string(id.uuidString)]) { "Opened \(id.uuidString) in Coincide." }
        }
        return 0
    }

    // MARK: New threads

    private func newThread(_ options: CLICommand.NewThread) throws -> Int32 {
        let workspace = try self.workspace(includeArchived: false)
        let project = try options.project.map { try Self.resolveProject($0, in: workspace) }
        guard case .thread(let id) = try connection.request(.newThread(projectID: project.flatMap { $0.isChats ? nil : $0.id })) else {
            throw ControlError(message: "Coincide didn't start a thread.")
        }
        var settings = RemoteThreadSettings(threadID: id)
        if let agent = options.agent {
            let provider = try Self.resolveAgent(agent, in: workspace)
            settings.provider = provider.id
            if let model = options.model { settings.modelID = try Self.resolveModel(model, of: provider).id }
        } else if let model = options.model {
            let current = try transcript(id, limit: 1).thread.selection.provider
            guard let provider = workspace.providers.first(where: { $0.id == current }) else {
                throw ControlError(message: "Name the agent with --agent to pick its model.")
            }
            settings.modelID = try Self.resolveModel(model, of: provider).id
        }
        settings.effort = options.effort
        settings.accessMode = options.access.map { ["full", "fullAccess"].contains($0) ? "fullAccess" : "approval" }
        if options.plan { settings.interactionMode = "plan" }
        if settings != RemoteThreadSettings(threadID: id) { _ = try connection.request(.updateSettings(settings)) }
        if let title = options.title { _ = try connection.request(.threadAction(threadID: id, action: .rename(title))) }
        var result: [String: CLIJSON] = ["threadID": .string(id.uuidString)]
        if options.open { _ = try connection.request(.showThread(threadID: id)) }
        guard let message = options.message else {
            emit(.object(result)) { "Started \(id.uuidString)." }
            return 0
        }
        let before = try transcript(id, limit: 1).thread.itemCount
        result["delivery"] = .string(try deliver(message, to: id, alternate: false))
        guard options.wait else {
            emit(.object(result)) { "Started \(id.uuidString)." }
            return 0
        }
        return try waitAndReport(id, since: before, timeout: options.timeout, extra: result)
    }

    private func deliver(_ message: String, to id: UUID, alternate: Bool) throws -> String {
        let request = RemoteSendRequest(threadID: id, text: message, delivery: alternate ? .alternate : .automatic)
        guard case .delivery(let delivery) = try connection.request(.send(request)) else { return "sent" }
        return delivery
    }

    // MARK: Waiting

    enum Outcome: String {
        case done
        case needsInput
        case timedOut
    }

    /// Waits until the thread's turn has ended (after a message added at `since`, when given) or it waits for an
    /// approval or answer, then prints its replies.
    private func waitAndReport(_ id: UUID, since: Int?, timeout: TimeInterval, extra: [String: CLIJSON]) throws -> Int32 {
        let (outcome, transcript) = try wait(id, since: since, timeout: timeout)
        let replies = Self.replies(transcript.items, count: nil)
        let waiting = transcript.items.filter { $0.status == "waiting" && ($0.kind == .approval || $0.kind == .question) }
        var result = extra
        result["threadID"] = .string(id.uuidString)
        result["state"] = .string(outcome.rawValue)
        result["replies"] = .array(replies.map { .string($0) })
        if !waiting.isEmpty { result["waiting"] = .array(waiting.map(Self.waitingJSON)) }
        emit(.object(result)) {
            var lines = replies
            switch outcome {
            case .done: if lines.isEmpty { lines.append("The turn ended without a reply.") }
            case .needsInput:
                lines.append(contentsOf: waiting.map {
                    "Waiting for \($0.kind == .approval ? "approval" : "an answer") (\($0.id.uuidString)): \(Self.oneLine($0))"
                })
            case .timedOut: lines.append("Still working; stopped waiting.")
            }
            return lines.joined(separator: "\n\n")
        }
        switch outcome {
        case .done: return 0
        case .needsInput: return Self.needsInput
        case .timedOut: return Self.timedOut
        }
    }

    func wait(_ id: UUID, since: Int?, timeout: TimeInterval) throws -> (Outcome, RemoteTranscript) {
        let start = now()
        var sawWork = false
        while true {
            let transcript = try transcript(id, limit: 400)
            let turn = transcript.turn
            let busy = turn.isRunning || turn.isStarting || !turn.queued.isEmpty
            sawWork = sawWork || busy
            if transcript.thread.pendingApprovals + transcript.thread.pendingQuestions > 0 {
                return (.needsInput, transcript)
            }
            // After a send, the turn may not have started at the first look; it's over once it ran, or once replies
            // came in after the message, or when nothing has started for a while.
            let started = since.map { transcript.thread.itemCount > $0 + 1 } ?? true
            if !busy, sawWork || started || now().timeIntervalSince(start) > 20 { return (.done, transcript) }
            if timeout > 0, now().timeIntervalSince(start) >= timeout { return (.timedOut, transcript) }
            sleep(pollInterval)
        }
    }

    // MARK: Lookups

    private func workspace(includeArchived: Bool) throws -> RemoteWorkspace {
        guard case .workspace(let workspace) = try connection.request(.workspace(includeArchived: includeArchived)) else {
            throw ControlError(message: "Coincide answered something unexpected.")
        }
        return workspace
    }

    private func transcript(_ id: UUID, limit: Int) throws -> RemoteTranscript {
        guard case .transcript(let transcript) = try connection.request(.openThread(threadID: id, limit: limit)) else {
            throw ControlError(message: "Coincide answered something unexpected.")
        }
        // Only a look, not a subscription to its changes.
        _ = try? connection.request(.closeThread(threadID: id))
        return transcript
    }

    private func waitingItem(_ kind: RemoteItem.Kind, item: String?, in id: UUID) throws -> RemoteItem {
        let waiting = try transcript(id, limit: 400).items.filter { $0.kind == kind && $0.status == "waiting" }
        let noun = kind == .approval ? "approval request" : "question"
        if let item {
            guard let match = waiting.first(where: { $0.id.uuidString.lowercased().hasPrefix(item.lowercased()) }) else {
                throw ControlError(message: "No waiting \(noun) has the id \(item).")
            }
            return match
        }
        guard let only = waiting.last else { throw ControlError(message: "The thread has no waiting \(noun).") }
        guard waiting.count == 1 else {
            throw ControlError(message: "Several \(noun)s wait; pick one with --item: \(waiting.map(\.id.uuidString).joined(separator: ", ")).")
        }
        return only
    }

    func resolveThread(_ name: String) throws -> UUID {
        if name == "this" {
            guard let raw = environment["COINCIDE_THREAD_ID"], let id = UUID(uuidString: raw) else {
                throw ControlError(message: "`this` works only inside a thread Coincide started.")
            }
            return id
        }
        if let id = UUID(uuidString: name) { return id }
        let threads = try workspace(includeArchived: true).threads
        let byID = threads.filter { name.count >= 4 && $0.id.uuidString.lowercased().hasPrefix(name.lowercased()) }
        if byID.count == 1 { return byID[0].id }
        let byTitle = threads.filter { $0.title.caseInsensitiveCompare(name) == .orderedSame }
        if byTitle.count == 1 { return byTitle[0].id }
        let candidates = byID.isEmpty ? byTitle : byID
        if candidates.count > 1 {
            throw ControlError(message: "“\(name)” matches several threads: \(candidates.map { "\($0.id.uuidString) (\($0.title))" }.joined(separator: ", ")).")
        }
        throw ControlError(message: "No thread matches “\(name)”.")
    }

    static func resolveProject(_ name: String, in workspace: RemoteWorkspace) throws -> RemoteProject {
        let lowered = name.lowercased()
        if lowered == "chats" || lowered == "chat", let chats = workspace.projects.first(where: \.isChats) { return chats }
        let expanded = (name as NSString).expandingTildeInPath
        let matches = workspace.projects.filter { project in
            project.id.uuidString.lowercased() == lowered
                || (lowered.count >= 4 && project.id.uuidString.lowercased().hasPrefix(lowered))
                || project.name.caseInsensitiveCompare(name) == .orderedSame
                || (project.path as NSString).expandingTildeInPath == expanded
        }
        guard matches.count == 1 else {
            throw ControlError(message: matches.isEmpty
                ? "No project matches “\(name)”. Run coincide projects."
                : "“\(name)” matches several projects; use its id.")
        }
        return matches[0]
    }

    static func resolveAgent(_ name: String, in workspace: RemoteWorkspace) throws -> RemoteProvider {
        let lowered = name.lowercased()
        let match = workspace.providers.first { $0.id.lowercased() == lowered }
            ?? workspace.providers.first { $0.name.lowercased() == lowered }
            ?? workspace.providers.first { $0.name.lowercased().hasPrefix(lowered) }
        guard let match else {
            throw ControlError(message: "No agent matches “\(name)”. Agents: \(workspace.providers.map(\.id).joined(separator: ", ")).")
        }
        return match
    }

    static func resolveModel(_ name: String, of provider: RemoteProvider) throws -> RemoteModel {
        let lowered = name.lowercased()
        let match = provider.models.first { $0.id.lowercased() == lowered }
            ?? provider.models.first { $0.name.lowercased() == lowered }
            ?? provider.models.first { $0.id.lowercased().hasPrefix(lowered) || $0.name.lowercased().hasPrefix(lowered) }
        guard let match else {
            throw ControlError(message: "\(provider.name) has no model “\(name)”. Run coincide agents.")
        }
        return match
    }

    // MARK: Output

    /// The latest turn's replies (assistant messages and errors after the last message sent), or the last `count`.
    static func replies(_ items: [RemoteItem], count: Int?) -> [String] {
        let replies = items.filter { $0.kind == .assistant || $0.kind == .error }
        if let count { return replies.suffix(count).map(text) }
        let lastUser = items.lastIndex { $0.kind == .user }
        let turn = lastUser.map { items[items.index(after: $0)...] } ?? items[...]
        return turn.filter { $0.kind == .assistant || $0.kind == .error }.map(text)
    }

    private static func text(_ item: RemoteItem) -> String {
        item.kind == .error ? "Error: \(item.text)" : item.text
    }

    private static func oneLine(_ item: RemoteItem) -> String {
        let text = item.kind == .question ? (item.questions?.questions.first?.prompt ?? item.text) : (item.title ?? item.text)
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }

    private static func state(_ thread: RemoteThreadSummary) -> String {
        if thread.pendingApprovals > 0 { return "needs approval" }
        if thread.pendingQuestions > 0 { return "has a question" }
        if thread.isRunning { return "running" }
        if thread.isStarting { return "starting" }
        return thread.isArchived ? "archived" : "idle"
    }

    private func emit(_ value: CLIJSON, text: () -> String) {
        output(json ? value.compactJSON : text())
    }

    private static func project(_ project: RemoteProject) -> CLIJSON {
        ["id": .string(project.id.uuidString), "name": .string(project.isChats ? "Chats" : project.name),
         "path": .string(project.path), "isChats": .bool(project.isChats)]
    }

    private static func thread(_ thread: RemoteThreadSummary, workspace: RemoteWorkspace) -> CLIJSON {
        ["id": .string(thread.id.uuidString), "title": .string(thread.title), "projectID": .string(thread.projectID.uuidString),
         "state": .string(state(thread)), "agent": .string(thread.selection.provider), "model": .string(thread.selection.modelID),
         "updatedAt": .string(ISO8601DateFormatter().string(from: thread.updatedAt)), "archived": .bool(thread.isArchived)]
    }

    private static func agent(_ provider: RemoteProvider) -> CLIJSON {
        ["id": .string(provider.id), "name": .string(provider.name), "state": .string(provider.state),
         "models": .array(provider.models.map { model in
             ["id": .string(model.id), "name": .string(model.name), "efforts": .array(model.efforts.map { .string($0) })]
         })]
    }

    private static func status(_ transcript: RemoteTranscript, waiting: [RemoteItem]) -> CLIJSON {
        ["threadID": .string(transcript.thread.id.uuidString), "title": .string(transcript.thread.title),
         "state": .string(state(transcript.thread)), "agent": .string(transcript.thread.selection.provider),
         "model": .string(transcript.thread.selection.modelID), "queued": .number(Double(transcript.turn.queued.count)),
         "waiting": .array(waiting.map(waitingJSON))]
    }

    private static func waitingJSON(_ item: RemoteItem) -> CLIJSON {
        var object: [String: CLIJSON] = ["id": .string(item.id.uuidString), "kind": .string(item.kind.rawValue), "text": .string(oneLine(item))]
        if let options = item.approval?.options {
            object["options"] = .array(options.map { ["id": .string($0.id), "label": .string($0.label), "kind": .string($0.kind)] })
        }
        if let questions = item.questions { object["questions"] = Self.questionsJSON(questions) }
        return .object(object)
    }

    private static func questions(_ item: RemoteItem) -> CLIJSON {
        ["id": .string(item.id.uuidString), "questions": item.questions.map(questionsJSON) ?? .array([])]
    }

    private static func questionsJSON(_ set: RemoteQuestionSet) -> CLIJSON {
        .array(set.questions.map { question in
            ["id": .string(question.id), "prompt": .string(question.prompt), "options": .array(question.options.map { .string($0.label) }),
             "multiple": .bool(question.allowsMultipleSelection), "freeText": .bool(question.allowsFreeText)]
        })
    }
}

/// A small JSON value for the tool's output, encoded with sorted keys on one line.
nonisolated enum CLIJSON: Sendable, Equatable, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByStringLiteral {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([CLIJSON])
    case object([String: CLIJSON])

    init(dictionaryLiteral elements: (String, CLIJSON)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    init(arrayLiteral elements: CLIJSON...) { self = .array(elements) }
    init(stringLiteral value: String) { self = .string(value) }

    var any: Any {
        switch self {
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .array(let values): values.map(\.any)
        case .object(let values): values.mapValues(\.any)
        }
    }

    var compactJSON: String {
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
