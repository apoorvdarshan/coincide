import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private let remoteUsageViewNow = Date(timeIntervalSince1970: 1_700_000_000)
private func remoteUsageViewValue(runID: UUID?) throws -> ProviderUsageUpdate {
    .claude(try .init(runID: runID, revision: 2,
        turn: runID == nil ? nil : .init(usageStatus: .complete, inputTokens: 100, outputTokens: 20),
        session: .init(estimatedCostUSD: 0.12, observedAt: remoteUsageViewNow),
        rateLimits: [.init(window: .fiveHour, status: .allowed, utilization: 0.25)], observedAt: remoteUsageViewNow))
}
private func remoteUsageViewBinding() -> RemoteProjectionBinding {
    .init(environmentID: UUID(), hostID: UUID(), viewID: UUID(), sequence: 1, fingerprint: String(repeating: "a", count: 64), scope: .thread(UUID()))
}
private func remoteUsageViewReference(_ bytes: Data, kind: RemoteProjectionContentKind = .providerUsage) -> RemoteProjectionContentReference {
    .init(id: UUID(), kind: kind, totalBytes: bytes.count, digest: RemoteProjectionProtocol.digest(bytes))
}
private actor RemoteUsageViewPeer {
    struct Call: Equatable { let reference: RemoteProjectionContentReference; let binding: RemoteProjectionBinding }
    let data: Data
    let held: Bool
    private(set) var calls: [Call] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    init(data: Data, held: Bool = false) { self.data = data; self.held = held }
    func read(_ reference: RemoteProjectionContentReference, binding: RemoteProjectionBinding) async -> Data {
        calls.append(.init(reference: reference, binding: binding))
        if held, !released { await withCheckedContinuation { waiters.append($0) } }
        return data
    }
    func release() { released = true; let owned = waiters; waiters = []; owned.forEach { $0.resume() } }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func providerUsageRemoteReaderKeepsExactLeaseAndRejectsLateReplyAfterSelectionChanges() async throws {
    let firstID = UUID(), secondID = UUID(), first = try remoteUsageViewValue(runID: firstID), second = try remoteUsageViewValue(runID: secondID)
    let firstData = try RemoteProjectionProtocol.payload(first), secondData = try RemoteProjectionProtocol.payload(second)
    let firstRef = remoteUsageViewReference(firstData), secondRef = remoteUsageViewReference(secondData)
    let firstBinding = remoteUsageViewBinding(), secondBinding = remoteUsageViewBinding()
    let firstCapture = RemoteProviderUsageCapture(binding: firstBinding, reference: firstRef, provider: .claude, runID: firstID, live: false)
    let secondCapture = RemoteProviderUsageCapture(binding: secondBinding, reference: secondRef, provider: .claude, runID: secondID, live: false)
    let held = RemoteUsageViewPeer(data: firstData, held: true), immediate = RemoteUsageViewPeer(data: secondData)
    let firstAccess = RemoteProviderUsageContentAccess(connected: { true }, document: { reference, binding in await held.read(reference, binding: binding) })
    let secondAccess = RemoteProviderUsageContentAccess(connected: { true }, document: { reference, binding in await immediate.read(reference, binding: binding) })
    let reader = RemoteProviderUsageReader()
    let loading = Task { await reader.load(firstCapture, access: firstAccess) }
    do {
        try await waitNativeSetup { await held.calls.count == 1 }
        reader.cancel()
        await reader.load(secondCapture, access: secondAccess)
        #expect(reader.value == second && reader.errorMessage == nil)
        await held.release(); await loading.value
        #expect(reader.value == second && reader.capture == secondCapture && !reader.isLoading)
        #expect(await held.calls == [.init(reference: firstRef, binding: firstBinding)])
        #expect(await immediate.calls == [.init(reference: secondRef, binding: secondBinding)])
    } catch { await held.release(); await loading.value; await reader.shutdown(); throw error }
    await reader.shutdown()
}

@Test @MainActor func providerUsageRemoteReaderVerifiesKindDigestAndRunScopeWithoutLeakingHostErrors() async throws {
    let runID = UUID(), value = try remoteUsageViewValue(runID: runID), data = try RemoteProjectionProtocol.payload(value)
    let binding = remoteUsageViewBinding(), reference = remoteUsageViewReference(data), peer = RemoteUsageViewPeer(data: data)
    let access = RemoteProviderUsageContentAccess(connected: { true }, document: { reference, binding in await peer.read(reference, binding: binding) })
    let reader = RemoteProviderUsageReader()
    await reader.load(.init(binding: binding, reference: remoteUsageViewReference(data, kind: .text), provider: .claude, runID: runID, live: false), access: access)
    #expect(reader.value == nil && reader.errorMessage != nil)
    #expect(await peer.calls.isEmpty)
    let oversized = RemoteProjectionContentReference(id: UUID(), kind: .providerUsage, totalBytes: 1_048_577, digest: reference.digest)
    await reader.load(.init(binding: binding, reference: oversized, provider: .claude, runID: runID, live: false), access: access)
    #expect(await peer.calls.isEmpty)
    await reader.load(.init(binding: binding, reference: reference, provider: .claude, runID: UUID(), live: false), access: access)
    #expect(reader.value == nil && reader.errorMessage != nil)
    await reader.load(.init(binding: binding, reference: reference, provider: .codex, runID: runID, live: false), access: access)
    #expect(reader.value == nil && reader.errorMessage != nil)
    let corrupt = RemoteProviderUsageContentAccess(connected: { true }, document: { _, _ in Data("PRIVATE-HOST-DATA".utf8) })
    await reader.load(.init(binding: binding, reference: reference, provider: .claude, runID: runID, live: false), access: corrupt)
    #expect(reader.value == nil && reader.errorMessage?.contains("PRIVATE-HOST-DATA") == false)
    let failed = RemoteProviderUsageContentAccess(connected: { true }, document: { _, _ in throw CoincideError("PRIVATE-HOST-ERROR") })
    await reader.load(.init(binding: binding, reference: reference, provider: .claude, runID: runID, live: false), access: failed)
    #expect(reader.errorMessage?.contains("PRIVATE-HOST-ERROR") == false)
    let passive = try remoteUsageViewValue(runID: nil), passiveData = try RemoteProjectionProtocol.payload(passive)
    let passiveRef = remoteUsageViewReference(passiveData)
    let passiveAccess = RemoteProviderUsageContentAccess(connected: { true }, document: { _, captured in
        #expect(captured == binding); return passiveData
    })
    await reader.load(.init(binding: binding, reference: passiveRef, provider: .claude, runID: nil, live: true), access: passiveAccess)
    #expect(reader.value == passive && reader.errorMessage == nil)
    await reader.load(.init(binding: binding, reference: passiveRef, provider: .claude, runID: runID, live: false), access: passiveAccess)
    #expect(reader.value == nil && reader.errorMessage != nil, "An idle meter is not recorded-run accounting.")
    await reader.shutdown()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func providerUsageRemoteViewsRenderInlineReferenceAndPassiveStatesOffscreenWithoutImplicitReads() async throws {
    _ = NSApplication.shared
    let runID = UUID(), value = try remoteUsageViewValue(runID: runID), passive = try remoteUsageViewValue(runID: nil)
    let data = try RemoteProjectionProtocol.payload(value), reference = remoteUsageViewReference(data), binding = remoteUsageViewBinding()
    let peer = RemoteUsageViewPeer(data: data)
    let access = RemoteProviderUsageContentAccess(connected: { true }, document: { reference, binding in await peer.read(reference, binding: binding) })
    let contents: [AnyView] = [
        AnyView(RemoteProviderUsageView(binding: binding, contentAccess: access, provider: .claude, runID: runID, inline: value, reference: nil)),
        AnyView(RemoteProviderUsageView(binding: binding, contentAccess: access, provider: .claude, runID: runID, inline: nil, reference: reference)),
        AnyView(RemoteProviderUsageView(binding: binding, contentAccess: access, provider: .claude, runID: nil, inline: passive, reference: nil, live: true)),
        AnyView(RemoteProviderUsageView(binding: binding, contentAccess: access, provider: .codex, runID: runID, inline: value, reference: nil)),
        AnyView(RemoteProviderUsageView(binding: binding, contentAccess: access, provider: .claude, runID: runID, inline: nil, reference: nil))]
    for scheme in [ColorScheme.light, .dark] {
        for width in [CGFloat(280), 560] {
            for content in contents {
                let host = NSHostingController(rootView: content.environment(\.colorScheme, scheme))
                let size = host.sizeThatFits(in: .init(width: width, height: 4_000))
                #expect(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 && size.width <= width + 1 && size.height < 4_000)
                host.view.frame = .init(origin: .zero, size: size); host.view.layoutSubtreeIfNeeded()
                #expect(host.view.window == nil)
            }
            let passiveHost = NSHostingController(rootView: RemoteProviderUsageView(binding: binding, contentAccess: access,
                provider: .claude, runID: nil, inline: passive, reference: nil, live: true).environment(\.colorScheme, scheme))
            let incorrectlyExpanded = NSHostingController(rootView: ProviderUsageView(usage: passive, showMainAgent: true).environment(\.colorScheme, scheme))
            let passiveHeight = passiveHost.sizeThatFits(in: .init(width: width, height: 4_000)).height
            let expandedHeight = incorrectlyExpanded.sizeThatFits(in: .init(width: width, height: 4_000)).height
            #expect(passiveHeight < expandedHeight, "A passive meter must not render a main-agent placeholder as a current turn.")
        }
    }
    #expect(await peer.calls.isEmpty)
}
