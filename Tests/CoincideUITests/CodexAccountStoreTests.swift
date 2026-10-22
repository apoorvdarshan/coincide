import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private let accountCheckedAt = Date(timeIntervalSince1970: 1_800_000_000)
private let firstAccount = CodexAccountIdentity(kind: .chatgpt, requiresOpenAIAuth: true,
    email: "first@example.invalid", planType: "plus", accountID: "private-first-account")
private let secondAccount = CodexAccountIdentity(kind: .chatgpt, requiresOpenAIAuth: true,
    email: "second@example.invalid", planType: "pro", accountID: "private-second-account")
private let accountUsage = CodexUsageSnapshot(buckets: [
    .init(id: "codex", name: "Codex", primary: .init(usedPercent: 30, windowDurationMinutes: 300,
        resetsAt: accountCheckedAt.addingTimeInterval(3_600)))
], ordinaryUsageAllowed: false, accountID: "private-first-account")

private func accountSnapshot(_ identity: CodexAccountIdentity = firstAccount,
                             usage: CodexAccountUsage = .available(accountUsage)) -> CodexAccountSnapshot {
    .init(identity: identity, usage: usage, checkedAt: accountCheckedAt)
}

private actor AccountReadGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var entered = false
    func wait() async {
        entered = true
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        released = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

@MainActor private final class AccountCancellationProbe {
    var started = false
    var finished = false
}

@MainActor private func accountEventually(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The owned account read did not reach its gate.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func codexAccountRefreshRetainsStaleUsageOnlyForExactIdentityAndClearsItOnAccountSwitch() async {
    let store = CodexAccountStore()
    await store.refresh { accountSnapshot() }
    #expect(store.snapshot?.usage == .available(accountUsage) && !store.isStale)
    await store.refresh { accountSnapshot(usage: .probeFailed(previous: nil)) }
    #expect(store.isStale && store.errorMessage != nil)
    #expect(store.snapshot?.usage.snapshot?.buckets == accountUsage.buckets)
    #expect(store.snapshot?.usage.snapshot?.ordinaryUsageAllowed == nil)
    await store.refresh { accountSnapshot(secondAccount, usage: .probeFailed(previous: accountUsage)) }
    #expect(store.snapshot?.identity == secondAccount)
    #expect(store.snapshot?.usage.snapshot == nil, "An identity change must never retain the old account's usage bars.")
    await store.refresh { accountSnapshot(.init(kind: .apiKey, requiresOpenAIAuth: true), usage: .unsupported) }
    #expect(store.snapshot?.usage == .unsupported && !store.isStale && store.errorMessage == nil)
    await store.cancel()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func codexAccountReplacedReadCannotPublishAndShutdownStillDrainsItsCanceledWork() async throws {
    let store = CodexAccountStore(), gate = AccountReadGate(), probe = AccountCancellationProbe()
    let old = Task { await store.refresh { await gate.wait(); return accountSnapshot() } }
    do {
        try await accountEventually { await gate.entered }
        await store.refresh { accountSnapshot(secondAccount, usage: .unsupported) }
        #expect(store.snapshot?.identity == secondAccount && !store.isRefreshing)
        let close = Task { probe.started = true; await store.cancel(); probe.finished = true }
        try await accountEventually { await MainActor.run { probe.started } }
        for _ in 0..<10 { await Task.yield() }
        #expect(!probe.finished, "Cancel must still own a replaced read after the newer read completed.")
        await gate.release(); await old.value; await close.value
        #expect(probe.finished && !store.isRefreshing && store.snapshot?.identity == secondAccount)
    } catch { await gate.release(); await old.value; await store.cancel(); throw error }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func codexAccountCanceledRefreshPreservesPriorStatusAndDoesNotLeaveRefreshingStuck() async throws {
    let store = CodexAccountStore(), gate = AccountReadGate()
    await store.refresh { accountSnapshot() }
    let previous = store.snapshot
    let read = Task { await store.refresh { await gate.wait(); return accountSnapshot(secondAccount) } }
    do {
        try await accountEventually { await gate.entered }
        #expect(store.isRefreshing)
        read.cancel(); await gate.release(); await read.value
        #expect(store.snapshot == previous && store.errorMessage == nil && !store.isStale && !store.isRefreshing)
        await store.cancel()
    } catch { await gate.release(); await read.value; await store.cancel(); throw error }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func codexAccountRefreshFailureIsBoundedRetainsTheLastCheckAndRecoversWithoutRawProviderDetails() async {
    let store = CodexAccountStore()
    await store.refresh { accountSnapshot() }
    let previous = store.snapshot
    await store.refresh { throw CoincideError("Private account debug response: do-not-display-this") }
    #expect(store.snapshot == previous && store.isStale && !store.isRefreshing)
    #expect(store.errorMessage != nil && store.errorMessage?.contains("do-not-display-this") == false)
    await store.refresh { accountSnapshot(secondAccount, usage: .unsupported) }
    #expect(store.snapshot?.identity == secondAccount && !store.isStale && store.errorMessage == nil)
    await store.cancel()
}

@Test func codexAccountPresentationUsesRemainingAllowanceAndKeepsUnknownSignInDetailsOutOfLabels() {
    #expect(CodexAccountPresentation.remainingPercent(used: 30) == 70)
    #expect(CodexAccountPresentation.remainingPercent(used: -20) == 100)
    #expect(CodexAccountPresentation.remainingPercent(used: 150) == 0)
    #expect(CodexAccountPresentation.remainingPercent(used: .nan) == nil)
    #expect(CodexAccountPresentation.boundedPercent(.infinity) == nil)
    #expect(CodexAccountPresentation.accountTitle(.unknown("private-wire-detail")) == "Unrecognized CLI sign-in")
}
