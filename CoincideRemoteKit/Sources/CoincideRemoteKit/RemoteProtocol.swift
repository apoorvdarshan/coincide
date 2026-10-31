import Foundation

/// Coincide Remote's wire protocol: JSON text messages over a WebSocket, inside TLS whose certificate the phone pins.
///
/// Every message carries the protocol version `v`. The phone sends requests (`RemoteClientMessage`), each with an id the
/// Mac's response repeats; the Mac also sends events on its own (`RemoteServerMessage.event`). The first request on a
/// connection must be `hello` (a paired phone's token) or `pair` (the one-time secret from the QR code); the Mac
/// closes a connection that sends anything else first.
///
/// Versioning: a peer accepts messages from `minimumVersion` through its own `version`. Request, result and event
/// types it doesn't know are answered with `unsupported` (requests) or ignored (results and events), so a newer phone
/// and an older Mac, or the reverse, keep working with what they share. New message types are added this way rather
/// than by raising `version`, which an older peer would refuse outright: `presence` (phone to Mac) and the `notify`
/// and `clearNotifications` events (Mac to phone) came later, and a peer without them simply never sends or shows them.
public enum RemoteProtocol {
    public static let version = 1
    public static let minimumVersion = 1
    /// The Bonjour service type the Mac advertises.
    public static let serviceType = "_coincide._tcp"
    /// The port the Mac listens on unless it's taken.
    public static let defaultPort: UInt16 = 47_391
    /// Largest message either side accepts, which leaves room for a few photos.
    public static let maxMessageBytes = 32 * 1024 * 1024

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.dataEncodingStrategy = .base64
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        decoder.dataDecodingStrategy = .base64
        return decoder
    }

    public static func isSupported(_ version: Int) -> Bool { (minimumVersion...Self.version).contains(version) }
}

// MARK: Requests

/// The first request of a paired phone.
public struct RemoteHello: Codable, Hashable, Sendable {
    public var deviceID: String
    public var token: String
    public var appVersion: String

    public init(deviceID: String, token: String, appVersion: String) {
        self.deviceID = deviceID
        self.token = token
        self.appVersion = appVersion
    }
}

/// Trades the QR code's one-time secret for a long-lived token.
public struct RemotePairRequest: Codable, Hashable, Sendable {
    public var secret: String
    public var deviceName: String

    public init(secret: String, deviceName: String) {
        self.secret = secret
        self.deviceName = deviceName
    }
}

public struct RemotePairResult: Codable, Hashable, Sendable {
    public var deviceID: String
    public var token: String
    public var server: RemoteServerInfo

    public init(deviceID: String, token: String, server: RemoteServerInfo) {
        self.deviceID = deviceID
        self.token = token
        self.server = server
    }
}

/// An image the phone attaches to a message.
public struct RemoteImage: Codable, Hashable, Sendable {
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public struct RemoteSendRequest: Codable, Hashable, Sendable {
    /// What happens to a message sent while a turn runs.
    public enum Delivery: String, Codable, Sendable {
        /// The Mac's follow-up setting, as the Mac's send button does.
        case automatic
        /// The other behavior, as ⌘-clicking send on the Mac does.
        case alternate
    }

    public var threadID: UUID
    public var text: String
    public var images: [RemoteImage]
    public var delivery: Delivery

    public init(threadID: UUID, text: String, images: [RemoteImage] = [], delivery: Delivery = .automatic) {
        self.threadID = threadID
        self.text = text
        self.images = images
        self.delivery = delivery
    }
}

/// Changes to a thread's composer settings. Nil fields stay as they are.
public struct RemoteThreadSettings: Codable, Hashable, Sendable {
    public var threadID: UUID
    /// Switching the agent or model; the effort and speed carry over when the new model has them.
    public var provider: String?
    public var modelID: String?
    public var accountID: String?
    public var effort: String?
    /// A speed id, or `standard` for the model's standard speed.
    public var speed: String?
    public var accessMode: String?
    public var interactionMode: String?

    public init(
        threadID: UUID, provider: String? = nil, modelID: String? = nil, accountID: String? = nil, effort: String? = nil,
        speed: String? = nil, accessMode: String? = nil, interactionMode: String? = nil
    ) {
        self.threadID = threadID
        self.provider = provider
        self.modelID = modelID
        self.accountID = accountID
        self.effort = effort
        self.speed = speed
        self.accessMode = accessMode
        self.interactionMode = interactionMode
    }

    /// The speed value that asks for standard speed.
    public static let standardSpeed = "standard"
}

/// Something done to a thread from its menu.
public enum RemoteThreadAction: Codable, Hashable, Sendable {
    case rename(String)
    case pin(Bool)
    case archive(Bool)
    /// Nil wakes it.
    case snooze(Date?)
    case settle(Bool)
    case markUnread
    case move(projectID: UUID)
    /// The phone asks the user first.
    case delete

