import Foundation
import Testing

@testable import CoincideKit

/// "Hold ⌘Q to quit": the setting and the decisions made from ⌘Q's presses and releases.
struct QuitShortcutGuardTests {
    @Test func theSettingIsOnByDefaultAndForSettingsSavedBeforeIt() throws {
        #expect(AppSettings().holdToQuit)
        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"sendOnReturn": false}"#.utf8))
        #expect(older.holdToQuit)
        var off = AppSettings()
        off.holdToQuit = false
        let reloaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(off))
        #expect(!reloaded.holdToQuit)
    }

    @Test func aSinglePressOnlyShowsTheHintUntilItTimesOut() {
        var quit = QuitShortcutGuard()
        #expect(quit.keyDown(at: 10, isRepeat: false) == .showHint)
        #expect(quit.showsHint && quit.isHolding)
        #expect(quit.keyUp(at: 10.1) == .none)
        #expect(quit.showsHint && !quit.isHolding)
        #expect(quit.tick(at: 11) == .none)
        #expect(quit.tick(at: 11.5) == .none)
        #expect(quit.tick(at: 11.6) == .hideHint)
        #expect(!quit.showsHint)
        #expect(quit.tick(at: 20) == .none)
    }

    @Test func holdingForASecondQuits() {
        var quit = QuitShortcutGuard()
        #expect(quit.keyDown(at: 0, isRepeat: false) == .showHint)
        #expect(quit.holdProgress(at: 0.5) == 0.5)
        // The key repeating while held does not quit early.
        #expect(quit.keyDown(at: 0.5, isRepeat: true) == .none)
        #expect(quit.tick(at: 0.9) == .none)
        #expect(quit.tick(at: 1) == .quit)
        #expect(quit.holdProgress(at: 1.2) == 0)
    }

    @Test func aRepeatPastTheHoldOrAReleaseAfterItQuitsWithoutWaitingForATick() {
        var repeated = QuitShortcutGuard()
        _ = repeated.keyDown(at: 0, isRepeat: false)
        #expect(repeated.keyDown(at: 1.05, isRepeat: true) == .quit)
        var released = QuitShortcutGuard()
        _ = released.keyDown(at: 0, isRepeat: false)
        #expect(released.keyUp(at: 1.2) == .quit)
    }

    @Test func pressingTwiceWithinTheWindowQuits() {
        var quit = QuitShortcutGuard()
        _ = quit.keyDown(at: 0, isRepeat: false)
        _ = quit.keyUp(at: 0.1)
        #expect(quit.keyDown(at: 1.4, isRepeat: false) == .quit)
    }

    @Test func aSecondPressAfterTheWindowStartsOver() {
        var quit = QuitShortcutGuard()
        _ = quit.keyDown(at: 0, isRepeat: false)
        _ = quit.keyUp(at: 0.1)
        #expect(quit.keyDown(at: 1.6, isRepeat: false) == .showHint)
        #expect(quit.isHolding)
        #expect(quit.holdProgress(at: 2.1) == 0.5)
        // A release and quick press now count from this press.
        _ = quit.keyUp(at: 1.7)
        #expect(quit.keyDown(at: 2.5, isRepeat: false) == .quit)
    }

    @Test func letGoBeforeTheSecondIsUpNeverQuits() {
        var quit = QuitShortcutGuard()
        _ = quit.keyDown(at: 0, isRepeat: false)
        _ = quit.keyUp(at: 0.9)
        #expect(quit.tick(at: 1.2) == .none)
        #expect(quit.holdProgress(at: 1.2) == 0)
    }

    @Test func afterAskingToQuitTheRepeatingKeyNeverAsksAgain() {
        var quit = QuitShortcutGuard()
        _ = quit.keyDown(at: 0, isRepeat: false)
        #expect(quit.tick(at: 1) == .quit)
        // Still held while "agents still working" asks, and the user cancels.
        #expect(quit.keyDown(at: 1.5, isRepeat: true) == .none)
        #expect(quit.keyDown(at: 3, isRepeat: true) == .none)
        #expect(quit.tick(at: 3) == .none)
        #expect(!quit.showsHint)
        // Once let go, a new press starts over.
        #expect(quit.keyUp(at: 3.1) == .none)
        #expect(quit.keyDown(at: 3.2, isRepeat: false) == .showHint)
    }

    @Test func aNewPressAfterQuittingStartsOverEvenWithoutARelease() {
        var quit = QuitShortcutGuard()
        _ = quit.keyDown(at: 0, isRepeat: false)
        _ = quit.tick(at: 1)
        #expect(quit.keyDown(at: 5, isRepeat: false) == .showHint)
    }

    @Test func cancellingHidesTheHint() {
        var quit = QuitShortcutGuard()
        #expect(quit.cancel() == .none)
        _ = quit.keyDown(at: 0, isRepeat: false)
        #expect(quit.cancel() == .hideHint)
        #expect(!quit.showsHint)
        #expect(quit.tick(at: 2) == .none)
        // The earlier press no longer counts toward a double press.
        #expect(quit.keyDown(at: 0.5, isRepeat: false) == .showHint)
    }

    @Test func aRepeatWithNoPressSeenStartsAHold() {
        var quit = QuitShortcutGuard()
        #expect(quit.keyDown(at: 0, isRepeat: true) == .showHint)
        #expect(quit.tick(at: 1) == .quit)
    }
}
