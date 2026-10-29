import CloudKit
import CoincideRemoteKit
import Foundation
import Testing

@testable import Coincide
@testable import CoincideKit

// MARK: Routing

@MainActor
struct NotificationRoutingTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let thread = UUID()
    let other = UUID()

    /// The Mac: in front or not, seconds since input, the thread on screen.
    func mac(_ appActive: Bool = true, idle: TimeInterval, showing: UUID? = nil) -> MacActivity {
        MacActivity(isAppActive: appActive, idleSeconds: idle, visibleThreadID: showing)
    }

    func phone(
        _ state: RemotePresence.State = .active, id: String = "phone", open: UUID? = nil, idle: TimeInterval = 5,
        heardAgo: TimeInterval = 1
    ) -> DevicePresence {
        DevicePresence(
            deviceID: id, presence: RemotePresence(state: state, openThreadID: open, idleSeconds: idle),
            receivedAt: now.addingTimeInterval(-heardAgo))
    }

    func target(_ id: String = "phone", activeAgo: TimeInterval = 600) -> PushTarget {
        PushTarget(deviceID: id, zone: "alerts-\(id)", lastActiveAt: now.addingTimeInterval(-activeAgo))
    }

    @Test func theRoutingTable() {
        let away: TimeInterval = 600
        let here: TimeInterval = 10
        let cases: [(String, MacActivity, [DevicePresence], [PushTarget], Bool, NotificationRoute)] = [
            // The Mac in use: as before Coincide Remote.
            ("Mac active, no phone", mac(idle: here), [], [], true, .mac),
            ("Mac active, showing the thread", mac(idle: here, showing: thread), [], [], true, .none),
            ("Mac active in another app", mac(false, idle: here, showing: thread), [], [], true, .mac),
            ("Mac active, phone in the background", mac(idle: here), [phone(.background)], [], true, .mac),
            ("Mac active, lock-screen alerts on", mac(idle: here), [], [target()], true, .mac),
            // The Mac idle, the phone in front: the phone, unless it shows the thread.
            ("Mac idle, phone in front", mac(idle: away), [phone()], [], true, .device("phone")),
            ("Mac idle, phone shows the thread", mac(idle: away), [phone(open: thread)], [], true, .none),
            ("Mac idle, phone shows another thread", mac(idle: away), [phone(open: other)], [], true, .device("phone")),
            ("Mac idle but showing the thread, phone in front", mac(idle: away, showing: thread), [phone()], [], true,
                .device("phone")),
            ("Mac idle, phone in front with alerts on", mac(idle: away), [phone()], [target()], true, .device("phone")),
            ("Mac idle, phone in front showing the thread, alerts on", mac(idle: away), [phone(open: thread)], [target()],
                true, .none),
            // The Mac idle, no phone in front: the Mac, or the lock screen when turned on.
            ("Mac idle, phone in the background", mac(idle: away), [phone(.background)], [], true, .mac),
            ("Mac idle, phone inactive", mac(idle: away), [phone(.inactive)], [], true, .mac),
            ("Mac idle, phone disconnected", mac(idle: away), [], [], true, .mac),
            ("Mac idle, phone's presence went stale", mac(idle: away), [phone(heardAgo: RemotePresence.lifetime + 5)], [],
                true, .mac),
            ("Mac idle showing the thread, no phone", mac(idle: away, showing: thread), [], [], true, .none),
            ("Mac idle, phone locked with alerts on", mac(idle: away), [phone(.background)], [target()], true,
                .push(target())),
            ("Mac idle, phone disconnected with alerts on", mac(idle: away), [], [target()], true, .push(target())),
            ("Mac idle, alerts on but no CloudKit on this Mac", mac(idle: away), [], [target()], false, .mac),
            ("Mac idle, alerts on but phone unused for hours", mac(idle: away), [],
                [target(activeAgo: NotificationRouting.pushRecency + 60)], true, .mac),
            // Both in use: whichever was touched last.
            ("Both active, phone touched last", mac(idle: 30), [phone(idle: 2)], [], true, .device("phone")),
            ("Both active, Mac touched last", mac(idle: 2), [phone(idle: 30)], [], true, .mac),
            ("Both active, Mac touched last and showing the thread", mac(idle: 2, showing: thread), [phone(idle: 30)], [],
                true, .none),
            ("Two phones in front, the newer wins", mac(idle: away), [phone(id: "phone", idle: 40), phone(id: "ipad", idle: 3)], [],
                true, .device("ipad")),
        ]
        for (name, mac, devices, targets, pushAvailable, expected) in cases {
            let route = NotificationRouting.route(
                threadID: thread, mac: mac, devices: devices, pushTargets: targets, pushAvailable: pushAvailable, now: now)
            #expect(route == expected, "\(name)")
        }
    }

    @Test func theCloudKitDecisionPicksARecentPhoneThatIsNotInFront() {
        let older = target("old", activeAgo: 3_600)
        let newer = target("new", activeAgo: 60)
        #expect(NotificationRouting.pushTarget([older, newer], connected: [], pushAvailable: true, now: now) == newer)
        // The phone in front gets it live instead, so CloudKit picks the other.
        #expect(NotificationRouting.pushTarget([older, newer], connected: [phone(id: "new")], pushAvailable: true, now: now) == older)
        // A backgrounded connection doesn't count as in front.
        #expect(
            NotificationRouting.pushTarget([newer], connected: [phone(.background, id: "new")], pushAvailable: true, now: now)
                == newer)
        #expect(NotificationRouting.pushTarget([newer], connected: [], pushAvailable: false, now: now) == nil)
        #expect(NotificationRouting.pushTarget([], connected: [], pushAvailable: true, now: now) == nil)
        var noZone = newer
        noZone.zone = ""
        #expect(NotificationRouting.pushTarget([noZone], connected: [], pushAvailable: true, now: now) == nil)
        let stale = target("stale", activeAgo: NotificationRouting.pushRecency + 1)
        #expect(NotificationRouting.pushTarget([stale], connected: [], pushAvailable: true, now: now) == nil)
    }

    @Test func lockScreenAlertsAreOffUntilTurnedOn() throws {
        let suite = "CoincideTests-alerts-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!RemoteAlerts.lockScreenAlertsEnabled(in: defaults))
        defaults.set(true, forKey: RemoteAlerts.lockScreenAlertsKey)
        #expect(RemoteAlerts.lockScreenAlertsEnabled(in: defaults))
        // A phone that says nothing about them reports them off, so the Mac never writes one.
        #expect(RemotePresence(state: .active).alertZone == nil)
        let decoded = try RemoteProtocol.makeDecoder().decode(
            RemotePresence.self, from: Data(#"{"state":"active","idleSeconds":3}"#.utf8))
        #expect(decoded.alertZone == nil)
        // A Mac that never heard from a phone knows no phone to alert.
        let folder = TemporaryDirectory("alerts-default")
        #expect(RemoteServer(directory: folder.url).alertTargets.isEmpty)
    }

    @Test func presenceUsesTheMacsClockForTheLastTouch() {
        let presence = DevicePresence(
            deviceID: "p", presence: RemotePresence(state: .active, idleSeconds: 42), receivedAt: now)
        #expect(presence.lastInteraction == now.addingTimeInterval(-42))
        #expect(presence.isForeground(at: now.addingTimeInterval(RemotePresence.lifetime)))
        #expect(!presence.isForeground(at: now.addingTimeInterval(RemotePresence.lifetime + 1)))
    }
}

// MARK: Protocol

struct NotificationProtocolTests {
    @Test func presenceAndAlertsSurviveEncoding() throws {
        let thread = UUID()
        let presence = RemotePresence(state: .inactive, openThreadID: thread, idleSeconds: 12.5, alertZone: "alerts-x")
        let data = try RemoteProtocol.makeEncoder().encode(RemoteClientMessage(id: "p", request: .presence(presence)))
        #expect(try RemoteProtocol.makeDecoder().decode(RemoteClientMessage.self, from: data).request == .presence(presence))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "presence")
        #expect(json["v"] as? Int == 1)

        let alert = RemoteNotification(
            id: RemoteAlerts.eventID(threadID: thread, kind: .approval, itemID: UUID()), threadID: thread, kind: .approval,
            title: "Fix the build", subtitle: "Codex needs approval in coincide", body: "Run tests")
        for message: RemoteServerMessage in [.event(.notify(alert)), .event(.clearNotifications(threadID: thread))] {
            let encoded = try RemoteProtocol.makeEncoder().encode(message)
            #expect(try RemoteProtocol.makeDecoder().decode(RemoteServerMessage.self, from: encoded) == message)
        }
        #expect(RemoteAlerts.threadID(ofEvent: alert.id) == thread)
        #expect(RemoteAlerts.collapseID(eventID: alert.id).utf8.count <= 64)
    }

    @Test func olderAndNewerPeersKeepWorking() throws {
        let decoder = RemoteProtocol.makeDecoder()
        // A Mac older than routing sends no `notifies`.
        let info = try decoder.decode(
            RemoteServerInfo.self,
            from: Data(
                #"{"serverID":"s","name":"Mac","appVersion":"1","protocolVersion":1,"theme":{"appearance":"system","darkThemeID":"carbon","lightThemeID":"carbon-light"},"showsReasoning":true,"followUpBehavior":"steer"}"#
                    .utf8))
        #expect(info.notifies == nil)
        // States and kinds a newer peer adds read as unknown instead of failing the message.
        let presence = try decoder.decode(RemotePresence.self, from: Data(#"{"state":"dreaming","idleSeconds":1}"#.utf8))
        #expect(presence.state == .unknown)
        #expect(!DevicePresence(deviceID: "d", presence: presence, receivedAt: Date()).isForeground(at: Date()))
        let thread = UUID()
        let kind = try decoder.decode(
            RemoteNotification.self,
            from: Data(#"{"id":"x","threadID":"\#(thread.uuidString)","kind":"hologram","title":"T","subtitle":"S"}"#.utf8))
        #expect(kind.kind == .unknown)
        // An event type this phone lacks is ignored, which is what an older phone does with `notify`.
        let newer = Data(#"{"v":1,"kind":"event","type":"notifyLater","body":{"id":"x"}}"#.utf8)
        #expect(try decoder.decode(RemoteServerMessage.self, from: newer) == .unknown("notifyLater"))
    }
}

// MARK: Ledger, dispatch and CloudKit fallback

@MainActor
final class FakePusher: AlertPusher {
    var isAvailable = true
    /// Thrown by the next saves, in order.
    var errors: [Error] = []
    var attempts: [PushAlert] = []
    var deleted: [PushAlert] = []

    func save(_ alert: PushAlert) async throws {
        attempts.append(alert)
        if !errors.isEmpty { throw errors.removeFirst() }
    }

    func delete(_ alerts: [PushAlert]) async throws { deleted += alerts }
}

@MainActor
final class DispatchWorld {
    var enabled = true
    var mac = MacActivity(isAppActive: false, idleSeconds: 600, visibleThreadID: nil)
    var devices: [DevicePresence] = []
    var targets: [PushTarget] = []
    var liveSucceeds = true
    var macPosts: [String] = []
    var live: [(String, String)] = []
    var sleeps: [TimeInterval] = []
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func dispatcher(ledger: NotificationLedger, pusher: FakePusher? = nil, onSleep: (() -> Void)? = nil) -> NotificationDispatcher {
        let push = pusher.map {
            PushAlertDelivery(pusher: $0, url: nil, now: { [now] in now }) { [weak self] delay in
                self?.sleeps.append(delay)
                onSleep?()
            }
        }
        return NotificationDispatcher(
            ledger: ledger, push: push,
            environment: NotificationDispatcher.Environment(
                isEnabled: { [unowned self] in self.enabled }, macActivity: { [unowned self] in self.mac },
                devices: { [unowned self] in self.devices }, pushTargets: { [unowned self] in self.targets },
                postMac: { [unowned self] in self.macPosts.append($0.id) },
                sendLive: { [unowned self] notification, device in
                    guard self.liveSucceeds else { return false }
                    self.live.append((notification.id, device))
                    return true
                }, now: { [now] in now }))
    }

    func phone(_ state: RemotePresence.State = .active, open: UUID? = nil) -> DevicePresence {
        DevicePresence(deviceID: "phone", presence: RemotePresence(state: state, openThreadID: open, idleSeconds: 1), receivedAt: now)
    }

    func alertTarget() -> PushTarget { PushTarget(deviceID: "phone", zone: "alerts-phone", lastActiveAt: now.addingTimeInterval(-60)) }
}

@MainActor
struct NotificationDispatchTests {
    let thread = UUID()

    func alert(_ item: UUID = UUID(), kind: RemoteNotification.Kind = .completed) -> AlertContent {
        AlertContent(
            id: RemoteAlerts.eventID(threadID: thread, kind: kind, itemID: item), threadID: thread, kind: kind, title: "T",
            subtitle: "Codex finished", body: "Done")
    }

    @Test func theLedgerRemembersAcrossRelaunchesForADay() {
        let folder = TemporaryDirectory("ledger")
        let url = folder.url.appendingPathComponent("notified-events.json")
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let ledger = NotificationLedger(url: url) { clock }
        #expect(ledger.claim("a"))
        #expect(!ledger.claim("a"))
        // Relaunched: the file still has it.
        #expect(!NotificationLedger(url: url) { clock }.claim("a"))
        clock += NotificationLedger.lifetime + 1
        #expect(NotificationLedger(url: url) { clock }.claim("a"))
    }

    @Test func eachEventGoesToExactlyOnePlaceOnce() {
        let world = DispatchWorld()
        let pusher = FakePusher()
        let dispatcher = world.dispatcher(ledger: NotificationLedger(url: nil), pusher: pusher)
        let event = alert()
        world.devices = [world.phone()]
        #expect(dispatcher.dispatch(event) == .device("phone"))
        // The same event again, through any path and whatever changed since: nothing more.
        world.devices = []
        world.targets = [world.alertTarget()]
        #expect(dispatcher.dispatch(event) == nil)
        world.mac.idleSeconds = 1
        #expect(dispatcher.dispatch(event) == nil)
        #expect(world.live.map(\.0) == [event.id])
        #expect(world.macPosts.isEmpty)
        #expect(pusher.attempts.isEmpty)
        // A different event is its own.
        #expect(dispatcher.dispatch(alert()) == .mac)
        #expect(world.macPosts.count == 1)
    }

    @Test func aReplayAfterReconnectingOrRelaunchingDoesNotAlertAgain() {
        let folder = TemporaryDirectory("replay")
        let url = folder.url.appendingPathComponent("notified-events.json")
        let world = DispatchWorld()
        let event = alert()
        world.devices = [world.phone()]
        #expect(world.dispatcher(ledger: NotificationLedger(url: url)).dispatch(event) == .device("phone"))
        // The phone reconnects with a new session and the transcript replays the event.
        world.devices = [world.phone()]
        let relaunched = world.dispatcher(ledger: NotificationLedger(url: url))
        #expect(relaunched.dispatch(event) == nil)
        #expect(world.live.count == 1)
        #expect(world.macPosts.isEmpty)
    }

    @Test func aConnectionLostWhileSendingFallsBackToTheMacOnce() {
        let world = DispatchWorld()
        let dispatcher = world.dispatcher(ledger: NotificationLedger(url: nil))
        let event = alert()
        world.devices = [world.phone()]
        world.liveSucceeds = false
        #expect(dispatcher.dispatch(event) == .device("phone"))
        #expect(world.macPosts == [event.id])
        // Back online: no second copy.
        world.liveSucceeds = true
        #expect(dispatcher.dispatch(event) == nil)
        #expect(world.live.isEmpty)
        #expect(world.macPosts.count == 1)
    }

    @Test func notificationsOffSendsNothing() {
        let world = DispatchWorld()
        world.enabled = false
        world.devices = [world.phone()]
        #expect(world.dispatcher(ledger: NotificationLedger(url: nil)).dispatch(alert()) == nil)
        #expect(world.live.isEmpty && world.macPosts.isEmpty)
    }

    @Test func aPermanentCloudKitFailureFallsBackToTheMacOnce() async {
        let world = DispatchWorld()
        world.targets = [world.alertTarget()]
        let pusher = FakePusher()
        pusher.errors = [CKError(.notAuthenticated)]
        let dispatcher = world.dispatcher(ledger: NotificationLedger(url: nil), pusher: pusher)
        let event = alert()
        #expect(dispatcher.dispatch(event) == .push(world.alertTarget()))
        await dispatcher.push?.waitUntilIdle()
        #expect(pusher.attempts.count == 1)
        #expect(world.macPosts == [event.id])
        #expect(world.sleeps.isEmpty)
        #expect(dispatcher.dispatch(event) == nil)
        #expect(world.macPosts.count == 1)
    }

    @Test func passingCloudKitFailuresRetryABoundedNumberOfTimes() async {
        let world = DispatchWorld()
        world.targets = [world.alertTarget()]
        let pusher = FakePusher()
        pusher.errors = Array(repeating: CKError(.networkFailure), count: 5)
        let dispatcher = world.dispatcher(ledger: NotificationLedger(url: nil), pusher: pusher)
        let event = alert()
        dispatcher.dispatch(event)
        await dispatcher.push?.waitUntilIdle()
        #expect(pusher.attempts.count == 3)
        #expect(world.sleeps == [2, 4])
        #expect(world.macPosts == [event.id])

        // CloudKit asks to wait; once it works, the Mac stays quiet.
        let limited = FakePusher()
        limited.errors = [CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 7.0])]
        let next = world.dispatcher(ledger: NotificationLedger(url: nil), pusher: limited)
        world.sleeps = []
        next.dispatch(alert())
        await next.push?.waitUntilIdle()
        #expect(world.sleeps == [7])
        #expect(limited.attempts.count == 2)
        #expect(world.macPosts.count == 1)
        #expect(next.push?.written.count == 1)
    }

    @Test func anAlertAlreadyInCloudKitCountsAsDelivered() async {
        let world = DispatchWorld()
        world.targets = [world.alertTarget()]
        let pusher = FakePusher()
        pusher.errors = [CKError(.serverRecordChanged)]
        let dispatcher = world.dispatcher(ledger: NotificationLedger(url: nil), pusher: pusher)
        dispatcher.dispatch(alert())
        await dispatcher.push?.waitUntilIdle()
        #expect(world.macPosts.isEmpty)
        #expect(dispatcher.push?.written.count == 1)
    }

    @Test func thePhoneComingToTheFrontAfterACloudKitWriteGetsNoSecondAlert() async {
        let world = DispatchWorld()
        world.targets = [world.alertTarget()]
        let pusher = FakePusher()
        let dispatcher = world.dispatcher(ledger: NotificationLedger(url: nil), pusher: pusher)
        let event = alert()
        #expect(dispatcher.dispatch(event) == .push(world.alertTarget()))
        // The phone unlocks at once and connects; the event replays as it catches up.
        world.devices = [world.phone()]
        #expect(dispatcher.dispatch(event) == nil)
        await dispatcher.push?.waitUntilIdle()
        // Later the user comes back to the Mac: nothing stale appears there either.
        world.devices = []
        world.mac = MacActivity(isAppActive: true, idleSeconds: 1, visibleThreadID: nil)
        #expect(dispatcher.dispatch(event) == nil)
        #expect(pusher.attempts.count == 1)
        #expect(world.live.isEmpty)
        #expect(world.macPosts.isEmpty)
        // Opening the thread removes the written alert.
        dispatcher.threadSeen(thread)
        #expect(dispatcher.push?.written.isEmpty == true)
        for _ in 0..<50 where pusher.deleted.isEmpty { await Task.yield() }
        #expect(pusher.deleted.map(\.eventID) == [event.id])
    }

    @Test func seeingTheThreadDuringRetriesCancelsTheFallback() async {
        let world = DispatchWorld()
        world.targets = [world.alertTarget()]
        let pusher = FakePusher()
        pusher.errors = Array(repeating: CKError(.serviceUnavailable), count: 5)
        var dispatcher: NotificationDispatcher!
        dispatcher = world.dispatcher(ledger: NotificationLedger(url: nil), pusher: pusher) { [thread] in
            dispatcher.threadSeen(thread)
        }
        dispatcher.dispatch(alert())
        await dispatcher.push?.waitUntilIdle()
        for _ in 0..<5 { await Task.yield() }
        #expect(pusher.attempts.count == 1)
        #expect(world.macPosts.isEmpty)
    }

    @Test func failuresAreClassified() {
        #expect(PushFailure.classify(CKError(.serverRecordChanged)) == .alreadyDelivered)
        #expect(PushFailure.classify(CKError(.networkUnavailable)) == .transient(retryAfter: nil))
        #expect(PushFailure.classify(CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 3.0])) == .transient(retryAfter: 3))
        for code in [CKError.Code.notAuthenticated, .quotaExceeded, .permissionFailure, .zoneNotFound, .missingEntitlement] {
            #expect(PushFailure.classify(CKError(code)) == .permanent, "\(code)")
        }
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: ["r": CKError(.requestRateLimited)]])
        #expect(PushFailure.classify(partial) == .transient(retryAfter: nil))
        #expect(PushFailure.classify(URLError(.timedOut)) == .transient(retryAfter: nil))
        #expect(PushFailure.classify(CocoaError(.fileNoSuchFile)) == .permanent)
    }

    @Test func lockScreenAlertsKeepToAShortLine() {
        let long = AlertContent(
            id: "e", threadID: thread, kind: .completed, title: "T", subtitle: "S", body: String(repeating: "x", count: 500))
        let alert = PushAlert(long, zone: "z", createdAt: Date())
        #expect(alert.body.count == PushAlert.maxBody)
        // No detail: what happened becomes the body.
        let bare = PushAlert(AlertContent(id: "e", threadID: thread, kind: .completed, title: "T", subtitle: "S"), zone: "z", createdAt: Date())
        #expect(bare.body == "S" && bare.subtitle.isEmpty)
    }
}

// MARK: Sessions

@MainActor
struct NotificationSessionTests {
    final class Seen {
        var ids: [UUID] = []
    }

    struct Fixture {
        let folder: TemporaryDirectory
        let store: AppStore
        let adapter: RemoteStoreAdapter
        let pairing: RemotePairing
        let project: Project
        let seen: Seen
    }

    func fixture(_ name: String) -> Fixture {
        let folder = TemporaryDirectory(name)
        let store = AppStore(directory: folder.url)
        let registry = ProviderRegistry(store: store, providers: [])
        let runner = ThreadRunner(store: store, registry: registry)
        let seen = Seen()
        var services = RemoteSessionTests.services(store: store)
        services.markSeen = { seen.ids.append($0) }
        let adapter = RemoteStoreAdapter(store: store, runner: runner, registry: registry, services: services)
        return Fixture(
            folder: folder, store: store, adapter: adapter, pairing: RemotePairing(storage: MemoryRemoteDeviceStorage()),
            project: store.addProject(at: folder.url), seen: seen)
    }

    func connect(_ fixture: Fixture) throws -> (RemoteSession, FakeTransport) {
        let transport = FakeTransport()
        let session = RemoteSession(transport: transport, adapter: fixture.adapter, pairing: fixture.pairing) {
            RemoteServerInfo(serverID: "server", name: "Mac", appVersion: "1")
        }
        session.start()
        try send(session, .pair(RemotePairRequest(secret: fixture.pairing.makeSecret().value, deviceName: "P")), id: "auth")
        return (session, transport)
    }

    func send(_ session: RemoteSession, _ request: RemoteRequest, id: String) throws {
        session.receive(try RemoteProtocol.makeEncoder().encode(RemoteClientMessage(id: id, request: request)))
    }

    func clears(_ transport: FakeTransport) -> [UUID] {
        transport.events().compactMap { if case .clearNotifications(let id) = $0 { id } else { nil } }
    }

    @Test func seeingAThreadClearsItOnEveryPhone() throws {
        let fixture = fixture("notify-clear")
        let thread = fixture.store.createThread(in: fixture.project.id)
        let (phone, phoneWire) = try connect(fixture)
        let (tablet, tabletWire) = try connect(fixture)
        let (_, oldWire) = try connect(fixture)
        try send(phone, .presence(RemotePresence(state: .background)), id: "p1")
        try send(tablet, .presence(RemotePresence(state: .active, idleSeconds: 3)), id: "p2")
        #expect(phoneWire.result("p1") == .ok)

        fixture.adapter.clearNotifications(thread.id)
        #expect(clears(phoneWire) == [thread.id])
        #expect(clears(tabletWire) == [thread.id])
        // A phone older than routing never reported presence and gets none of it.
        #expect(clears(oldWire).isEmpty)
    }

    @Test func aThreadOpenOnAPhoneInFrontCountsAsSeen() throws {
        let fixture = fixture("notify-seen")
        let thread = fixture.store.createThread(in: fixture.project.id)
        let next = fixture.store.createThread(in: fixture.project.id)
        let (phone, _) = try connect(fixture)
        // Opening a thread marks it seen, which on the Mac clears its notifications everywhere.
        try send(phone, .markSeen(threadID: thread.id), id: "m")
        #expect(fixture.seen.ids == [thread.id])
        try send(phone, .presence(RemotePresence(state: .active, openThreadID: thread.id)), id: "p1")
        #expect(fixture.seen.ids == [thread.id, thread.id])
        // Heartbeats with the same thread don't repeat it; a different thread or coming back to the front does.
        try send(phone, .presence(RemotePresence(state: .active, openThreadID: thread.id)), id: "p2")
        #expect(fixture.seen.ids.count == 2)
        try send(phone, .presence(RemotePresence(state: .active, openThreadID: next.id)), id: "p3")
        try send(phone, .presence(RemotePresence(state: .background, openThreadID: nil)), id: "p4")
        try send(phone, .presence(RemotePresence(state: .active, openThreadID: next.id)), id: "p5")
        #expect(fixture.seen.ids == [thread.id, thread.id, next.id, next.id])
    }

    @Test func alertsGoOnlyToPhonesThatReportedPresence() throws {
        let fixture = fixture("notify-deliver")
        let (phone, wire) = try connect(fixture)
        let thread = UUID()
        let alert = RemoteNotification(
            id: RemoteAlerts.eventID(threadID: thread, kind: .question, itemID: UUID()), threadID: thread, kind: .question,
            title: "T", subtitle: "Claude has a question")
        #expect(!phone.deliver(alert))
        try send(phone, .presence(RemotePresence(state: .active, idleSeconds: 2, alertZone: "alerts-1")), id: "p")
        let presence = try #require(phone.presence)
        #expect(presence.state == .active)
        #expect(phone.deliver(alert))
        #expect(wire.events().contains(.notify(alert)))
        phone.close()
        #expect(!phone.deliver(alert))
    }

    @Test func anUnknownRequestIsRefusedWithoutHangingUp() throws {
        // What an older Mac does with `presence`: the phone ignores the refusal and carries on.
        let fixture = fixture("notify-unknown")
        let (session, wire) = try connect(fixture)
        session.receive(Data(#"{"v":1,"id":"x","type":"presenceV2","body":{}}"#.utf8))
        #expect(wire.error("x")?.code == .unsupported)
        #expect(!wire.isClosed)
        try send(session, .ping, id: "ping")
        #expect(wire.result("ping") == .ok)
    }
}