    private enum CodingKeys: String, CodingKey { case action, title, value, date, projectID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .action) {
        case "rename": self = .rename(try container.decode(String.self, forKey: .title))
        case "pin": self = .pin(try container.decode(Bool.self, forKey: .value))
        case "archive": self = .archive(try container.decode(Bool.self, forKey: .value))
        case "snooze": self = .snooze(try container.decodeIfPresent(Date.self, forKey: .date))
        case "settle": self = .settle(try container.decode(Bool.self, forKey: .value))
        case "markUnread": self = .markUnread
        case "move": self = .move(projectID: try container.decode(UUID.self, forKey: .projectID))
        case "delete": self = .delete
        case let other: throw RemoteProtocolError.unsupported(other)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .rename(let title):
            try container.encode("rename", forKey: .action)
            try container.encode(title, forKey: .title)
        case .pin(let value):
            try container.encode("pin", forKey: .action)
            try container.encode(value, forKey: .value)
        case .archive(let value):
            try container.encode("archive", forKey: .action)
            try container.encode(value, forKey: .value)
        case .snooze(let date):
            try container.encode("snooze", forKey: .action)
            try container.encodeIfPresent(date, forKey: .date)
        case .settle(let value):
            try container.encode("settle", forKey: .action)
            try container.encode(value, forKey: .value)
        case .markUnread:
            try container.encode("markUnread", forKey: .action)
        case .move(let projectID):
            try container.encode("move", forKey: .action)
            try container.encode(projectID, forKey: .projectID)
        case .delete:
            try container.encode("delete", forKey: .action)
        }
    }
}

public enum RemoteRequest: Hashable, Sendable {
    case hello(RemoteHello)
    case pair(RemotePairRequest)
    case ping
    case workspace(includeArchived: Bool)
    /// Sends the thread's newest `limit` items and then its live changes until `closeThread`.
    case openThread(threadID: UUID, limit: Int)
    case closeThread(threadID: UUID)
    case loadEarlier(threadID: UUID, beforeIndex: Int, limit: Int)
    case markSeen(threadID: UUID)
    case send(RemoteSendRequest)
    case steerQueued(threadID: UUID, messageID: UUID)
    case removeQueued(threadID: UUID, messageID: UUID)
    case stop(threadID: UUID)
    case respond(threadID: UUID, itemID: UUID, optionID: String, text: String?)
    case answer(threadID: UUID, itemID: UUID, answers: [String: [String]])
    case dismissQuestion(threadID: UUID, itemID: UUID)
    case updateSettings(RemoteThreadSettings)
    /// Nil starts a chat.
    case newThread(projectID: UUID?)
    case threadAction(threadID: UUID, action: RemoteThreadAction)
    /// The changes of one turn (the id of the item that opened it), or the thread's uncommitted changes for nil.
    case diff(threadID: UUID, turnID: UUID?)
    case runScript(threadID: UUID, scriptID: UUID)
    case usageLimits
    /// Whether the app is in front, what it shows and how long since it was touched (see `RemotePresence`). An older
    /// Mac answers `unsupported`, which the phone ignores.
    case presence(RemotePresence)
    /// Opens the thread in the Mac's window. Only the Mac's own command-line tool may ask; a phone gets `unsupported`.
    case showThread(threadID: UUID)
    /// A conversation with a bot: an untouched one waiting is reused, as on the Mac. Answers `thread`. An older Mac
    /// answers `unsupported`.
    case newBotConversation(botID: UUID)
    /// Creates a bot (no `id`) or edits one. Answers `bot` with its id. An older Mac answers `unsupported`.
    case saveBot(RemoteBotDraft)
    /// Deletes a bot; its conversations stay as chats unless `deletesConversations`. An older Mac answers `unsupported`.
    case deleteBot(botID: UUID, deletesConversations: Bool)
    /// The Mac's Settings, described page by page (`RemoteSettingsSnapshot`). Answers `settings`, then sends a
    /// `settings` event whenever they change. An older Mac answers `unsupported`.
    case settings
    /// Changes one setting by its row's key. Answers the updated `settings`.
    case changeSetting(key: String, value: RemoteSettingValue)
    /// Runs a row's action, or brings up its place on the Mac for one that finishes there. Answers `settings`.
    case settingsAction(key: String)
    /// The text of a `document` row. Answers `settingsDocument`. An older Mac answers `unsupported`.
    case settingsDocument(key: String)
    /// Saves a `document` row's text, refused when the document changed since the version given. Answers the saved
    /// `settingsDocument`. An older Mac answers `unsupported`.
    case saveSettingsDocument(RemoteSettingsDocument)
    /// Expands or collapses a project in the Mac's sidebar, so both show the same. Answers `ok`. An older Mac answers
    /// `unsupported`, and the phone keeps the choice to itself.
    case setProjectExpanded(projectID: UUID, expanded: Bool)
    /// An image an item previews (`RemoteItem.media`, by its index): a thumbnail, or the full picture. Answers `media`.
    /// The Mac reads only what that item references; video gets a thumbnail of its first frame, and audio and
    /// interactive pages none. An older Mac answers `unsupported`.
    case media(threadID: UUID, itemID: UUID, index: Int, full: Bool)
    /// Suggestions for the word being typed: `@` and a query for files in the thread's folder, `/` for the commands
    /// and skills its agent offers there. Answers `completions`. An older Mac answers `unsupported`.
    case completions(threadID: UUID, trigger: String, query: String)
    /// Where the thread works and on which branch, with the branches it can use. Answers `checkout`. An older Mac
    /// answers `unsupported`, and the phone shows the checkout read only.
    case checkout(threadID: UUID)
    /// Changes where the thread works or its branch, as the Mac's checkout menus do. Answers the updated `checkout`.
    case changeCheckout(threadID: UUID, action: RemoteCheckoutAction)
    /// Settings › Usage as the Mac shows it, for a period and filters, reading the providers again first when asked.
    /// Answers `usageDashboard`. An older Mac answers `unsupported`, and the phone shows `usageLimits` instead.
    case usageDashboard(RemoteUsageQuery)
    /// Forks a thread, whole or through a turn, as "Fork Thread" and "Fork from Here" do. Answers `thread` with the
    /// fork. An older Mac answers `unsupported`.
    case forkThread(RemoteForkRequest)
    /// What "Edit from Here" can do with one of the user's messages. Answers `rewindOptions`.
    case rewindOptions(RemoteItemReference)
    /// Rewinds the conversation to before one of the user's messages, putting files back too when asked. Answers
    /// `rewind` with the message, for the composer.
    case rewind(RemoteRewindRequest)
    /// The banner over a thread's composer. Answers `composerNotice`.
    case composerNotice(threadID: UUID)
    /// Dismisses the usage-limit banner or (un)schedules the thread to resume at the reset. Answers `composerNotice`.
    case usageWarningAction(RemoteUsageWarningCommand)
    /// Changes how the Mac's sidebar sorts its lists and how many threads a project shows. Answers `ok`; a `workspace`
    /// event follows.
    case setSidebarOptions(RemoteSidebarOptions)
    /// What a project's new threads start with. Answers `projectDefaults`.
    case projectDefaults(projectID: UUID)
    /// Saves what a project's new threads start with. Answers the saved `projectDefaults`.
    case saveProjectDefaults(RemoteProjectDefaults)
    /// Removes a project from Coincide, deleting its threads; its folder stays. Answers `ok`.
    case removeProject(projectID: UUID)
    /// The Mac's scheduled tasks. Answers `scheduledTasks`.
    case scheduledTasks
    /// Creates or edits a scheduled task. Answers the updated `scheduledTasks`.
    case saveScheduledTask(RemoteScheduledTaskDraft)
    /// Pauses, resumes, runs or deletes a scheduled task. Answers the updated `scheduledTasks`.
    case scheduledTaskAction(RemoteScheduledTaskCommand)
    /// A thread's folder as git sees it, with the actions it allows. Answers `gitState`.
    case gitState(threadID: UUID)
    /// Commits, pushes, pulls or opens a pull request for a thread's folder. Answers `gitAction` once done.
    case gitAction(RemoteGitActionRequest)
    /// A project's pull requests. Answers `pullRequests`.
    case pullRequests(RemotePullRequestQuery)
    /// One pull request with its checks and reviews. Answers `pullRequest`.
    case pullRequest(RemotePullRequestReference)
    /// Merges, reviews, marks ready or checks out a pull request. Answers the updated `pullRequest`, or `thread`.
    case pullRequestAction(RemotePullRequestCommand)

