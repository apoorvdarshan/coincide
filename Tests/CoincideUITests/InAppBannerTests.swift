import AppKit
@testable import CoincideCore
import SwiftUI
import Testing
@testable import Coincide

@MainActor private final class BannerClock { var now = ContinuousClock.now }
@MainActor private final class BannerRecorder { var values: [UUID] = []; var count = 0 }

@MainActor @Test func inAppBannersDeduplicateKeepThreeAndExpireOnlyTransientBanners() {
    let clock = BannerClock()
    let center = InAppBannerCenter(now: { clock.now }, schedulesExpiry: false, announces: false)
    center.post(.info, title: "First", key: "shared")
    center.post(.info, title: "Replacement", key: "shared")
    #expect(center.banners.map(\.title) == ["Replacement"])
    center.post(.error, title: "Failure")
    center.post(.success, title: "Done")
    center.post(.warning, title: "Needs input")
    #expect(center.banners.map(\.title) == ["Needs input", "Done", "Failure"], "The oldest transient banner yields first.")
    center.post(.error, title: "Second failure"); center.post(.error, title: "Third failure")
    #expect(center.banners.map(\.title) == ["Third failure", "Second failure", "Failure"])
    center.dismissAll { _ in true }
    center.post(.info, title: "Transient"); center.post(.error, title: "Sticky")
    center.expire(at: clock.now + .seconds(4))
    #expect(center.banners.count == 2)
    center.expire(at: clock.now + .seconds(6))
    #expect(center.banners.map(\.title) == ["Sticky"], "Errors stay until dismissed.")
}

@MainActor @Test func inAppBannerHoverPausesExpiryAndActionsDismissTheirBanner() {
    let clock = BannerClock()
    let center = InAppBannerCenter(now: { clock.now }, schedulesExpiry: false, announces: false)
    let performed = BannerRecorder()
    let id = center.post(.success, title: "Thread completed", actionTitle: "Open") { performed.count += 1 }
    center.setHovering(true)
    clock.now += .seconds(10)
    center.expire(at: clock.now)
    #expect(center.banners.count == 1, "Hovering pauses expiry.")
    center.setHovering(false)
    center.expire(at: clock.now + .seconds(1))
    #expect(center.banners.count == 1, "Leaving the stack grants a short grace period.")
    center.performAction(id)
    #expect(performed.count == 1 && center.banners.isEmpty)
    center.post(.info, title: "No action", actionTitle: "Ignored")
    #expect(center.banners.first?.actionTitle == nil)
}

private func bannerRun(_ thread: CodingThread, status: ThreadRunStatus) -> ThreadRunRecord {
    var result = ThreadRunRecord(run: .init(id: UUID(), configuration: .init(thread: thread), startedAt: .now), origin: .user)
    result.status = status
    if status.isTerminal { result.endedAt = .now }
    return result
}

@MainActor @Test func threadBannersAppearOnlyForOtherConversationsWhileActive() throws {
    let suite = "coincide-banner-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let clock = BannerClock()
    let center = InAppBannerCenter(now: { clock.now }, schedulesExpiry: false, announces: false)
    let project = WorkspaceProject(path: "/tmp/coincide-banner-fixture")
    var selected = CodingThread(project: project); selected.title = "Selected conversation"
    var other = CodingThread(project: project); other.title = "Background refactor"
    let opened = BannerRecorder(), selectedID = selected.id
    let notifications = NativeThreadNotifications(defaults: defaults) { _ in }
    notifications.banners = ThreadBannerCoordinator(center: center, defaults: defaults, selectedThreadID: { selectedID }) { opened.values.append($0) }
    func snapshot() -> WorkspaceSnapshot { var value = WorkspaceSnapshot(); value.projects = [project]; value.threads = [selected, other]; return value }
    notifications.observe(snapshot(), baseline: true, appIsActive: true)
    selected.runHistory = [bannerRun(selected, status: .running)]; other.runHistory = [bannerRun(other, status: .running)]
    notifications.observe(snapshot(), baseline: false, appIsActive: true)
    #expect(center.banners.isEmpty)
    selected.runHistory?[0].status = .completed; selected.runHistory?[0].endedAt = .now
    other.runHistory?[0].status = .completed; other.runHistory?[0].endedAt = .now
    notifications.observe(snapshot(), baseline: false, appIsActive: true)
    #expect(center.banners.count == 1 && center.banners.first?.threadID == other.id && center.banners.first?.kind == .success)
    #expect(center.banners.first?.detail == "Background refactor" && center.banners.first?.actionTitle == "Open")
    center.performAction(try #require(center.banners.first).id)
    #expect(opened.values == [other.id] && center.banners.isEmpty)

    // Inactive app: system notifications cover it, so no banner.
    let second = bannerRun(other, status: .running); other.runHistory?.append(second)
    notifications.observe(snapshot(), baseline: false, appIsActive: false)
    other.runHistory?[1].status = .failed; other.runHistory?[1].endedAt = .now; other.state = .failed
    notifications.observe(snapshot(), baseline: false, appIsActive: false)
    #expect(center.banners.isEmpty)

    // Disabled in Settings.
    defaults.set(false, forKey: ThreadBannerCoordinator.preference)
    let third = bannerRun(other, status: .running); other.runHistory?.append(third); other.state = .running
    notifications.observe(snapshot(), baseline: false, appIsActive: true)
    other.runHistory?[2].status = .completed; other.runHistory?[2].endedAt = .now; other.state = .idle
    notifications.observe(snapshot(), baseline: false, appIsActive: true)
    #expect(center.banners.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func inAppBannerOverlayAndQuitHintFitNarrowAndWideWindowsInLightAndDark() {
    _ = NSApplication.shared
    let center = InAppBannerCenter(schedulesExpiry: false, announces: false)
    center.post(.error, title: "Link not opened", detail: "This prompt is longer than 8,000 characters, so Coincide did not open it. A long explanation must wrap inside the banner.")
    center.post(.success, title: "Thread completed", detail: "A conversation with a deliberately long title that should wrap or truncate cleanly", actionTitle: "Open") {}
    for scheme in [ColorScheme.light, .dark] {
        for width in [CGFloat(320), 680] {
            let overlay = NSHostingController(rootView: InAppBannerOverlay(center: center, hiddenThreadID: nil).environment(\.colorScheme, scheme))
            let size = overlay.sizeThatFits(in: .init(width: width, height: 600))
            #expect(size.width <= width + 1 && size.height > 40 && size.height <= 600)
            for mode in [QuitShortcutStateMachine.Mode.hold, .doublePress] {
                let hint = NSHostingController(rootView: QuitHoldHUDView(mode: mode).environment(\.colorScheme, scheme))
                let hintSize = hint.sizeThatFits(in: .init(width: width, height: 300))
                #expect(hintSize.width <= width + 1 && hintSize.height > 0 && hintSize.height <= 300)
            }
        }
    }
}
