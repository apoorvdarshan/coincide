import Foundation
import Testing
@testable import CoincideCore

private typealias Machine = QuitShortcutStateMachine

private struct QuitDriver {
    var machine = Machine()
    var mode: Machine.Mode
    var timer: (token: UInt64, at: Int64)?
    var quits = 0
    var hint: Machine.Mode?
    init(_ mode: Machine.Mode) { self.mode = mode }

    @discardableResult
    mutating func send(_ input: Machine.Input, at now: Int64) -> Bool {
        let output = machine.handle(input, mode: mode, now: now)
        for effect in output.effects {
            switch effect {
            case .showHint(let mode): hint = mode
            case .hideHint: hint = nil
            case .cancelTimer: timer = nil
            case let .schedule(token, milliseconds): timer = (token, now + Int64(milliseconds))
            case .quit: quits += 1
            }
        }
        return output.consumed
    }
    /// Fires the pending timer when its deadline is not after `now`.
    mutating func advance(to now: Int64) {
        while let pending = timer, pending.at <= now { timer = nil; send(.timer(pending.token), at: pending.at) }
    }
    mutating func press(at now: Int64) -> Bool { send(.keyDown(isQ: true, command: true, otherModifiers: false, isRepeat: false), at: now) }
    mutating func repeatQ(at now: Int64) { send(.keyDown(isQ: true, command: true, otherModifiers: false, isRepeat: true), at: now) }
}

@Test func quitHoldWithKeyRepeatQuitsAfterTheHoldAndAQuietPeriod() {
    var driver = QuitDriver(.hold)
    let consumed = driver.press(at: 0)
    #expect(consumed && driver.hint == .hold && driver.quits == 0)
    var time: Int64 = 400
    while time < 1_200 { driver.repeatQ(at: time); driver.advance(to: time); time += 40 }
    #expect(driver.quits == 0, "Holding less than 1.2 seconds never quits.")
    driver.repeatQ(at: 1_200)
    #expect(driver.quits == 0 && driver.timer != nil)
    driver.repeatQ(at: 1_240); driver.repeatQ(at: 1_280)
    driver.advance(to: 1_280 + 599)
    #expect(driver.quits == 0, "Quitting waits until repeats stop.")
    driver.advance(to: 1_280 + 600)
    #expect(driver.quits == 1 && driver.hint == nil)
}

@Test func quitHoldQuitsOnQReleaseOnceArmedAndSlowRepeatsExtendTheGrace() {
    var released = QuitDriver(.hold)
    _ = released.press(at: 0)
    for time in stride(from: Int64(500), through: 1_300, by: 100) { released.repeatQ(at: time) }
    released.send(.qKeyUp, at: 1_310)
    #expect(released.quits == 1)

    var slow = QuitDriver(.hold)
    _ = slow.press(at: 0)
    slow.repeatQ(at: 900); slow.repeatQ(at: 1_400)
    // A 500 ms cadence waits two cadences rather than the 600 ms grace.
    slow.advance(to: 1_400 + 999)
    #expect(slow.quits == 0)
    slow.advance(to: 1_400 + 1_000)
    #expect(slow.quits == 1)
}

@Test func quitHoldTapShowsTheHintOnlyAndASecondPressQuits() {
    var driver = QuitDriver(.hold)
    _ = driver.press(at: 0)
    driver.send(.commandReleased, at: 90)
    #expect(driver.quits == 0 && driver.hint == nil)
    let second = driver.press(at: 400)
    #expect(second && driver.quits == 1, "Two presses within 500 ms quit in hold mode.")

    var slow = QuitDriver(.hold)
    _ = slow.press(at: 0); slow.send(.commandReleased, at: 80)
    _ = slow.press(at: 700)
    #expect(slow.quits == 0 && slow.hint == .hold, "A second press after 500 ms starts over.")
    slow.advance(to: 700 + 1_800)
    #expect(slow.quits == 0 && slow.hint == nil, "An unheld hint expires without quitting.")
}

