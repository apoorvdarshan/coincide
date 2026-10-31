import Foundation
import Testing

@testable import CoincideKit

/// The one-time acknowledgement of Antigravity's account risk (`AntigravityRiskGate`): how it is kept, that it asks
/// exactly once, that sign-in waits for it, and that nothing already set up is stopped.
@MainActor
struct AntigravityAccountRiskTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("antigravity-risk-" + UUID().uuidString, isDirectory: true)
    }

    // MARK: Persistence and decoding

    @Test func acknowledgementSurvivesReopeningTheStore() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = AntigravityRiskGate(store: AppStore(directory: directory))
        #expect(!gate.isAcknowledged)
        gate.signIn {}
        gate.acknowledge()
        #expect(gate.isAcknowledged)

        let reopened = AppStore(directory: directory)
        #expect(reopened.settings.dismissedWarnings.contains(AntigravityAccountRisk.acknowledgementKey))
        #expect(AntigravityRiskGate(store: reopened).isAcknowledged)
    }

    @Test func settingsDecodeTheAcknowledgementAndTolerateOlderOrBrokenFiles() throws {
        let key = AntigravityAccountRisk.acknowledgementKey
        let saved = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"fontSize":15,"dismissedWarnings":["provider:antigravity-account-risk"]}"#.utf8))
        #expect(saved.dismissedWarnings.contains(key))

        // Settings from before the acknowledgement existed, or with the list unreadable, ask again and keep the rest.
        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize":15}"#.utf8))
        #expect(!older.dismissedWarnings.contains(key))
        let broken = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"fontSize":15,"dismissedWarnings":{"provider:antigravity-account-risk":true}}"#.utf8))
        #expect(!broken.dismissedWarnings.contains(key))
        #expect(broken.fontSize == 15)

        var settings = AppSettings()
        settings.dismissedWarnings.insert(key)
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).dismissedWarnings.contains(key))
    }

    @Test func theKeyIsStableAndTheTermsAreGooglesOwnPage() {
        #expect(AntigravityAccountRisk.acknowledgementKey == "provider:antigravity-account-risk")
        #expect(AntigravityAccountRisk.termsURL.absoluteString == "https://antigravity.google/terms")
    }

    // MARK: Asking once

    @Test func theSheetShowsExactlyOnce() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        let gate = AntigravityRiskGate(store: store)
        var signIns = 0

        gate.signIn { signIns += 1 }
        #expect(gate.isAsking)
        #expect(signIns == 0)
        gate.acknowledge()
        #expect(!gate.isAsking)
        #expect(signIns == 1)

        // Later sign-ins and turning Antigravity on go ahead without asking, in this gate and in a new one.
        gate.signIn { signIns += 1 }
        #expect(!gate.isAsking)
        #expect(signIns == 2)
        var enabled = false
        let later = AntigravityRiskGate(store: AppStore(directory: directory))
        later.setEnabled(true, wasEnabled: false) { enabled = true }
        #expect(!later.isAsking)
        #expect(enabled)
    }

    @Test func aSecondRequestWhileAskingRunsOnlyTheLatest() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = AntigravityRiskGate(store: AppStore(directory: directory))
        var ran: [String] = []
        gate.signIn { ran.append("first") }
        gate.signIn { ran.append("second") }
        gate.acknowledge()
        #expect(ran == ["second"])
    }

    // MARK: New users

    @Test func signInDoesNotStartWithoutAcknowledgement() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        let gate = AntigravityRiskGate(store: store)
        var signIns = 0

        gate.signIn { signIns += 1 }
        #expect(gate.isAsking)
        gate.cancel()
        #expect(!gate.isAsking)
        #expect(signIns == 0)
        #expect(!gate.isAcknowledged)
        #expect(!store.settings.dismissedWarnings.contains(AntigravityAccountRisk.acknowledgementKey))

        // Cancelling saves nothing, so the next attempt asks again, and an acknowledgement then never replays the
        // cancelled one.
        gate.signIn { signIns += 10 }
        #expect(gate.isAsking)
        gate.acknowledge()
        #expect(signIns == 10)
    }

    @Test func turningAntigravityOnWaitsForAcknowledgement() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = AntigravityRiskGate(store: AppStore(directory: directory))
        var enabled = false

        gate.setEnabled(true, wasEnabled: false) { enabled = true }
        #expect(gate.isAsking)
        #expect(!enabled)
        gate.cancel()
        #expect(!enabled)

        gate.setEnabled(true, wasEnabled: false) { enabled = true }
        gate.acknowledge()
        #expect(enabled)
    }

    // MARK: Existing users

    @Test func existingSignedInUsersAreNotBlocked() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Someone who set up Antigravity before this version: it's on, with no acknowledgement saved.
        let store = AppStore(directory: directory)
        store.updateSettings { $0.providers[.antigravity] = ProviderSettings(isEnabled: true) }
        store.flush()
        let reopened = AppStore(directory: directory)
        let gate = AntigravityRiskGate(store: reopened)

        // Nothing asks on its own, and Antigravity stays on.
        #expect(!gate.isAsking)
        #expect(!gate.isAcknowledged)
        #expect(reopened.settings.settings(for: .antigravity).isEnabled)

        // Changes that leave it on, or turn it off, never wait.
        var applied = 0
        gate.setEnabled(true, wasEnabled: true) { applied += 1 }
        gate.setEnabled(false, wasEnabled: true) { applied += 1 }
        #expect(applied == 2)
        #expect(!gate.isAsking)

        // Their next sign-in asks, once.
        var signIns = 0
        gate.signIn { signIns += 1 }
        #expect(gate.isAsking)
        gate.acknowledge()
        gate.signIn { signIns += 1 }
        #expect(signIns == 2)
        #expect(!gate.isAsking)
    }
}
