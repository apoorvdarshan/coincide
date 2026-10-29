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
/// and an older Mac, or the reverse, keep working with what they share.
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
        case .ping, .usageLimits: return
        case .workspace(let includeArchived): f.includeArchived = includeArchived
        case .openThread(let threadID, let limit):
            f.threadID = threadID
            f.limit = limit
        case .closeThread(let threadID), .markSeen(let threadID), .stop(let threadID): f.threadID = threadID
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

    var name: String {
        switch self {
        case .ok: "ok"
        case .server: "server"
        case .paired: "paired"
        case .workspace: "workspace"
        case .transcript: "transcript"
        case .items: "items"
        case .delivery: "delivery"
        case .thread: "thread"
        case .diff: "diff"
        case .usage: "usage"
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

    var name: String {
        switch self {
        case .workspace: "workspace"
        case .server: "server"
        case .items: "items"
        case .transcript: "transcript"
        case .turn: "turn"
        case .threadRemoved: "threadRemoved"
        case .revoked: "revoked"
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
            }
        case .unknown(let type):
            try container.encode("unknown", forKey: .kind)
            try container.encode(type, forKey: .type)
        }
    }
}
