import CoincideRemoteKit
import CryptoKit
import Foundation
import Security
import Testing

@testable import Coincide
@testable import CoincideKit

// MARK: Protocol

struct RemoteProtocolTests {
    private func roundTrip(_ message: RemoteClientMessage) throws -> RemoteClientMessage {
        let data = try RemoteProtocol.makeEncoder().encode(message)
        return try RemoteProtocol.makeDecoder().decode(RemoteClientMessage.self, from: data)
    }

    @Test func everyRequestSurvivesEncoding() throws {
        let thread = UUID()
        let item = UUID()
        let requests: [RemoteRequest] = [
            .hello(RemoteHello(deviceID: "d", token: "t", appVersion: "1")),
            .pair(RemotePairRequest(secret: "s", deviceName: "Phone")),
            .ping,
            .workspace(includeArchived: true),
            .openThread(threadID: thread, limit: 50),
            .closeThread(threadID: thread),
            .loadEarlier(threadID: thread, beforeIndex: 40, limit: 20),
            .markSeen(threadID: thread),
            .send(RemoteSendRequest(threadID: thread, text: "hi", images: [RemoteImage(name: "a.jpg", data: Data([1, 2, 3]))], delivery: .alternate)),
            .steerQueued(threadID: thread, messageID: item),
            .removeQueued(threadID: thread, messageID: item),
            .stop(threadID: thread),
            .respond(threadID: thread, itemID: item, optionID: "allow", text: "ok"),
            .answer(threadID: thread, itemID: item, answers: ["q": ["a", "b"]]),
            .dismissQuestion(threadID: thread, itemID: item),
            .updateSettings(RemoteThreadSettings(threadID: thread, provider: "codex", modelID: "m", effort: "high", speed: "standard")),
            .newThread(projectID: nil),
            .newThread(projectID: thread),
            .threadAction(threadID: thread, action: .rename("New")),
            .threadAction(threadID: thread, action: .snooze(Date(timeIntervalSince1970: 1_000))),
            .threadAction(threadID: thread, action: .snooze(nil)),
            .threadAction(threadID: thread, action: .move(projectID: item)),
            .threadAction(threadID: thread, action: .delete),
            .diff(threadID: thread, turnID: item),
            .diff(threadID: thread, turnID: nil),
            .runScript(threadID: thread, scriptID: item),
            .usageLimits,
            .newBotConversation(botID: item),
            .saveBot(RemoteBotDraft(name: "Brulee", avatar: RemoteBotAvatar(.brulee, .rose), persona: "Kind.")),
            .saveBot(
                RemoteBotDraft(
                    id: item, name: "Teddy", avatar: RemoteBotAvatar(.teddy, .caramel), provider: "codex", modelID: "m", effort: "high",
                    accessMode: "fullAccess", interactionMode: "plan")),
            .deleteBot(botID: item, deletesConversations: true),
            .deleteBot(botID: item, deletesConversations: false),
        ]
        for request in requests {
            let decoded = try roundTrip(RemoteClientMessage(id: "1", request: request))
            #expect(decoded.request == request)
            #expect(decoded.id == "1")
        }
    }

