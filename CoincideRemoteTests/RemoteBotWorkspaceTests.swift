import CoincideRemoteKit
import Foundation
import Testing

struct RemoteBotWorkspaceTests {
    @Test func botEditingCapabilityDoesNotChangeOldMacBehavior() throws {
        let oldMac = #"{"projects":[],"threads":[],"providers":[],"sections":[],"pinnedOrder":[],"bots":[]}"#
        let rustMac = #"{"projects":[],"threads":[],"providers":[],"sections":[],"pinnedOrder":[],"bots":[{"id":"00000000-0000-4000-8000-000000000077","name":"Fixture bot","projectID":"B0B5B0B5-C01C-4D1E-B075-000000000001","threadIDs":["00000000-0000-4000-8000-000000000088"],"avatar":{"character":"alien","tint":"mint"}}],"canEditBots":false}"#
        let decoder = JSONDecoder()
        let old = try decoder.decode(RemoteWorkspace.self, from: Data(oldMac.utf8))
        let current = try decoder.decode(RemoteWorkspace.self, from: Data(rustMac.utf8))
        #expect(old.canEditBots == nil)
        #expect(current.canEditBots == false)
        #expect(current.bots?.first?.name == "Fixture bot")
        #expect(current.bots?.first?.threadIDs.count == 1)
        #expect(current.bots?.first?.avatar?.character == "alien")
    }
}
