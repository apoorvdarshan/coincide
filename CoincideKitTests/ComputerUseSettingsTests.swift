import Foundation
import Testing
@testable import CoincideKit

struct ComputerUseSettingsTests {
    @Test func computerUseStartsOffForNewAndExistingSettings() throws {
        #expect(!AppSettings().computerUseEnabled)
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize":16}"#.utf8))
        #expect(!settings.computerUseEnabled)
        #expect(settings.fontSize == 16)
    }

    @Test(arguments: ["null", "3", #""true""#, "[]", "{}"])
    func unreadableComputerUseDoesNotEnableAccessOrLoseOtherSettings(value: String) throws {
        let data = Data(#"{"computerUseEnabled":\#(value),"fontSize":16,"commandLineControl":false}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(!settings.computerUseEnabled)
        #expect(settings.fontSize == 16)
        #expect(!settings.commandLineControl)
    }

    @MainActor @Test func savedChoiceSurvivesStoreReconstructionAndCanBeRevoked() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-computer-use-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        store.updateSettings { $0.computerUseEnabled = true }
        store.flush()
        let reloaded = AppStore(directory: directory)
        #expect(reloaded.settings.computerUseEnabled)
        reloaded.updateSettings { $0.computerUseEnabled = false }
        reloaded.flush()
        #expect(!AppStore(directory: directory).settings.computerUseEnabled)
    }
}