    /// The request's name on the wire.
    public var name: String {
        switch self {
        case .hello: "hello"
        case .pair: "pair"
        case .ping: "ping"
        case .workspace: "workspace"
        case .openThread: "openThread"
        case .closeThread: "closeThread"
        case .loadEarlier: "loadEarlier"
        case .markSeen: "markSeen"
        case .send: "send"
        case .steerQueued: "steerQueued"
        case .removeQueued: "removeQueued"
        case .stop: "stop"
        case .respond: "respond"
        case .answer: "answer"
        case .dismissQuestion: "dismissQuestion"
        case .updateSettings: "updateSettings"
        case .newThread: "newThread"
        case .threadAction: "threadAction"
        case .diff: "diff"
        case .runScript: "runScript"
        case .usageLimits: "usageLimits"
        case .presence: "presence"
        case .showThread: "showThread"
        case .newBotConversation: "newBotConversation"
        case .saveBot: "saveBot"
        case .deleteBot: "deleteBot"
        case .settings: "settings"
        case .changeSetting: "changeSetting"
        case .settingsAction: "settingsAction"
        case .settingsDocument: "settingsDocument"
        case .saveSettingsDocument: "saveSettingsDocument"
        case .setProjectExpanded: "setProjectExpanded"
        case .media: "media"
        case .completions: "completions"
        case .checkout: "checkout"
        case .changeCheckout: "changeCheckout"
        case .usageDashboard: "usageDashboard"
        case .forkThread: "forkThread"
        case .rewindOptions: "rewindOptions"
        case .rewind: "rewind"
        case .composerNotice: "composerNotice"
        case .usageWarningAction: "usageWarningAction"
        case .setSidebarOptions: "setSidebarOptions"
        case .projectDefaults: "projectDefaults"
        case .saveProjectDefaults: "saveProjectDefaults"
        case .removeProject: "removeProject"
        case .scheduledTasks: "scheduledTasks"
        case .saveScheduledTask: "saveScheduledTask"
        case .scheduledTaskAction: "scheduledTaskAction"
        case .gitState: "gitState"
        case .gitAction: "gitAction"
        case .pullRequests: "pullRequests"
        case .pullRequest: "pullRequest"
        case .pullRequestAction: "pullRequestAction"
        }
    }
}