@Test func quitDoublePressModeIgnoresHoldsAndKeepsItsHintUntilTheWindowEnds() {
    var driver = QuitDriver(.doublePress)
    _ = driver.press(at: 0)
    #expect(driver.hint == .doublePress)
    for time in stride(from: Int64(300), through: 2_000, by: 50) { driver.repeatQ(at: time); driver.advance(to: time) }
    #expect(driver.quits == 0, "Holding never quits in double-press mode.")

    var twice = QuitDriver(.doublePress)
    _ = twice.press(at: 0); twice.send(.commandReleased, at: 60)
    #expect(twice.hint == .doublePress, "Releasing keeps the double-press hint visible.")
    _ = twice.press(at: 450)
    #expect(twice.quits == 1)

    var expired = QuitDriver(.doublePress)
    _ = expired.press(at: 0); expired.send(.commandReleased, at: 60)
    expired.advance(to: 500)
    #expect(expired.hint == nil && expired.quits == 0)
}

@Test func quitDirectModeQuitsOnFirstPressAndOtherKeysPassThrough() {
    var direct = QuitDriver(.direct)
    let quitPress = direct.press(at: 0)
    #expect(quitPress && direct.quits == 1)

    var driver = QuitDriver(.hold)
    let shifted = driver.send(.keyDown(isQ: true, command: true, otherModifiers: true, isRepeat: false), at: 0)
    let otherKey = driver.send(.keyDown(isQ: false, command: true, otherModifiers: false, isRepeat: false), at: 10)
    let plainQ = driver.send(.keyDown(isQ: true, command: false, otherModifiers: false, isRepeat: false), at: 20)
    #expect(!shifted && !otherKey && !plainQ, "Only ⌘Q without other modifiers is the quit shortcut.")
    _ = driver.press(at: 100)
    #expect(driver.hint == .hold)
    let typing = driver.send(.keyDown(isQ: false, command: false, otherModifiers: false, isRepeat: false), at: 150)
    #expect(!typing)
    #expect(driver.hint == nil, "Another key cancels a pending hold.")
    _ = driver.press(at: 300)
    #expect(driver.quits == 0, "A cancelled first press does not count toward a double press.")
}

@Test func quitRunningWorkCountsBusyLocalThreadsAndRemoteRuns() {
    let project = WorkspaceProject(path: "/tmp/coincide-quit-fixture")
    var busy = CodingThread(project: project); busy.state = .running
    var waiting = CodingThread(project: project); waiting.state = .awaitingApproval
    let idle = CodingThread(project: project)
    var snapshot = WorkspaceSnapshot(); snapshot.threads = [busy, waiting, idle]
    let work = QuitRunningWork(snapshot: snapshot, remoteConversations: 1)
    #expect(work.localConversations == 2 && work.total == 3 && !work.isEmpty)
    #expect(work.title.contains("3") && work.detail.contains("remote") && work.detail.contains("resume"))
    #expect(QuitRunningWork(snapshot: .init(), remoteConversations: 0).isEmpty)
    #expect(QuitRunningWork(localConversations: 1, remoteConversations: 0).title == "Quit while a conversation is running?")
}

@Test func quitScopeCancellationForgetsTheFirstPressAndInvalidatesTheOldTimer() {
    for mode in [Machine.Mode.hold, .doublePress] {
        var driver = QuitDriver(mode)
        let consumed = driver.press(at: 0)
        #expect(consumed)
        let oldTimer = driver.timer
        driver.send(.cancel, at: 100)
        #expect(driver.hint == nil && driver.timer == nil && driver.quits == 0)
        if let oldTimer { driver.send(.timer(oldTimer.token), at: 2_000) }
        #expect(driver.quits == 0 && driver.hint == nil)
        #expect(driver.press(at: 2_100) && driver.quits == 0, "A press in another window cannot complete the earlier window's double press.")
        #expect(driver.press(at: 2_200) && driver.quits == 1)
    }
}