    @Test func messagesCarryTheirVersionAndTypeOnTheWire() throws {
        let data = try RemoteProtocol.makeEncoder().encode(RemoteClientMessage(id: "7", request: .stop(threadID: UUID())))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["v"] as? Int == RemoteProtocol.version)
        #expect(json["type"] as? String == "stop")
        #expect(json["id"] as? String == "7")
    }

    @Test func unknownRequestsAndVersionsAreRefused() {
        let unknown = Data(#"{"v":1,"id":"1","type":"launchRockets","body":{}}"#.utf8)
        #expect(throws: RemoteProtocolError.unsupported("launchRockets")) {
            try RemoteProtocol.makeDecoder().decode(RemoteClientMessage.self, from: unknown)
        }
        let future = Data(#"{"v":99,"id":"1","type":"ping"}"#.utf8)
        #expect(throws: RemoteProtocolError.version(99)) {
            try RemoteProtocol.makeDecoder().decode(RemoteClientMessage.self, from: future)
        }
        let missing = Data(#"{"v":1,"id":"1","type":"stop","body":{}}"#.utf8)
        #expect(throws: RemoteProtocolError.missingField("threadID")) {
            try RemoteProtocol.makeDecoder().decode(RemoteClientMessage.self, from: missing)
        }
    }

    @Test func serverMessagesSurviveEncodingAndUnknownOnesAreIgnored() throws {
        let thread = UUID()
        // Dates go over the wire in whole milliseconds.
        let date = Date(timeIntervalSince1970: 1_800_000_000.5)
        let item = RemoteItem(id: UUID(), index: 3, kind: .assistant, text: "Hello", provider: "claude", createdAt: date)
        let summary = RemoteThreadSummary(
            id: thread, projectID: UUID(), title: "T", createdAt: date, updatedAt: date,
            selection: RemoteSelection(provider: "claude", modelID: "m", modelName: "M"))
        let messages: [RemoteServerMessage] = [
            .response(id: "1", result: .ok),
            .response(id: "2", result: .delivery("queued")),
            .response(id: "3", result: .thread(thread)),
            .response(id: "4", result: .transcript(RemoteTranscript(thread: summary, items: [item], hasEarlier: true))),
            .response(id: "5", result: .usage([RemoteUsage(provider: "codex", providerName: "Codex", accountID: "default", windows: [])])),
            .response(id: "5b", result: .bot(thread)),
            .failure(id: "6", error: RemoteError(.notFound, "Gone")),
            .event(.items(threadID: thread, items: [item], count: 4)),
            .event(.turn(threadID: thread, state: RemoteTurnState(isRunning: true, canSteer: true))),
            .event(.threadRemoved(thread)),
            .event(.revoked),
        ]
        for message in messages {
            let data = try RemoteProtocol.makeEncoder().encode(message)
            #expect(try RemoteProtocol.makeDecoder().decode(RemoteServerMessage.self, from: data) == message)
        }
        let newer = Data(#"{"v":1,"kind":"event","type":"hologram","body":{}}"#.utf8)
        #expect(try RemoteProtocol.makeDecoder().decode(RemoteServerMessage.self, from: newer) == .unknown("hologram"))
        // An item kind a newer Mac adds decodes as unknown rather than failing the message.
        var json = try #require(
            try JSONSerialization.jsonObject(with: RemoteProtocol.makeEncoder().encode(item)) as? [String: Any])
        json["kind"] = "hologram"
        let decoded = try RemoteProtocol.makeDecoder().decode(RemoteItem.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.kind == .unknown)
    }

    @Test func pairingCodesRoundTripAndRejectOtherCodes() throws {
        let payload = RemotePairingPayload(
            serverID: "S", name: "Mac", hosts: [RemoteHostCandidate(host: "192.168.1.2", kind: .lan)], port: 47_391,
            fingerprint: String(repeating: "a", count: 64), secret: "secret", expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
        let code = payload.encoded()
        #expect(code.hasPrefix("coincide-remote:pair#"))
        #expect(RemotePairingPayload.decode(code) == payload)
        #expect(RemotePairingPayload.decode("https://example.com") == nil)
        #expect(RemotePairingPayload.decode("coincide-remote:pair#not-base64!") == nil)
    }

    @Test func diffsSplitPerFile() {
        let patch = """
            diff --git a/a.txt b/a.txt
            index 1..2 100644
            --- a/a.txt
            +++ b/a.txt
            @@ -1,2 +1,2 @@
             same
            -old
            +new
            diff --git a/new.swift b/new.swift
            new file mode 100644
            --- /dev/null
            +++ b/new.swift
            @@ -0,0 +1 @@
            +let x = 1
            """
        let diff = RemoteDiffParsing.split(patch, title: "Turn")
        #expect(diff.files.map(\.path) == ["a.txt", "new.swift"])
        #expect(diff.files[0].additions == 1 && diff.files[0].deletions == 1)
        #expect(diff.files[1].status == "added")
        let lines = RemoteDiffParsing.lines(of: diff.files[0].patch)
        #expect(lines.map(\.kind) == [.hunk, .context, .deletion, .addition])
        #expect(lines[3].newLine == 2)
    }

    @Test func tailscaleAddressesAreRecognized() {
        #expect(RemoteAddresses.isTailscale("100.101.102.103"))
        #expect(!RemoteAddresses.isTailscale("100.0.0.1"))
        #expect(!RemoteAddresses.isTailscale("192.168.1.4"))
        let status = Data(#"{"BackendState":"Running","Self":{"DNSName":"mac.tail1234.ts.net."}}"#.utf8)
        #expect(RemoteAddresses.parseTailscaleStatus(status) == "mac.tail1234.ts.net")
        // Only the local network and Tailscale reach the server.
        for allowed in ["127.0.0.1", "192.168.1.4", "10.0.0.7", "172.20.1.1", "100.101.102.103", "169.254.3.4", "::1",
            "fe80::1%en0", "fd7a:115c:a1e0::1", "::ffff:192.168.1.4"]
        {
            #expect(RemoteAddresses.isAllowedPeer(allowed), "\(allowed)")
        }
        for refused in ["8.8.8.8", "172.32.0.1", "100.0.0.1", "2001:4860::8888", "::ffff:8.8.8.8", "garbage"] {
            #expect(!RemoteAddresses.isAllowedPeer(refused), "\(refused)")
        }
        let stopped = Data(#"{"BackendState":"Stopped","Self":{"DNSName":"mac.tail1234.ts.net."}}"#.utf8)
        #expect(RemoteAddresses.parseTailscaleStatus(stopped) == nil)
    }

    @Test func selfSignedCertificatesParseAndVerify() throws {
        let key = P256.Signing.PrivateKey()
        let der = try SelfSignedCertificate.make(
            commonName: "Coincide Remote Test", publicKey: key.publicKey.x963Representation, serial: Data([0x01, 0x02])
        ) { tbs in try key.signature(for: tbs).derRepresentation }
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "Coincide Remote Test")
        let publicKey = try #require(SecCertificateCopyKey(certificate))
        #expect(SecKeyCopyExternalRepresentation(publicKey, nil) as Data? == key.publicKey.x963Representation)
    }
}

// MARK: Pairing

@MainActor
struct RemotePairingTests {
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    @Test func aSecretWorksOnceAndOnlyBeforeItExpires() throws {
        let clock = Clock()
        let storage = MemoryRemoteDeviceStorage()
        let pairing = RemotePairing(storage: storage) { clock.now }
        let secret = pairing.makeSecret()
        let (device, token) = try pairing.pair(secret: secret.value, deviceName: "Phone", peer: "a").get()
        #expect(device.name == "Phone")
        // Single use.
        #expect(throws: RemoteError.self) { try pairing.pair(secret: secret.value, deviceName: "Other", peer: "b").get() }
        // The Mac keeps only the token's hash.
        #expect(storage.devices.count == 1)
        #expect(storage.devices[0].tokenHash == RemoteCrypto.sha256Hex(token))
        #expect(!storage.devices[0].tokenHash.contains(token))

        let late = pairing.makeSecret()
        clock.now += RemotePairing.secretLifetime + 1
        let expired = pairing.pair(secret: late.value, deviceName: "Late", peer: "c")
        #expect(throws: RemoteError.self) { try expired.get() }
        #expect(pairing.devices.count == 1)
    }

    @Test func wrongGuessesUseUpTheSecretAndAreRateLimited() throws {
        let clock = Clock()
        let pairing = RemotePairing(storage: MemoryRemoteDeviceStorage()) { clock.now }
        let secret = pairing.makeSecret()
        for attempt in 0..<RemotePairing.maxFailuresPerSecret {
            _ = pairing.pair(secret: "guess\(attempt)", deviceName: "X", peer: "peer\(attempt)")
        }
        // Thrown away after too many wrong guesses, even the right one fails now.
        #expect(throws: RemoteError.self) { try pairing.pair(secret: secret.value, deviceName: "X", peer: "fresh").get() }

        let limited = RemotePairing(storage: MemoryRemoteDeviceStorage()) { clock.now }
        let good = limited.makeSecret()
        for _ in 0..<RemotePairing.maxFailuresPerWindow { _ = limited.authenticate(deviceID: "nope", token: "nope", peer: "attacker") }
        guard case .failure(let error) = limited.pair(secret: good.value, deviceName: "X", peer: "attacker") else {
            Issue.record("A rate-limited address paired")
            return
        }
        #expect(error.code == .rateLimited)
        // Another address is unaffected, and the window passes.
        #expect(throws: Never.self) { try limited.pair(secret: good.value, deviceName: "X", peer: "phone").get() }
        clock.now += RemotePairing.failureWindow + 1
        #expect(!limited.isLimited("attacker"))
    }

    @Test func tokensAuthenticateUntilRevoked() throws {
        let pairing = RemotePairing(storage: MemoryRemoteDeviceStorage())
        let (device, token) = try pairing.pair(secret: pairing.makeSecret().value, deviceName: "Phone", peer: "a").get()
        #expect(try pairing.authenticate(deviceID: device.id, token: token, peer: "a").get().id == device.id)
        #expect(throws: RemoteError.self) { try pairing.authenticate(deviceID: device.id, token: token + "x", peer: "a").get() }
        pairing.revoke(device.id)
        #expect(throws: RemoteError.self) { try pairing.authenticate(deviceID: device.id, token: token, peer: "a").get() }
    }
}

// MARK: Sessions and the store adapter

@MainActor
final class FakeTransport: RemoteTransport {
    let peer = "test-peer"
    var sent: [RemoteServerMessage] = []
    var isClosed = false

    func send(_ data: Data) {
        if let message = try? RemoteProtocol.makeDecoder().decode(RemoteServerMessage.self, from: data) { sent.append(message) }
    }

    func close() { isClosed = true }

    func events() -> [RemoteEvent] {
        sent.compactMap { if case .event(let event) = $0 { event } else { nil } }
    }

    func result(_ id: String) -> RemoteResult? {
        for message in sent { if case .response(id, let result) = message { return result } }
        return nil
    }

    func error(_ id: String) -> RemoteError? {
        for message in sent { if case .failure(id, let error) = message { return error } }
        return nil
    }
}

@MainActor
struct RemoteSessionTests {
    struct Fixture {
        let folder: TemporaryDirectory
        let store: AppStore
        let adapter: RemoteStoreAdapter
        let pairing: RemotePairing
        let project: Project
        var seen: [UUID] = []
    }

    static func services(store: AppStore) -> RemoteStoreAdapter.Services {
        RemoteStoreAdapter.Services(
            pending: { _ in (0, 0) }, unseen: { _ in nil }, markSeen: { _ in }, markUnread: { _ in }, isSettled: { _ in false },
            isHidden: { _ in false }, archive: { _, _ in }, settle: { _, _ in }, delete: { _ in }, snooze: { _, _ in },
            runScript: { _, _ in }, turnChanges: { _ in [:] }, isPreparingWorktree: { _ in false }, importImage: { _, _ in nil },
            diff: { _, _ in RemoteDiff(title: "None", files: []) }, moveBlocker: { _ in nil },
            move: { [weak store] id, projectID in store?.moveThread(id, to: projectID) }, layout: { .init() })
    }

    func fixture(_ name: String) -> Fixture {
        let folder = TemporaryDirectory(name)
        let store = AppStore(directory: folder.url)
        let registry = ProviderRegistry(store: store, providers: [])
        let runner = ThreadRunner(store: store, registry: registry)
        let adapter = RemoteStoreAdapter(store: store, runner: runner, registry: registry, services: Self.services(store: store))
        let project = store.addProject(at: folder.url)
        return Fixture(folder: folder, store: store, adapter: adapter, pairing: RemotePairing(storage: MemoryRemoteDeviceStorage()), project: project)
    }

    func session(_ fixture: Fixture, _ transport: FakeTransport) -> RemoteSession {
        let session = RemoteSession(transport: transport, adapter: fixture.adapter, pairing: fixture.pairing) {
            RemoteServerInfo(serverID: "server", name: "Mac", appVersion: "1")
        }
        session.start()
        return session
    }

    func send(_ session: RemoteSession, _ request: RemoteRequest, id: String) throws {
        session.receive(try RemoteProtocol.makeEncoder().encode(RemoteClientMessage(id: id, request: request)))
    }

    @Test func requestsBeforeAuthenticationCloseTheConnection() throws {
        let fixture = fixture("remote-unauthenticated")
        let transport = FakeTransport()
        let session = session(fixture, transport)
        try send(session, .workspace(includeArchived: false), id: "1")
        #expect(transport.error("1")?.code == .unauthorized)
        #expect(transport.isClosed)
        #expect(session.state == .closed)
        // Nothing about the Mac's threads went out.
        #expect(transport.result("1") == nil)

        let garbage = FakeTransport()
        let other = self.session(fixture, garbage)
        other.receive(Data("not json".utf8))
        #expect(garbage.isClosed)
    }

    @Test func aWrongTokenIsRejectedAndARightOneAuthenticates() throws {
        let fixture = fixture("remote-hello")
        let (device, token) = try fixture.pairing.pair(secret: fixture.pairing.makeSecret().value, deviceName: "P", peer: "x").get()

        let wrong = FakeTransport()
        try send(session(fixture, wrong), .hello(RemoteHello(deviceID: device.id, token: "forged", appVersion: "1")), id: "h")
        #expect(wrong.error("h")?.code == .unauthorized)
        #expect(wrong.isClosed)

        let right = FakeTransport()
        let session = session(fixture, right)
        try send(session, .hello(RemoteHello(deviceID: device.id, token: token, appVersion: "1")), id: "h")
        guard case .server(let info)? = right.result("h") else {
            Issue.record("No server info")
            return
        }
        #expect(info.serverID == "server")
        #expect(session.deviceID == device.id)
        try send(session, .ping, id: "p")
        #expect(right.result("p") == .ok)
    }

    @Test func pairingThroughASessionIssuesATokenThatWorksLater() throws {
        let fixture = fixture("remote-pair")
        let secret = fixture.pairing.makeSecret()
        let transport = FakeTransport()
        let first = session(fixture, transport)
        try send(first, .pair(RemotePairRequest(secret: secret.value, deviceName: "iPad")), id: "p")
        guard case .paired(let paired)? = transport.result("p") else {
            Issue.record("Not paired")
            return
        }
        #expect(first.deviceID == paired.deviceID)

        let again = FakeTransport()
        let second = session(fixture, again)
        try send(second, .pair(RemotePairRequest(secret: secret.value, deviceName: "Thief")), id: "p")
        #expect(again.error("p")?.code == .pairingFailed)
        #expect(again.isClosed)

        let later = FakeTransport()
        try send(session(fixture, later), .hello(RemoteHello(deviceID: paired.deviceID, token: paired.token, appVersion: "1")), id: "h")
        #expect(later.error("h") == nil)
    }

    private func authenticated(_ fixture: Fixture) throws -> (RemoteSession, FakeTransport) {
        let transport = FakeTransport()
        let session = session(fixture, transport)
        try send(session, .pair(RemotePairRequest(secret: fixture.pairing.makeSecret().value, deviceName: "P")), id: "auth")
        return (session, transport)
    }

    @Test func theWorkspaceAndTranscriptMirrorTheStore() throws {
        let fixture = fixture("remote-snapshot")
        let store = fixture.store
        let thread = store.createThread(in: fixture.project.id)
        store.updateThread(thread.id) {
            $0.title = "Fix the build"
            $0.isPinned = true
        }
        for index in 0..<5 { store.append(TranscriptItem(kind: index == 0 ? .user : .assistant, text: "item \(index)"), to: thread.id) }
        let (session, transport) = try authenticated(fixture)

        try send(session, .workspace(includeArchived: false), id: "w")
        guard case .workspace(let workspace)? = transport.result("w") else {
            Issue.record("No workspace")
            return
        }
        #expect(workspace.projects.contains { $0.id == fixture.project.id })
        let summary = try #require(workspace.threads.first { $0.id == thread.id })
        #expect(summary.title == "Fix the build")
        #expect(summary.isPinned)
        #expect(summary.itemCount == 5)

        try send(session, .openThread(threadID: thread.id, limit: 3), id: "o")
        guard case .transcript(let transcript)? = transport.result("o") else {
            Issue.record("No transcript")
            return
        }
        #expect(transcript.items.map(\.text) == ["item 2", "item 3", "item 4"])
        #expect(transcript.items.map(\.index) == [2, 3, 4])
        #expect(transcript.hasEarlier)

        try send(session, .loadEarlier(threadID: thread.id, beforeIndex: 2, limit: 10), id: "e")
        guard case .items(let page)? = transport.result("e") else {
            Issue.record("No earlier items")
            return
        }
        #expect(page.items.map(\.index) == [0, 1])
        #expect(!page.hasEarlier)

        try send(session, .openThread(threadID: UUID(), limit: 3), id: "missing")
        #expect(transport.error("missing")?.code == .notFound)
    }

    @Test func openThreadsReceiveAppendedChangedAndResetItems() throws {
        let fixture = fixture("remote-updates")
        let store = fixture.store
        let thread = store.createThread(in: fixture.project.id)
        store.append(TranscriptItem(kind: .user, text: "hello"), to: thread.id)
        let other = store.createThread(in: fixture.project.id)
        let (session, transport) = try authenticated(fixture)
        try send(session, .openThread(threadID: thread.id, limit: 50), id: "o")
        transport.sent = []

        // Streaming: an appended reply, then its text growing, arrive as item upserts with their indexes.
        let reply = store.append(TranscriptItem(kind: .assistant, text: "Hi"), to: thread.id)
        store.updateItem(reply, in: thread.id) { $0.text += " there" }
        // Threads the phone hasn't opened don't send items.
        store.append(TranscriptItem(kind: .user, text: "elsewhere"), to: other.id)
        session.flushItems()
        let itemEvents = transport.events().compactMap { event -> [RemoteItem]? in
            if case .items(let id, let items, let count) = event, id == thread.id {
                #expect(count == 2)
                return items
            }
            if case .items = event { Issue.record("Items of an unopened thread were sent") }
            return nil
        }
        #expect(itemEvents.count == 1)
        #expect(itemEvents.first?.map(\.text) == ["Hi there"])
        #expect(itemEvents.first?.first?.index == 1)

        // A rewind resends the transcript.
        transport.sent = []
        store.truncate(thread.id, from: reply)
        session.flushItems()
        let reset = transport.events().compactMap { event -> RemoteTranscript? in
            if case .transcript(let transcript) = event { return transcript }
            return nil
        }
        #expect(reset.first?.items.map(\.text) == ["hello"])

        // The sidebar follows, batched.
        transport.sent = []
        store.updateThread(thread.id) { $0.title = "Renamed" }
        session.flushWorkspace()
        let workspaces = transport.events().compactMap { event -> RemoteWorkspace? in
            if case .workspace(let workspace) = event { return workspace }
            return nil
        }
        #expect(workspaces.last?.threads.first { $0.id == thread.id }?.title == "Renamed")

        // Closed threads stop sending.
        try send(session, .closeThread(threadID: thread.id), id: "c")
        transport.sent = []
        store.append(TranscriptItem(kind: .assistant, text: "after close"), to: thread.id)
        session.flushItems()
        #expect(!transport.events().contains { if case .items = $0 { true } else { false } })
    }

    @Test func actionsChangeTheStoreAsTheMacsControlsDo() throws {
        let fixture = fixture("remote-actions")
        let store = fixture.store
        let thread = store.createThread(in: fixture.project.id)
        let target = store.addProject(at: fixture.folder.url.appendingPathComponent("other", isDirectory: true))
        let (session, transport) = try authenticated(fixture)

        try send(session, .threadAction(threadID: thread.id, action: .rename("  Remote name ")), id: "r")
        try send(session, .threadAction(threadID: thread.id, action: .pin(true)), id: "p")
        try send(session, .updateSettings(RemoteThreadSettings(threadID: thread.id, accessMode: "approval", interactionMode: "plan")), id: "s")
        #expect(store.summary(thread.id)?.title == "Remote name")
        #expect(store.summary(thread.id)?.isPinned == true)
        #expect(store.summary(thread.id)?.accessMode == .approval)
        #expect(store.summary(thread.id)?.interactionMode == .plan)

        try send(session, .updateSettings(RemoteThreadSettings(threadID: thread.id, accessMode: "root")), id: "bad")
        #expect(transport.error("bad")?.code == .badRequest)

        try send(session, .threadAction(threadID: thread.id, action: .move(projectID: target.id)), id: "m")
        #expect(transport.result("m") == .ok)
        #expect(store.summary(thread.id)?.projectID == target.id)

        try send(session, .newThread(projectID: fixture.project.id), id: "n")
        guard case .thread(let created)? = transport.result("n") else {
            Issue.record("No thread")
            return
        }
        #expect(store.summary(created)?.projectID == fixture.project.id)
        // An untouched thread is reused, as on the Mac.
        try send(session, .newThread(projectID: fixture.project.id), id: "n2")
        #expect(transport.result("n2") == .thread(created))

        try send(session, .threadAction(threadID: UUID(), action: .pin(true)), id: "gone")
        #expect(transport.error("gone")?.code == .notFound)
    }

    @Test func theWorkspaceFollowsTheMacSidebarsOrder() {
        let folder = TemporaryDirectory("remote-order")
        let store = AppStore(directory: folder.url)
        let registry = ProviderRegistry(store: store, providers: [])
        var services = Self.services(store: store)
        services.layout = {
            .init(sections: ["chats", "pinned", "projects"], pinned: [], projectSort: .name, threadSort: .name, chatSort: .recentActivity)
        }
        let adapter = RemoteStoreAdapter(
            store: store, runner: ThreadRunner(store: store, registry: registry), registry: registry, services: services)
        let zeta = store.addProject(at: folder.url.appendingPathComponent("zeta", isDirectory: true))
        let alpha = store.addProject(at: folder.url.appendingPathComponent("alpha", isDirectory: true))
        let chats = store.ensureChatsProject()
        for title in ["Charlie", "Alpha", "Bravo"] {
            let id = store.createThread(in: alpha.id).id
            store.updateThread(id) { $0.title = title }
        }
        let pinned = store.createThread(in: zeta.id).id
        store.updateThread(pinned) { $0.isPinned = true }
        let workspace = adapter.workspace()
        #expect(workspace.sections == ["chats", "pinned", "projects"])
        #expect(workspace.projects.map(\.id) == [alpha.id, zeta.id, chats.id])
        #expect(workspace.threads.filter { $0.projectID == alpha.id }.map(\.title) == ["Alpha", "Bravo", "Charlie"])
        #expect(workspace.pinnedOrder == [pinned])
    }

    @Test func aBotFromAnOlderMacDecodesWithoutItsLook() throws {
        let old = #"{"id":"6E3A2B1C-0000-4000-8000-000000000001","name":"Sunny","threadIDs":[]}"#
        let bot = try RemoteProtocol.makeDecoder().decode(RemoteBot.self, from: Data(old.utf8))
        #expect(bot.name == "Sunny")
        #expect(bot.avatar == nil)
        #expect(bot.selection == nil)
        // A look this version doesn't know still draws something.
        let unknown = RemoteBotAvatar(character: "dragon", tint: "glitter")
        #expect(unknown.artCharacter == .alien)
        #expect(unknown.artTint == BotArtwork.Character.alien.defaultTint)
        // The shared names match the ones the Mac saves.
        #expect(BotArtwork.Character.allCases.map(\.rawValue) == BotAvatar.Shape.allCases.map(\.rawValue))
        #expect(BotArtwork.Tint.allCases.map(\.rawValue) == BotAvatar.Tint.allCases.map(\.rawValue))
    }

    @Test func thePhoneCreatesEditsTalksToAndDeletesBots() throws {
        let fixture = fixture("remote-bots")
        let store = fixture.store
        let (session, transport) = try authenticated(fixture)

        try send(session, .saveBot(RemoteBotDraft(name: "  ", avatar: RemoteBotAvatar(.brulee, .rose), persona: "Kind.")), id: "new")
        guard case .bot(let botID)? = transport.result("new"), let created = store.bot(botID) else {
            Issue.record("No bot")
            return
        }
        // An empty name takes the character's own.
        #expect(created.name == "Brulee")
        #expect(created.avatar == BotAvatar(shape: .brulee, tint: .rose))
        #expect(created.persona == "Kind.")
        #expect(created.accessMode == .approval)

        let workspace = fixture.adapter.workspace()
        let remote = try #require(workspace.bots?.first { $0.id == botID })
        #expect(remote.avatar == RemoteBotAvatar(.brulee, .rose))
        #expect(remote.persona == "Kind.")
        #expect(remote.accessMode == "approval")

        try send(session, .newBotConversation(botID: botID), id: "talk")
        guard case .thread(let conversation)? = transport.result("talk") else {
            Issue.record("No conversation")
            return
        }
        #expect(store.bot(forThread: conversation)?.id == botID)
        // An untouched conversation is reused, as on the Mac.
        try send(session, .newBotConversation(botID: botID), id: "talk2")
        #expect(transport.result("talk2") == .thread(conversation))

        try send(
            session,
            .saveBot(RemoteBotDraft(id: botID, name: "Brulee B", avatar: RemoteBotAvatar(.teddy, .sky), persona: "Brief.", accessMode: "fullAccess")),
            id: "edit")
        #expect(transport.result("edit") == .bot(botID))
        #expect(store.bot(botID)?.name == "Brulee B")
        #expect(store.bot(botID)?.avatar == BotAvatar(shape: .teddy, tint: .sky))
        #expect(store.bot(botID)?.accessMode == .fullAccess)
        // The untouched conversation follows the new access, as the Mac's editor does.
        #expect(store.summary(conversation)?.accessMode == .fullAccess)

        // A draft this Mac can't honor changes nothing.
        try send(session, .saveBot(RemoteBotDraft(id: botID, name: "X", avatar: RemoteBotAvatar(character: "dragon", tint: "rose"))), id: "bad")
        #expect(transport.error("bad")?.code == .badRequest)
        try send(session, .saveBot(RemoteBotDraft(id: botID, name: "X", avatar: RemoteBotAvatar(.star, .sky), accessMode: "root")), id: "bad2")
        #expect(transport.error("bad2")?.code == .badRequest)
        #expect(store.bot(botID)?.name == "Brulee B")

        try send(session, .deleteBot(botID: botID, deletesConversations: false), id: "delete")
        #expect(transport.result("delete") == .ok)
        #expect(store.bot(botID) == nil)
        // Its conversation stays, as a chat.
        #expect(store.summary(conversation) != nil)
        try send(session, .newBotConversation(botID: botID), id: "gone")
        #expect(transport.error("gone")?.code == .notFound)
    }

    @Test func secretAnswersAndLongToolOutputStayOnTheMac() {
        let question = UserInputRequest(id: "r", questions: [UserQuestion(id: "pw", prompt: "Password?", isSecret: true)])
        let item = TranscriptItem(kind: .question, questions: question, answers: ["pw": ["hunter2"]])
        let remote = RemoteStoreAdapter.item(item, index: 0)
        #expect(remote.answers?["pw"] != ["hunter2"])

        let tool = TranscriptItem(kind: .tool, text: String(repeating: "x", count: 50_000), title: "cat big", category: .command)
        let clipped = RemoteStoreAdapter.item(tool, index: 1)
        #expect(clipped.isClipped)
        #expect(clipped.text.count < 7_000)
    }
}
