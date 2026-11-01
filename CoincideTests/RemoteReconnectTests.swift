import CoincideRemoteKit
import Foundation
import Network
import Testing

/// Coincide Remote reconnecting to its Mac (`RemoteReconnect`): a launch, a return to the app and a connection the
/// system dropped reconnect quietly, and only a reconnect that outlasts the grace period shows "Connecting" or
/// "Offline".
struct RemoteReconnectTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func aLaunchStaysQuietForTheGracePeriod() {
        var reconnect = RemoteReconnect()
        #expect(!reconnect.isQuiet(at: at(0)))
        reconnect.connectingQuietly(at: at(0))
        #expect(reconnect.isQuiet(at: at(0)))
        #expect(reconnect.isQuiet(at: at(RemoteReconnect.grace - 0.1)))
        #expect(!reconnect.isQuiet(at: at(RemoteReconnect.grace)))
        #expect(reconnect.quietRemaining(at: at(1)) == RemoteReconnect.grace - 1)
        #expect(reconnect.quietRemaining(at: at(RemoteReconnect.grace)) == nil)
        // Short enough to report a Mac that's gone before the wait feels broken, long enough for a retry.
        #expect(RemoteReconnect.grace > 1 && RemoteReconnect.grace <= 3)
    }

    @Test func connectingEndsTheQuietSoALaterDropShowsAtOnce() {
        var reconnect = RemoteReconnect()
        reconnect.connectingQuietly(at: at(0))
        reconnect.connected(at: at(0.4))
        #expect(!reconnect.isQuiet(at: at(0.5)))
        #expect(reconnect.quietRemaining(at: at(0.5)) == nil)
        // The Mac closing the connection, a minute later and with the app in front, isn't the system's doing.
        #expect(reconnect.failed(transient: false, at: at(60)) == .retry(after: 1))
        #expect(!reconnect.isQuiet(at: at(60)))
    }

    @Test func theBackgroundStaysQuietUntilTheAppIsBackAndThenForTheGracePeriod() {
        var reconnect = RemoteReconnect()
        reconnect.connected(at: at(0))
        reconnect.enteredBackground()
        #expect(reconnect.isInBackground)
        #expect(reconnect.isQuiet(at: at(3_600)))
        // No timer while away: the quiet lasts until the app is back in front.
        #expect(reconnect.quietRemaining(at: at(3_600)) == nil)
        // A drop while away, of either kind, shows nothing.
        #expect(reconnect.failed(transient: false, at: at(3_600)) == .retry(after: 1))
        #expect(reconnect.isQuiet(at: at(3_601)))
        reconnect.becameActive(at: at(7_200))
        #expect(!reconnect.isInBackground)
        #expect(reconnect.isQuiet(at: at(7_200 + RemoteReconnect.grace - 0.1)))
        #expect(!reconnect.isQuiet(at: at(7_200 + RemoteReconnect.grace)))
    }

    @Test func aMomentInactiveInFrontChangesNothingOnScreen() {
        // Control Center or a system alert: the app never went to the background, so the socket is as it was.
        var reconnect = RemoteReconnect()
        reconnect.connected(at: at(0))
        reconnect.becameActive(at: at(60))
        #expect(!reconnect.isQuiet(at: at(60)))
        #expect(reconnect.quietRemaining(at: at(60)) == nil)
        // Offline and saying so, it goes on saying so rather than hiding until the next try fails too.
        #expect(reconnect.failed(transient: false, at: at(70)) == .retry(after: 1))
        reconnect.becameActive(at: at(71))
        #expect(!reconnect.isQuiet(at: at(71)))
        // A quiet launch under way keeps its end, neither cut short nor drawn out.
        reconnect.connectingQuietly(at: at(100))
        reconnect.becameActive(at: at(101))
        #expect(reconnect.isQuiet(at: at(100 + RemoteReconnect.grace - 0.1)))
        #expect(!reconnect.isQuiet(at: at(100 + RemoteReconnect.grace)))
    }

    @Test func aTransientDropRetriesAtOnceAndQuietly() {
        var reconnect = RemoteReconnect()
        reconnect.connected(at: at(0))
        #expect(reconnect.failed(transient: true, at: at(60)) == .retryNow)
        // The drop starts a grace period of its own, with the app in front.
        #expect(reconnect.isQuiet(at: at(60 + RemoteReconnect.grace - 0.1)))
        #expect(!reconnect.isQuiet(at: at(60 + RemoteReconnect.grace)))
        reconnect.connected(at: at(60.3))
        #expect(!reconnect.isQuiet(at: at(60.4)))
    }

    @Test func aFailedAttemptDoesntStartAGracePeriodOfItsOwn() {
        // Try Again by hand: "Connecting" shows, and a transient failure retries at once without hiding it.
        var reconnect = RemoteReconnect()
        reconnect.showNow()
        #expect(reconnect.failed(transient: true, at: at(0)) == .retryNow)
        #expect(!reconnect.isQuiet(at: at(0)))
    }

    @Test func immediateRetriesRunOutAndThenBackOff() {
        var reconnect = RemoteReconnect()
        reconnect.connectingQuietly(at: at(0))
        for _ in 0..<RemoteReconnect.immediateRetries {
            #expect(reconnect.failed(transient: true, at: at(0.1)) == .retryNow)
        }
        #expect(reconnect.immediateRetriesLeft == 0)
        var delays: [RemoteReconnect.Next] = []
        for _ in 0..<7 { delays.append(reconnect.failed(transient: true, at: at(0.2))) }
        let expected: [TimeInterval] = [1, 2, 4, 8, 16, 30, 30]
        #expect(delays == expected.map { RemoteReconnect.Next.retry(after: $0) })
        // Coming back to the app starts over.
        reconnect.enteredBackground()
        reconnect.becameActive(at: at(100))
        #expect(reconnect.failed(transient: true, at: at(100)) == .retryNow)
        #expect(reconnect.backoff == 1)
        // So does a moment inactive in front, as when the user turned Wi-Fi on in Control Center.
        #expect(reconnect.failed(transient: false, at: at(101)) == .retry(after: 1))
        #expect(reconnect.backoff == 2)
        reconnect.becameActive(at: at(102))
        #expect(reconnect.immediateRetriesLeft == RemoteReconnect.immediateRetries)
        #expect(reconnect.backoff == 1)
    }

    @Test func onlyAConnectionThatStayedUpEarnsFreshImmediateRetries() {
        var reconnect = RemoteReconnect()
        reconnect.connectingQuietly(at: at(0))
        for _ in 0..<RemoteReconnect.immediateRetries { _ = reconnect.failed(transient: true, at: at(0)) }
        // A Mac that accepts and drops at once isn't retried in a tight loop.
        reconnect.connected(at: at(1))
        #expect(reconnect.failed(transient: true, at: at(2)) == .retry(after: 1))
        reconnect.connected(at: at(3))
        #expect(reconnect.failed(transient: true, at: at(3 + RemoteReconnect.stableAfter)) == .retryNow)
    }

    @Test func showingNowEndsTheQuiet() {
        var reconnect = RemoteReconnect()
        reconnect.connectingQuietly(at: at(0))
        #expect(reconnect.isQuiet(at: at(0.1)))
        for _ in 0..<RemoteReconnect.immediateRetries + 2 { _ = reconnect.failed(transient: true, at: at(0)) }
        // Pairing again, disconnecting, or connecting by hand.
        reconnect.showNow()
        #expect(!reconnect.isQuiet(at: at(0.1)))
        #expect(reconnect.immediateRetriesLeft == RemoteReconnect.immediateRetries)
        #expect(reconnect.backoff == 1)
    }

    @Test func suspensionAndNetworkChangesAreTransientAndOtherFailuresArent() {
        let transient: [POSIXErrorCode] = [.ECONNABORTED, .ECONNRESET, .ENOTCONN, .ENETRESET, .ENETDOWN, .EPIPE, .ECANCELED]
        for code in transient {
            let error = RemoteSocketError(.posix(code))
            #expect(error == .interrupted, "\(code)")
            #expect(error.isTransient, "\(code)")
        }
        // ECONNABORTED (53) is what a return from suspension finds.
        #expect(RemoteSocketError(.posix(POSIXErrorCode(rawValue: 53)!)).isTransient)
        // The Mac not listening, not answering or not routable: retried with the backoff, shown as offline.
        for code: POSIXErrorCode in [.ECONNREFUSED, .ETIMEDOUT, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN] {
            let error = RemoteSocketError(.posix(code))
            #expect(!error.isTransient, "\(code)")
            #expect(error != .certificateMismatch, "\(code)")
        }
        #expect(!RemoteSocketError(.dns(-65554)).isTransient)
        #expect(!RemoteSocketError.closedByMac.isTransient)
        #expect(!RemoteSocketError.certificateMismatch.isTransient)
    }

    @Test func onlyTheTLSPinFailingAsksToPairAgain() {
        // A failed pin (bad certificate) means another certificate; it deletes the token, so nothing else may map here.
        #expect(RemoteSocketError(.tls(-9808)) == .certificateMismatch)
        // A TLS session closed underneath, as a suspension mid-handshake does, is transient instead.
        for status: OSStatus in [-9805, -9806, -9816] {
            #expect(RemoteSocketError(.tls(status)) == .interrupted, "\(status)")
        }
    }

    @Test func noSocketErrorShowsNetworksOwnWording() {
        let errors: [NWError] = [.posix(.ECONNABORTED), .posix(.ECONNREFUSED), .posix(.ETIMEDOUT), .dns(-65554), .tls(-9806)]
        for error in errors {
            let message = RemoteSocketError(error).message
            #expect(!message.contains("NWError"), "\(error)")
            #expect(!message.contains("POSIX"), "\(error)")
            #expect(!message.contains(error.localizedDescription), "\(error)")
            #expect(!message.isEmpty)
        }
        #expect(RemoteSocketError.transport("POSIX 61").message == RemoteSocketError.transport("anything").message)
    }
}
