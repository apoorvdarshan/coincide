import Foundation
import Testing
@testable import CoincideCore

@Test(arguments: ProviderKind.allCases.filter { !$0.isSupported })
func removedProvidersCannotCreateNewThreadsChangeProviderOrStartProductionSessions(_ provider: ProviderKind) throws {
    let project = WorkspaceProject(path: "/historical-provider-fixture")
    let current = CodingThread(project: project)
    var removed = CodingThread(project: project); removed.provider = provider
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [current]
    let original = snapshot

    for command in [WorkspaceCommand.createThread(removed), .editThread(current.id, .provider(provider))] {
        do {
            _ = try WorkspaceDecision.make(.client(command), id: UUID(), snapshot: snapshot, now: .now)
            Issue.record("A removed provider was admitted through a workspace command.")
        } catch let error as WorkspaceCommandError {
            #expect(error.message == "Coincide supports Codex and Claude only.")
        }
    }
    do {
        _ = try ProviderSessions.make(for: removed)
        Issue.record("A removed provider was admitted through the production runtime factory.")
    } catch let error as CoincideError {
        #expect(error.localizedDescription == "Coincide supports Codex and Claude only.")
    }
    #expect(snapshot == original)
    // The enum remains decodable so existing stored conversations can be read.
    #expect(try JSONDecoder().decode(ProviderKind.self, from: JSONEncoder().encode(provider)) == provider)
}

@Test func removedACPConfigurationCannotBeRegisteredOrSelected() throws {
    let project = WorkspaceProject(path: "/historical-acp-fixture"), agent = ACPAgentConfiguration(name: "Historical agent", executable: "/must-not-run")
    let thread = CodingThread(project: project)
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    for command in [WorkspaceCommand.saveACPAgent(agent), .editThread(thread.id, .acpAgent(agent))] {
        do {
            _ = try WorkspaceDecision.make(.client(command), id: UUID(), snapshot: snapshot, now: .now)
            Issue.record("A removed ACP configuration was admitted.")
        } catch let error as WorkspaceCommandError {
            #expect(error.message == "Coincide supports Codex and Claude only.")
        }
    }
    #expect(ProviderKind.builtIn == [.codex, .claude])
    #expect(snapshot.acpAgents.isEmpty && snapshot.threads == [thread])
}