/// The fields requests carry, flattened into one body object.
private struct RequestBody: Codable {
    var threadID: UUID?
    var itemID: UUID?
    var messageID: UUID?
    var projectID: UUID?
    var scriptID: UUID?
    var turnID: UUID?
    var limit: Int?
    var beforeIndex: Int?
    var optionID: String?
    var text: String?
    var answers: [String: [String]]?
    var includeArchived: Bool?
    var action: RemoteThreadAction?
    var botID: UUID?
    var deletesConversations: Bool?
    var key: String?
    var value: RemoteSettingValue?
    var expanded: Bool?
    var index: Int?
    var full: Bool?
    var trigger: String?
    var query: String?
    var checkoutAction: RemoteCheckoutAction?
}

public enum RemoteProtocolError: Error, Equatable, Sendable {
    /// A message type this side doesn't know.
    case unsupported(String)
    /// A protocol version this side can't speak.
    case version(Int)
    case missingField(String)
}

/// A phone's message to the Mac.
public struct RemoteClientMessage: Hashable, Sendable, Codable {
    public var version: Int
    public var id: String
    public var request: RemoteRequest

    public init(id: String = UUID().uuidString, request: RemoteRequest, version: Int = RemoteProtocol.version) {
        self.version = version
        self.id = id
        self.request = request
    }

