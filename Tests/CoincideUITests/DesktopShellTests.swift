import AppKit
import CoincideCore
import Observation
import SwiftUI
import Testing
@testable import Coincide

@MainActor @Observable private final class ActivityFixture {
    var busy = 0
    var power = ActivityAssertionPolicy.PowerSource.ac
}

@MainActor private final class ActivityLog {
    var begun: [ActivityAssertionPolicy.Level] = []
    var ended = 0
}

@MainActor @Test(.timeLimit(.minutes(1)))
func agentActivityAssertionBeginsOnceEndsAfterTheDelayAndFollowsPower() async throws {
    let suite = "coincide-activity-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let fixture = ActivityFixture(), log = ActivityLog()
    let activities = AgentActivityAssertion.Activities(begin: { level in log.begun.append(level); return NSObject() }, end: { _ in log.ended += 1 })
    let assertion = AgentActivityAssertion(activeConversations: { fixture.busy }, power: { fixture.power }, defaults: defaults,
                                           activities: activities, releaseDelay: .milliseconds(150))
    assertion.start()
    #expect(log.begun.isEmpty && assertion.level == .none)
    fixture.busy = 1
    try await waitForActivity { assertion.level == .preventIdleSleep }
    fixture.busy = 2
    try await Task.sleep(for: .milliseconds(50))
    #expect(log.begun == [.preventIdleSleep], "A second running conversation does not take another assertion.")
    fixture.power = .battery; assertion.update()
    // Lowering to App Nap prevention waits for the release delay.
    #expect(assertion.level == .preventIdleSleep)
    try await waitForActivity { assertion.level == .preventAppNap }
    #expect(log.begun == [.preventIdleSleep, .preventAppNap] && log.ended == 1)
    fixture.busy = 0
    try await Task.sleep(for: .milliseconds(40))
    #expect(assertion.level == .preventAppNap, "Release is debounced.")
    try await waitForActivity { assertion.level == .none }
    #expect(log.ended == 2)
    defaults.set(ActivityAssertionPolicy.Preference.never.rawValue, forKey: AgentActivityAssertion.preference)
    fixture.power = .ac; fixture.busy = 1
    try await waitForActivity { assertion.level == .preventAppNap }
    assertion.shutdown()
    #expect(assertion.level == .none && log.ended == 3)
    fixture.busy = 3
    try await Task.sleep(for: .milliseconds(50))
    #expect(log.begun.count == 3, "Nothing is held after shutdown.")
}

@MainActor private func waitForActivity(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The activity assertion did not settle.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func welcomeReadinessUsesInjectedChecksAndSetupViewsFitInLightAndDark() async throws {
    _ = NSApplication.shared
    let readiness = AgentReadinessModel { agent, _, _ in agent == .codex ? .ready("Logged in using ChatGPT") : .signIn("Not logged in") }
    let environment = ShellEnvironmentController(available: false)
    await readiness.checkAll(environment: environment)
    #expect(readiness.states[.codex] == .ready("Logged in using ChatGPT") && readiness.states[.claude] == .signIn("Not logged in") && !readiness.isChecking)
    #expect(environment.summary == "Not used in this build")
    for scheme in [ColorScheme.light, .dark] {
        for width in [CGFloat(320), 680] {
            for state in [ProviderReadiness.install, .signIn(nil), .ready("Ready"), .attention("The sign-in check reported: a long and unexpected failure message from the CLI")] {
                let row = NSHostingController(rootView: AgentReadinessRow(agent: .claude, readiness: state, executable: URL(fileURLWithPath: "/Users/me/My Tools/claude"))
                    .environment(\.colorScheme, scheme))
                let size = row.sizeThatFits(in: .init(width: width, height: 400))
                #expect(size.width <= width + 1 && size.height > 0 && size.height <= 400)
            }
            let hint = NSHostingController(rootView: InAppBannerRow(banner: .init(id: UUID(), kind: .warning, title: "Approval needed", detail: "Refactor the build", actionTitle: "Open", key: nil, threadID: nil, expiresAt: nil), perform: {}, dismiss: {})
                .environment(\.colorScheme, scheme))
            #expect(hint.sizeThatFits(in: .init(width: width, height: 300)).width <= width + 1)
        }
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func licensesViewLoadsTheManifestAndSettingsReadBundleVersions() throws {
    _ = NSApplication.shared
    let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs")
    let manifest = try ThirdPartyNotices.load(directory: docs)
    for scheme in [ColorScheme.light, .dark] {
        let licenses = NSHostingController(rootView: OpenSourceLicensesView(manifest: manifest, directory: docs).environment(\.colorScheme, scheme))
        let size = licenses.sizeThatFits(in: .init(width: 760, height: 520))
        #expect(size.width > 0 && size.width <= 761 && size.height <= 521)
        let detail = NSHostingController(rootView: LicenseDetailView(package: try #require(manifest.packages.first { $0.id == "swiftterm" }), directory: docs)
            .environment(\.colorScheme, scheme))
        #expect(detail.sizeThatFits(in: .init(width: 480, height: 520)).width <= 481)
    }
    let unavailable = NSHostingController(rootView: OpenSourceLicensesView(directory: nil))
    #expect(unavailable.sizeThatFits(in: .init(width: 400, height: 400)).height > 0)
    #expect(DesktopShellSettings.versionText(["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7"]) == "0.1.0 (7)")
    #expect(DesktopShellSettings.versionText(["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "0.1.0"]) == "0.1.0")
    #expect(DesktopShellSettings.versionText([:]) == "Development build")
}

@MainActor @Test func desktopShellKeepsUITestCopiesOnDirectQuitAndWithoutLoginShellCapture() {
    let uiTesting = DesktopShell(bundleIdentifier: AppLaunchConfiguration.uiTestingBundleIdentifier, processEnvironment: [:])
    #expect(uiTesting.isUITesting && !uiTesting.isProductApp && !uiTesting.environment.available)
    #expect(!DesktopShell(bundleIdentifier: nil, processEnvironment: [:]).environment.available, "SwiftPM test hosts never read a login shell.")
    let product = DesktopShell(bundleIdentifier: DesktopShell.productBundleIdentifier, processEnvironment: ["COINCIDE_LOGIN_SHELL_ENV": "0"])
    #expect(product.isProductApp && !product.environment.available, "An explicit override disables capture.")
    #expect(DesktopShell(bundleIdentifier: DesktopShell.productBundleIdentifier, processEnvironment: [:]).environment.available)
    // Nothing runs, so quitting needs no confirmation and shows no alert.
    #expect(product.runningWork.isEmpty && product.confirmQuitWithRunningWork())
}
