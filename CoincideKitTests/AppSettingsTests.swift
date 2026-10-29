import Foundation
import Testing

@testable import CoincideKit

/// The follow-up behavior setting, T3 Code's `followUpBehavior`: steer by default, saved under T3's values, and read
/// leniently like the other settings.
struct FollowUpBehaviorSettingsTests {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test func steerIsTheDefaultAsInT3Code() throws {
        #expect(AppSettings().followUpBehavior == .steer)
        // Files written before the setting existed keep steering.
        #expect(try decode(#"{"fontSize": 15}"#).followUpBehavior == .steer)
    }

    @Test func theChoiceSavesUnderT3CodesValues() throws {
        var settings = AppSettings()
        settings.followUpBehavior = .queue
        let data = try JSONEncoder().encode(settings)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["followUpBehavior"] as? String == "queue")
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
        #expect(try decode(#"{"followUpBehavior": "steer"}"#).followUpBehavior == .steer)
    }

    @Test(arguments: [#""halt""#, "3", "null", #"["queue"]"#])
    func anUnreadableValueFallsBackToSteerAndKeepsTheOtherSettings(value: String) throws {
        let settings = try decode(#"{"followUpBehavior": \#(value), "sendOnReturn": false, "fontSize": 15}"#)
        #expect(settings.followUpBehavior == .steer)
        #expect(settings.sendOnReturn == false)
        #expect(settings.fontSize == 15)
    }

    @Test func eachBehaviorHasANameAndAnOpposite() {
        #expect(FollowUpBehavior.allCases == [.steer, .queue, .interrupt])
        #expect(FollowUpBehavior.steer.displayName == "Steer")
        #expect(FollowUpBehavior.queue.displayName == "Queue")
        #expect(FollowUpBehavior.interrupt.displayName == "Interrupt")
        #expect(FollowUpBehavior.steer.opposite == .queue)
        #expect(FollowUpBehavior.queue.opposite == .steer)
        // The alternate send of an interrupt waits instead.
        #expect(FollowUpBehavior.interrupt.opposite == .queue)
    }

    /// Before each thread kept its own, the setting applied to every thread; those threads go on as it had them.
    @Test func threadsFromBeforeKeepTheAppWideSettingTheyHad() throws {
        #expect(try decode(#"{"followUpBehavior": "queue"}"#).existingThreadsFollowUpBehavior == .queue)
        #expect(try decode(#"{"fontSize": 15}"#).existingThreadsFollowUpBehavior == .steer)
        #expect(AppSettings().existingThreadsFollowUpBehavior == .steer)
        // Once saved, it stays put however the default for new threads moves.
        var settings = try decode(#"{"followUpBehavior": "queue"}"#)
        settings.followUpBehavior = .interrupt
        let saved = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(saved.followUpBehavior == .interrupt)
        #expect(saved.existingThreadsFollowUpBehavior == .queue)
    }
}