    private enum CodingKeys: String, CodingKey { case v, id, type, body }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .v)
        id = try container.decode(String.self, forKey: .id)
        guard RemoteProtocol.isSupported(version) else { throw RemoteProtocolError.version(version) }
        let type = try container.decode(String.self, forKey: .type)
        func body<T: Decodable>(_ type: T.Type) throws -> T { try container.decode(T.self, forKey: .body) }
        func fields() throws -> RequestBody { try container.decodeIfPresent(RequestBody.self, forKey: .body) ?? RequestBody() }
        func need<T>(_ value: T?, _ name: String) throws -> T {
            guard let value else { throw RemoteProtocolError.missingField(name) }
            return value
        }
        switch type {
        case "hello": request = .hello(try body(RemoteHello.self))
        case "pair": request = .pair(try body(RemotePairRequest.self))
        case "ping": request = .ping
        case "workspace": request = .workspace(includeArchived: try fields().includeArchived ?? false)
        case "openThread":
            let f = try fields()
            request = .openThread(threadID: try need(f.threadID, "threadID"), limit: f.limit ?? 200)
        case "closeThread": request = .closeThread(threadID: try need(try fields().threadID, "threadID"))
        case "loadEarlier":
            let f = try fields()
            request = .loadEarlier(
                threadID: try need(f.threadID, "threadID"), beforeIndex: try need(f.beforeIndex, "beforeIndex"),
                limit: f.limit ?? 200)
        case "markSeen": request = .markSeen(threadID: try need(try fields().threadID, "threadID"))
        case "send": request = .send(try body(RemoteSendRequest.self))
        case "steerQueued", "removeQueued":
            let f = try fields()
            let thread = try need(f.threadID, "threadID")
            let message = try need(f.messageID, "messageID")
            request = type == "steerQueued" ? .steerQueued(threadID: thread, messageID: message)
                : .removeQueued(threadID: thread, messageID: message)
        case "stop": request = .stop(threadID: try need(try fields().threadID, "threadID"))
        case "respond":
            let f = try fields()
            request = .respond(
                threadID: try need(f.threadID, "threadID"), itemID: try need(f.itemID, "itemID"),
                optionID: try need(f.optionID, "optionID"), text: f.text)
        case "answer":
            let f = try fields()
            request = .answer(
                threadID: try need(f.threadID, "threadID"), itemID: try need(f.itemID, "itemID"),
                answers: try need(f.answers, "answers"))
        case "dismissQuestion":
            let f = try fields()
            request = .dismissQuestion(threadID: try need(f.threadID, "threadID"), itemID: try need(f.itemID, "itemID"))
        case "updateSettings": request = .updateSettings(try body(RemoteThreadSettings.self))
        case "newThread": request = .newThread(projectID: try fields().projectID)
        case "threadAction":
            let f = try fields()
            request = .threadAction(threadID: try need(f.threadID, "threadID"), action: try need(f.action, "action"))
        case "diff":
            let f = try fields()
            request = .diff(threadID: try need(f.threadID, "threadID"), turnID: f.turnID)
        case "runScript":
            let f = try fields()
            request = .runScript(threadID: try need(f.threadID, "threadID"), scriptID: try need(f.scriptID, "scriptID"))
        case "usageLimits": request = .usageLimits
        case "presence": request = .presence(try body(RemotePresence.self))
        case "showThread": request = .showThread(threadID: try need(try fields().threadID, "threadID"))
        case "newBotConversation": request = .newBotConversation(botID: try need(try fields().botID, "botID"))
        case "saveBot": request = .saveBot(try body(RemoteBotDraft.self))
        case "deleteBot":
            let f = try fields()
            request = .deleteBot(botID: try need(f.botID, "botID"), deletesConversations: f.deletesConversations ?? false)
        case "settings": request = .settings
        case "changeSetting":
            let f = try fields()
            request = .changeSetting(key: try need(f.key, "key"), value: try need(f.value, "value"))
        case "settingsAction": request = .settingsAction(key: try need(try fields().key, "key"))
        case "settingsDocument": request = .settingsDocument(key: try need(try fields().key, "key"))
        case "saveSettingsDocument": request = .saveSettingsDocument(try body(RemoteSettingsDocument.self))
        case "setProjectExpanded":
            let f = try fields()
            request = .setProjectExpanded(projectID: try need(f.projectID, "projectID"), expanded: try need(f.expanded, "expanded"))
        case "media":
            let f = try fields()
            request = .media(
                threadID: try need(f.threadID, "threadID"), itemID: try need(f.itemID, "itemID"), index: try need(f.index, "index"),
                full: f.full ?? false)
        case "checkout": request = .checkout(threadID: try need(try fields().threadID, "threadID"))
        case "usageDashboard": request = .usageDashboard(try body(RemoteUsageQuery.self))
        case "changeCheckout":
            let f = try fields()
            request = .changeCheckout(threadID: try need(f.threadID, "threadID"), action: try need(f.checkoutAction, "checkoutAction"))
        case "completions":
            let f = try fields()
            request = .completions(threadID: try need(f.threadID, "threadID"), trigger: try need(f.trigger, "trigger"), query: f.query ?? "")
        case "forkThread": request = .forkThread(try body(RemoteForkRequest.self))
        case "rewindOptions": request = .rewindOptions(try body(RemoteItemReference.self))
        case "rewind": request = .rewind(try body(RemoteRewindRequest.self))
        case "composerNotice": request = .composerNotice(threadID: try need(try fields().threadID, "threadID"))
        case "usageWarningAction": request = .usageWarningAction(try body(RemoteUsageWarningCommand.self))
        case "setSidebarOptions": request = .setSidebarOptions(try body(RemoteSidebarOptions.self))
        case "projectDefaults": request = .projectDefaults(projectID: try need(try fields().projectID, "projectID"))
        case "saveProjectDefaults": request = .saveProjectDefaults(try body(RemoteProjectDefaults.self))
        case "removeProject": request = .removeProject(projectID: try need(try fields().projectID, "projectID"))
        case "scheduledTasks": request = .scheduledTasks
        case "saveScheduledTask": request = .saveScheduledTask(try body(RemoteScheduledTaskDraft.self))
        case "scheduledTaskAction": request = .scheduledTaskAction(try body(RemoteScheduledTaskCommand.self))
        case "gitState": request = .gitState(threadID: try need(try fields().threadID, "threadID"))
        case "gitAction": request = .gitAction(try body(RemoteGitActionRequest.self))
        case "pullRequests": request = .pullRequests(try body(RemotePullRequestQuery.self))
        case "pullRequest": request = .pullRequest(try body(RemotePullRequestReference.self))
        case "pullRequestAction": request = .pullRequestAction(try body(RemotePullRequestCommand.self))
        default: throw RemoteProtocolError.unsupported(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .v)
        try container.encode(id, forKey: .id)
        try container.encode(request.name, forKey: .type)
        var f = RequestBody()
        switch request {
        case .hello(let hello): try container.encode(hello, forKey: .body); return
        case .pair(let pair): try container.encode(pair, forKey: .body); return
        case .send(let send): try container.encode(send, forKey: .body); return
        case .updateSettings(let settings): try container.encode(settings, forKey: .body); return
        case .presence(let presence): try container.encode(presence, forKey: .body); return
        case .saveBot(let draft): try container.encode(draft, forKey: .body); return
        case .saveSettingsDocument(let document): try container.encode(document, forKey: .body); return
        case .usageDashboard(let query): try container.encode(query, forKey: .body); return
        case .forkThread(let fork): try container.encode(fork, forKey: .body); return
        case .rewindOptions(let reference): try container.encode(reference, forKey: .body); return
        case .rewind(let rewind): try container.encode(rewind, forKey: .body); return
        case .usageWarningAction(let command): try container.encode(command, forKey: .body); return
        case .setSidebarOptions(let options): try container.encode(options, forKey: .body); return
        case .saveProjectDefaults(let defaults): try container.encode(defaults, forKey: .body); return
        case .saveScheduledTask(let draft): try container.encode(draft, forKey: .body); return
        case .scheduledTaskAction(let command): try container.encode(command, forKey: .body); return
        case .gitAction(let action): try container.encode(action, forKey: .body); return
        case .pullRequests(let query): try container.encode(query, forKey: .body); return
        case .pullRequest(let reference): try container.encode(reference, forKey: .body); return
        case .pullRequestAction(let command): try container.encode(command, forKey: .body); return
        case .ping, .usageLimits, .settings, .scheduledTasks: return
        case .composerNotice(let threadID), .gitState(let threadID): f.threadID = threadID
        case .projectDefaults(let projectID), .removeProject(let projectID): f.projectID = projectID
        case .changeSetting(let key, let value):
            f.key = key
            f.value = value
        case .settingsAction(let key), .settingsDocument(let key): f.key = key
        case .newBotConversation(let botID): f.botID = botID
        case .deleteBot(let botID, let deletesConversations):
            f.botID = botID
            f.deletesConversations = deletesConversations
        case .workspace(let includeArchived): f.includeArchived = includeArchived
        case .openThread(let threadID, let limit):
            f.threadID = threadID
            f.limit = limit
        case .closeThread(let threadID), .markSeen(let threadID), .stop(let threadID), .showThread(let threadID),
            .checkout(let threadID):
            f.threadID = threadID
        case .changeCheckout(let threadID, let action):
            f.threadID = threadID
            f.checkoutAction = action
        case .loadEarlier(let threadID, let beforeIndex, let limit):
            f.threadID = threadID
            f.beforeIndex = beforeIndex
            f.limit = limit
        case .steerQueued(let threadID, let messageID), .removeQueued(let threadID, let messageID):
            f.threadID = threadID
            f.messageID = messageID
        case .respond(let threadID, let itemID, let optionID, let text):
            f.threadID = threadID
            f.itemID = itemID
            f.optionID = optionID
            f.text = text
        case .answer(let threadID, let itemID, let answers):
            f.threadID = threadID
            f.itemID = itemID
            f.answers = answers
        case .dismissQuestion(let threadID, let itemID):
            f.threadID = threadID
            f.itemID = itemID
        case .newThread(let projectID): f.projectID = projectID
        case .setProjectExpanded(let projectID, let expanded):
            f.projectID = projectID
            f.expanded = expanded
        case .media(let threadID, let itemID, let index, let full):
            f.threadID = threadID
            f.itemID = itemID
            f.index = index
            f.full = full
        case .completions(let threadID, let trigger, let query):
            f.threadID = threadID
            f.trigger = trigger
            f.query = query
        case .threadAction(let threadID, let action):
            f.threadID = threadID
            f.action = action
        case .diff(let threadID, let turnID):
            f.threadID = threadID
            f.turnID = turnID
        case .runScript(let threadID, let scriptID):
            f.threadID = threadID
            f.scriptID = scriptID
        }
        try container.encode(f, forKey: .body)
    }
}

