import CloudKit
import CoincideRemoteKit
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// Alerts from the Mac on this phone.
///
/// While the app is in front and the Mac's user is away, the Mac sends alerts over the connection (`notify`): they
/// show as a banner in the app and stay in Notification Center until the thread is seen anywhere (`clearNotifications`).
/// With "Notify this iPhone when it's locked" on, the Mac can also write an alert to the user's private CloudKit
/// database while the phone is locked or the app is suspended; the subscription set up here makes iOS show it.
///
/// Every alert carries the event's id, the identifier of its notification here, and the ids already shown are kept
/// for a day, so an event never shows twice, whichever way it came.
@MainActor
@Observable
final class PhoneAlerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PhoneAlerts()

    enum LockScreenStatus: Equatable {
        case off
        case settingUp
        case on
        /// Notifications are turned off for Coincide Remote in Settings.
        case notificationsDenied
        /// No iCloud account, or CloudKit can't be reached; the message says which.
        case unavailable(String)
    }

    /// The alert on screen as a banner.
    var banner: RemoteNotification?
    private(set) var authorization = UNAuthorizationStatus.notDetermined
    private(set) var lockScreenStatus = LockScreenStatus.off
    /// The user's "Notify this iPhone when it's locked" setting. Off by default.
    private(set) var isLockScreenEnabled = RemoteAlerts.lockScreenAlertsEnabled(in: .standard)

    /// Opens a thread, when an alert is tapped.
    @ObservationIgnored var openThread: ((UUID) -> Void)? {
        didSet {
            if let pendingOpen, let openThread {
                self.pendingOpen = nil
                openThread(pendingOpen)
            }
        }
    }
    /// The thread on screen while the app is in front. Alerts about it are dropped.
    @ObservationIgnored var visibleThread: () -> UUID? = { nil }
    /// The app's scene phase, as reported to the Mac.
    @ObservationIgnored var phase = RemotePresence.State.background
    var isForeground: Bool { phase == .active }
    /// Called when what the phone reports to the Mac changed: whether lock-screen alerts work.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var pendingOpen: UUID?
    @ObservationIgnored private var started = false

    private var center: UNUserNotificationCenter { .current() }
    private static let shownKey = "shownAlerts"
    private static let installKey = "alertsInstallID"
    private static let shownLifetime: TimeInterval = 24 * 60 * 60

    /// The zone this phone's lock-screen alerts are written to; reported to the Mac only while they work.
    var alertZone: String? { lockScreenStatus == .on ? zoneName : nil }

    private var zoneName: String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: Self.installKey) { return RemoteAlerts.zoneName(installID: id) }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.installKey)
        return RemoteAlerts.zoneName(installID: id)
    }

    /// Becomes the notification delegate, early enough to hear about a tap that launched the app.
    func start() {
        guard !started else { return }
        started = true
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: RemoteAlerts.category, actions: [], intentIdentifiers: [])])
        Task {
            await refreshAuthorization()
            if isLockScreenEnabled { await setUpLockScreen() }
        }
    }

    // MARK: Permission

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Asks once, after pairing with a Mac that notifies; later calls only read the answer.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        await refreshAuthorization()
        if authorization == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            await refreshAuthorization()
        }
        return [.authorized, .provisional, .ephemeral].contains(authorization)
    }

    /// Back in front: the permission or the iCloud account may have changed in the meantime.
    func refresh() async {
        let wasAllowed = authorization
        await refreshAuthorization()
        guard isLockScreenEnabled else { return }
        if authorization != wasAllowed || lockScreenStatus != .on { await setUpLockScreen() }
    }

    // MARK: Live alerts

    /// An alert the Mac sent over the connection.
    func deliver(_ alert: RemoteNotification) {
        guard markShown(alert.id) else { return }
        if isForeground, visibleThread() == alert.threadID { return }
        if isForeground { withAnimation(.snappy) { banner = alert } }
        // Into Notification Center too, until the thread is seen. In front the banner above is the alert.
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.subtitle
        if let body = alert.body { content.body = body }
        content.sound = .default
        content.threadIdentifier = alert.threadID.uuidString
        content.categoryIdentifier = RemoteAlerts.category
        content.userInfo = ["threadID": alert.threadID.uuidString, "eventID": alert.id]
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        let center = center
        Task { try? await center.add(request) }
    }

    /// The thread was seen somewhere: remove its banner and what Notification Center holds about it.
    func clear(_ threadID: UUID) {
        if banner?.threadID == threadID { withAnimation(.snappy) { banner = nil } }
        let center = center
        Task {
            let ids = await center.deliveredNotifications()
                .filter { Self.threadID(of: $0.request.content.userInfo) == threadID }
                .map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    func open(_ threadID: UUID) {
        banner = nil
        if let openThread { openThread(threadID) } else { pendingOpen = threadID }
    }

    /// Records an event as shown; false when it already was.
    private func markShown(_ eventID: String) -> Bool {
        let defaults = UserDefaults.standard
        let now = Date()
        var shown = (defaults.dictionary(forKey: Self.shownKey) as? [String: Date] ?? [:])
            .filter { now.timeIntervalSince($0.value) < Self.shownLifetime }
        guard shown[eventID] == nil else { return false }
        shown[eventID] = now
        defaults.set(shown, forKey: Self.shownKey)
        return true
    }

    /// The thread an alert is about: the Mac's own, or one CloudKit delivered.
    nonisolated static func threadID(of userInfo: [AnyHashable: Any]) -> UUID? {
        if let value = userInfo["threadID"] as? String { return UUID(uuidString: value) }
        return cloudFields(userInfo)?.threadID
    }

    nonisolated private static func cloudFields(_ userInfo: [AnyHashable: Any]) -> (threadID: UUID?, eventID: String?)? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
            let fields = notification.recordFields
        else { return nil }
        let eventID = fields[RemoteAlerts.Field.eventID] as? String
        let threadID = (fields[RemoteAlerts.Field.threadID] as? String).flatMap(UUID.init(uuidString:))
            ?? eventID.flatMap(RemoteAlerts.threadID(ofEvent:))
        return (threadID, eventID)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        let isLive = userInfo["eventID"] != nil
        let cloud = isLive ? nil : Self.cloudFields(userInfo)
        return await MainActor.run {
            // The Mac's own, from `deliver`: the banner in the app already shows it.
            if isLive { return [.list] }
            // A lock-screen alert arriving after the app came to the front.
            guard let cloud else { return [] }
            if let threadID = cloud.threadID, self.visibleThread() == threadID { return [] }
            if let eventID = cloud.eventID, !self.markShown(eventID) { return [] }
            return [.banner, .list, .sound]
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let threadID = Self.threadID(of: response.notification.request.content.userInfo) else { return }
        await MainActor.run { self.open(threadID) }
    }

    // MARK: Lock-screen alerts

    func setLockScreenAlerts(_ enabled: Bool) async {
        isLockScreenEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: RemoteAlerts.lockScreenAlertsKey)
        if enabled { await setUpLockScreen() } else { await tearDownLockScreen() }
    }

    private var container: CKContainer { CKContainer(identifier: RemoteAlerts.containerIdentifier) }

    /// Makes this phone's zone and the subscription that turns each alert written there into a notification.
    private func setUpLockScreen() async {
        lockScreenStatus = .settingUp
        defer { onChange?() }
        guard await requestAuthorizationIfNeeded() else {
            lockScreenStatus = .notificationsDenied
            return
        }
        do {
            switch try await container.accountStatus() {
            case .available: break
            case .noAccount:
                lockScreenStatus = .unavailable(String(localized: "Sign in to iCloud on this iPhone to get alerts while it’s locked."))
                return
            default:
                lockScreenStatus = .unavailable(String(localized: "iCloud isn’t available on this iPhone right now."))
                return
            }
            let database = container.privateCloudDatabase
            let zone = CKRecordZone(zoneName: zoneName)
            _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
            let subscription = CKQuerySubscription(
                recordType: RemoteAlerts.recordType, predicate: NSPredicate(value: true), subscriptionID: zoneName,
                options: [.firesOnRecordCreation])
            subscription.zoneID = zone.zoneID
            let info = CKSubscription.NotificationInfo()
            // The record's own words; "%1$@" isn't in the string catalog, so iOS uses it as the format.
            info.titleLocalizationKey = "%1$@"
            info.titleLocalizationArgs = [RemoteAlerts.Field.title]
            info.subtitleLocalizationKey = "%1$@"
            info.subtitleLocalizationArgs = [RemoteAlerts.Field.subtitle]
            info.alertLocalizationKey = "%1$@"
            info.alertLocalizationArgs = [RemoteAlerts.Field.body]
            info.soundName = "default"
            info.category = RemoteAlerts.category
            info.desiredKeys = [RemoteAlerts.Field.eventID, RemoteAlerts.Field.threadID]
            info.collapseIDKey = RemoteAlerts.Field.collapseID
            subscription.notificationInfo = info
            _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
            UIApplication.shared.registerForRemoteNotifications()
            lockScreenStatus = .on
        } catch {
            lockScreenStatus = .unavailable(
                String(localized: "Couldn’t set up alerts through iCloud: \(error.localizedDescription)"))
        }
    }

    /// Removes the subscription and the zone with whatever alerts are left in it.
    private func tearDownLockScreen() async {
        lockScreenStatus = .off
        onChange?()
        let database = container.privateCloudDatabase
        let zoneName = zoneName
        _ = try? await database.modifySubscriptions(saving: [], deleting: [zoneName])
        _ = try? await database.modifyRecordZones(saving: [], deleting: [CKRecordZone.ID(zoneName: zoneName)])
    }

    /// iOS couldn't register for pushes, so no lock-screen alert can arrive.
    func registrationFailed(_ error: Error) {
        guard isLockScreenEnabled else { return }
        lockScreenStatus = .unavailable(
            String(localized: "Couldn’t set up alerts through iCloud: \(error.localizedDescription)"))
        onChange?()
    }
}