// MARK: Results and events

/// What a request returns.
public enum RemoteResult: Hashable, Sendable {
    case ok
    case server(RemoteServerInfo)
    case paired(RemotePairResult)
    case workspace(RemoteWorkspace)
    case transcript(RemoteTranscript)
    case items(RemoteItemPage)
    /// Where a sent message went: `sent`, `steered` or `queued`.
    case delivery(String)
    case thread(UUID)
    case diff(RemoteDiff)
    case usage([RemoteUsage])
    /// A bot the phone saved. Only a phone that asked (`saveBot`) ever gets it.
    case bot(UUID)
    /// The Mac's Settings. Only a phone that asked (`settings`) ever gets it.
    case settings(RemoteSettingsSnapshot)
    /// A preview's pixels. Only a phone that asked (`media`) ever gets it.
    case media(RemoteMediaData)
    /// Suggestions for the composer. Only a phone that asked (`completions`) ever gets them.
    case completions([RemoteCompletion])
    /// A settings document's text. Only a phone that asked (`settingsDocument`, `saveSettingsDocument`) ever gets it.
    case settingsDocument(RemoteSettingsDocument)
    /// A thread's checkout. Only a phone that asked (`checkout`, `changeCheckout`) ever gets it.
    case checkout(RemoteCheckout)
    /// Settings › Usage. Only a phone that asked (`usageDashboard`) ever gets it.
    case usageDashboard(RemoteUsageDashboard)
    /// What "Edit from Here" can do. Only a phone that asked (`rewindOptions`) ever gets it.
    case rewindOptions(RemoteRewindOptions)
    /// The message a rewind removed. Only a phone that asked (`rewind`) ever gets it.
    case rewind(RemoteRewind)
    /// The banner over a composer. Only a phone that asked (`composerNotice`, `usageWarningAction`) ever gets it.
    case composerNotice(RemoteComposerNotice)
    /// A project's defaults. Only a phone that asked (`projectDefaults`, `saveProjectDefaults`) ever gets them.
    case projectDefaults(RemoteProjectDefaults)
    /// The scheduled tasks. Only a phone that asked (`scheduledTasks` and their changes) ever gets them.
    case scheduledTasks(RemoteScheduledTasks)
    /// A folder's git state. Only a phone that asked (`gitState`) ever gets it.
    case gitState(RemoteGitState)
    /// What a git action did. Only a phone that asked (`gitAction`) ever gets it.
    case gitAction(RemoteGitActionResult)
    /// A project's pull requests. Only a phone that asked (`pullRequests`) ever gets them.
    case pullRequests(RemotePullRequestList)
    /// One pull request. Only a phone that asked (`pullRequest`, `pullRequestAction`) ever gets it.
    case pullRequest(RemotePullRequestDetail)

    var name: String {
        switch self {
        case .ok: "ok"
        case .rewindOptions: "rewindOptions"
        case .rewind: "rewind"
        case .composerNotice: "composerNotice"
        case .projectDefaults: "projectDefaults"
        case .scheduledTasks: "scheduledTasks"
        case .gitState: "gitState"
        case .gitAction: "gitAction"
        case .pullRequests: "pullRequests"
        case .pullRequest: "pullRequest"
        case .server: "server"
        case .paired: "paired"
        case .workspace: "workspace"
        case .transcript: "transcript"
        case .items: "items"
        case .delivery: "delivery"
        case .thread: "thread"
        case .diff: "diff"
        case .usage: "usage"
        case .bot: "bot"
        case .settings: "settings"
        case .media: "media"
        case .completions: "completions"
        case .settingsDocument: "settingsDocument"
        case .checkout: "checkout"
        case .usageDashboard: "usageDashboard"
        }
    }
}

/// Changes the Mac sends on its own while the phone is connected.
public enum RemoteEvent: Hashable, Sendable {
    /// The sidebar changed: threads, projects, agents or their state.
    case workspace(RemoteWorkspace)
    /// The theme or another setting the phone follows changed.
    case server(RemoteServerInfo)
    /// Items of an open thread were added or changed. Each carries its index in the whole transcript.
    case items(threadID: UUID, items: [RemoteItem], count: Int)
    /// An open thread's transcript changed in a way that needs reloading (rewound, say).
    case transcript(RemoteTranscript)
    /// An open thread's turn started, finished or its queue changed.
    case turn(threadID: UUID, state: RemoteTurnState)
    /// A thread the phone has open was deleted.
    case threadRemoved(UUID)
    /// The Mac revoked this phone; it should forget its token.
    case revoked
    /// Something the user should hear about, sent only to the phone the Mac decided they're using. An older phone
    /// ignores it, and the Mac never sends it to a phone that hasn't reported its presence.
    case notify(RemoteNotification)
    /// The user saw the thread somewhere: remove what was posted about it.
    case clearNotifications(threadID: UUID)
    /// The Mac's Settings changed, sent only to a phone that asked for them. An older phone ignores it.
    case settings(RemoteSettingsSnapshot)
    /// Whether the user is at the Mac, every half minute: while they are, the phone posts no notifications, which
    /// macOS would show again beside the Mac's own (iPhone Mirroring). An older phone ignores it.
    case macPresence(RemoteMacPresence)

    var name: String {
        switch self {
        case .workspace: "workspace"
        case .server: "server"
        case .items: "items"
        case .transcript: "transcript"
        case .turn: "turn"
        case .threadRemoved: "threadRemoved"
        case .revoked: "revoked"
        case .notify: "notify"
        case .clearNotifications: "clearNotifications"
        case .settings: "settings"
        case .macPresence: "macPresence"
        }
    }
}

public struct RemoteError: Codable, Hashable, Sendable, Error {
    public enum Code: String, Codable, Sendable {
        case unauthorized
        case pairingFailed
        case rateLimited
        case unsupported
        case badRequest
        case notFound
        case notAllowed
        case failed
        /// A save refused because what it changes changed since the phone read it (`saveSettingsDocument`). An older
        /// phone reads it as `unknown`.
        case conflict
        case unknown

        public init(from decoder: Decoder) throws {
            self = Code(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// The Mac's message to a phone.
public enum RemoteServerMessage: Hashable, Sendable, Codable {
    case response(id: String, result: RemoteResult)
    case failure(id: String?, error: RemoteError)
    case event(RemoteEvent)
    /// A result or event of a type this version doesn't know, which the phone ignores.
    case unknown(String)

    private enum CodingKeys: String, CodingKey { case v, re, kind, type, body, error }

    private struct ItemsBody: Codable {
        var threadID: UUID
        var items: [RemoteItem]
        var count: Int
    }

    private struct TurnBody: Codable {
        var threadID: UUID
        var state: RemoteTurnState
    }

    private struct ValueBody<T: Codable>: Codable { var value: T }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .v)
        guard RemoteProtocol.isSupported(version) else { throw RemoteProtocolError.version(version) }
        let kind = try container.decode(String.self, forKey: .kind)
        func body<T: Decodable>(_ type: T.Type) throws -> T { try container.decode(T.self, forKey: .body) }
        switch kind {
        case "error":
            self = .failure(id: try container.decodeIfPresent(String.self, forKey: .re), error: try container.decode(RemoteError.self, forKey: .error))
        case "response":
            let id = try container.decode(String.self, forKey: .re)
            let type = try container.decode(String.self, forKey: .type)
            let result: RemoteResult
            switch type {
            case "ok": result = .ok
            case "server": result = .server(try body(RemoteServerInfo.self))
            case "paired": result = .paired(try body(RemotePairResult.self))
            case "workspace": result = .workspace(try body(RemoteWorkspace.self))
            case "transcript": result = .transcript(try body(RemoteTranscript.self))
            case "items": result = .items(try body(RemoteItemPage.self))
            case "delivery": result = .delivery(try body(ValueBody<String>.self).value)
            case "thread": result = .thread(try body(ValueBody<UUID>.self).value)
            case "diff": result = .diff(try body(RemoteDiff.self))
            case "usage": result = .usage(try body(ValueBody<[RemoteUsage]>.self).value)
            case "bot": result = .bot(try body(ValueBody<UUID>.self).value)
            case "settings": result = .settings(try body(RemoteSettingsSnapshot.self))
            case "media": result = .media(try body(RemoteMediaData.self))
            case "completions": result = .completions(try body(ValueBody<[RemoteCompletion]>.self).value)
            case "settingsDocument": result = .settingsDocument(try body(RemoteSettingsDocument.self))
            case "checkout": result = .checkout(try body(RemoteCheckout.self))
            case "usageDashboard": result = .usageDashboard(try body(RemoteUsageDashboard.self))
            case "rewindOptions": result = .rewindOptions(try body(RemoteRewindOptions.self))
            case "rewind": result = .rewind(try body(RemoteRewind.self))
            case "composerNotice": result = .composerNotice(try body(RemoteComposerNotice.self))
            case "projectDefaults": result = .projectDefaults(try body(RemoteProjectDefaults.self))
            case "scheduledTasks": result = .scheduledTasks(try body(RemoteScheduledTasks.self))
            case "gitState": result = .gitState(try body(RemoteGitState.self))
            case "gitAction": result = .gitAction(try body(RemoteGitActionResult.self))
            case "pullRequests": result = .pullRequests(try body(RemotePullRequestList.self))
            case "pullRequest": result = .pullRequest(try body(RemotePullRequestDetail.self))
            default:
                self = .unknown(type)
                return
            }
            self = .response(id: id, result: result)
        case "event":
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "workspace": self = .event(.workspace(try body(RemoteWorkspace.self)))
            case "server": self = .event(.server(try body(RemoteServerInfo.self)))
            case "items":
                let items = try body(ItemsBody.self)
                self = .event(.items(threadID: items.threadID, items: items.items, count: items.count))
            case "transcript": self = .event(.transcript(try body(RemoteTranscript.self)))
            case "turn":
                let turn = try body(TurnBody.self)
                self = .event(.turn(threadID: turn.threadID, state: turn.state))
            case "threadRemoved": self = .event(.threadRemoved(try body(ValueBody<UUID>.self).value))
            case "revoked": self = .event(.revoked)
            case "notify": self = .event(.notify(try body(RemoteNotification.self)))
            case "macPresence": self = .event(.macPresence(try body(RemoteMacPresence.self)))
            case "clearNotifications": self = .event(.clearNotifications(threadID: try body(ValueBody<UUID>.self).value))
            case "settings": self = .event(.settings(try body(RemoteSettingsSnapshot.self)))
            default: self = .unknown(type)
            }
        default:
            self = .unknown(kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(RemoteProtocol.version, forKey: .v)
        switch self {
        case .failure(let id, let error):
            try container.encode("error", forKey: .kind)
            try container.encodeIfPresent(id, forKey: .re)
            try container.encode(error, forKey: .error)
        case .response(let id, let result):
            try container.encode("response", forKey: .kind)
            try container.encode(id, forKey: .re)
            try container.encode(result.name, forKey: .type)
            switch result {
            case .ok: break
            case .server(let info): try container.encode(info, forKey: .body)
            case .paired(let paired): try container.encode(paired, forKey: .body)
            case .workspace(let workspace): try container.encode(workspace, forKey: .body)
            case .transcript(let transcript): try container.encode(transcript, forKey: .body)
            case .items(let page): try container.encode(page, forKey: .body)
            case .delivery(let delivery): try container.encode(ValueBody(value: delivery), forKey: .body)
            case .thread(let id): try container.encode(ValueBody(value: id), forKey: .body)
            case .diff(let diff): try container.encode(diff, forKey: .body)
            case .usage(let usage): try container.encode(ValueBody(value: usage), forKey: .body)
            case .bot(let id): try container.encode(ValueBody(value: id), forKey: .body)
            case .settings(let snapshot): try container.encode(snapshot, forKey: .body)
            case .media(let media): try container.encode(media, forKey: .body)
            case .completions(let completions): try container.encode(ValueBody(value: completions), forKey: .body)
            case .settingsDocument(let document): try container.encode(document, forKey: .body)
            case .checkout(let checkout): try container.encode(checkout, forKey: .body)
            case .usageDashboard(let dashboard): try container.encode(dashboard, forKey: .body)
            case .rewindOptions(let options): try container.encode(options, forKey: .body)
            case .rewind(let rewind): try container.encode(rewind, forKey: .body)
            case .composerNotice(let notice): try container.encode(notice, forKey: .body)
            case .projectDefaults(let defaults): try container.encode(defaults, forKey: .body)
            case .scheduledTasks(let tasks): try container.encode(tasks, forKey: .body)
            case .gitState(let state): try container.encode(state, forKey: .body)
            case .gitAction(let result): try container.encode(result, forKey: .body)
            case .pullRequests(let list): try container.encode(list, forKey: .body)
            case .pullRequest(let detail): try container.encode(detail, forKey: .body)
            }
        case .event(let event):
            try container.encode("event", forKey: .kind)
            try container.encode(event.name, forKey: .type)
            switch event {
            case .workspace(let workspace): try container.encode(workspace, forKey: .body)
            case .server(let info): try container.encode(info, forKey: .body)
            case .items(let threadID, let items, let count):
                try container.encode(ItemsBody(threadID: threadID, items: items, count: count), forKey: .body)
            case .transcript(let transcript): try container.encode(transcript, forKey: .body)
            case .turn(let threadID, let state): try container.encode(TurnBody(threadID: threadID, state: state), forKey: .body)
            case .threadRemoved(let id): try container.encode(ValueBody(value: id), forKey: .body)
            case .revoked: break
            case .notify(let notification): try container.encode(notification, forKey: .body)
            case .macPresence(let presence): try container.encode(presence, forKey: .body)
            case .clearNotifications(let threadID): try container.encode(ValueBody(value: threadID), forKey: .body)
            case .settings(let snapshot): try container.encode(snapshot, forKey: .body)
            }
        case .unknown(let type):
            try container.encode("unknown", forKey: .kind)
            try container.encode(type, forKey: .type)
        }
    }
}
