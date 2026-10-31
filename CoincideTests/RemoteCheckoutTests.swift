import CoincideRemoteKit
import Foundation
import Testing

@testable import Coincide
@testable import CoincideKit

/// The checkout strip under Coincide Remote's composer: what the Mac describes, and the changes it makes for the phone.
@MainActor
struct RemoteCheckoutTests {
    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }

    private func fixture(_ name: String) throws -> (RemoteStoreAdapter, AppStore, UUID, URL, [TemporaryDirectory]) {
        let data = TemporaryDirectory(name + "-data")
        let repository = TemporaryDirectory(name + "-repo")
        try git(["init", "-q", "-b", "main"], in: repository.url)
        try git(["commit", "-q", "--allow-empty", "-m", "First"], in: repository.url)
        try git(["branch", "feature"], in: repository.url)
        let store = AppStore(directory: data.url)
        let registry = ProviderRegistry(store: store, providers: [])
        let runner = ThreadRunner(store: store, registry: registry)
        let adapter = RemoteStoreAdapter(store: store, runner: runner, registry: registry, services: RemoteSessionTests.services(store: store))
        let project = store.addProject(at: repository.url)
        let thread = store.createThread(in: project.id)
        return (adapter, store, thread.id, repository.url, [data, repository])
    }

    private func currentBranch(_ repository: URL) async throws -> String? {
        try await GitService.shared.branches(repository).currentBranch
    }

    @Test func aNewThreadInTheProjectsFolderSwitchesAndCreatesBranches() async throws {
        let (adapter, store, threadID, repository, folders) = try fixture("remote-checkout")
        defer { _ = folders }
        let checkout = try await adapter.checkout(threadID)
        #expect(checkout.workspace == .local)
        #expect(checkout.canChangeWorkspace)
        #expect(checkout.canPickBranch && checkout.canCreateBranch)
        #expect(checkout.branch == "main")
        #expect(Set(checkout.branches.map(\.name)).isSuperset(of: ["main", "feature"]))
        #expect(checkout.branches.first { $0.name == "main" }?.isCurrent == true)

        let switched = try await adapter.changeCheckout(threadID, .pickBranch("feature"))
        #expect(try await currentBranch(repository) == "feature")
        #expect(switched.branch == "feature")
        #expect(store.summary(threadID)?.branch == "feature")

        _ = try await adapter.changeCheckout(threadID, .createBranch("topic/remote"))
        #expect(try await currentBranch(repository) == "topic/remote")
        #expect(store.summary(threadID)?.branch == "topic/remote")
    }

    @Test func onlyBranchesGitListedAndNamesGitAcceptsReachGit() async throws {
        let (adapter, _, threadID, repository, folders) = try fixture("remote-checkout-refusals")
        defer { _ = folders }
        await #expect(throws: RemoteError.self) { try await adapter.changeCheckout(threadID, .pickBranch("--orphan=evil")) }
        await #expect(throws: RemoteError.self) { try await adapter.changeCheckout(threadID, .pickBranch("nope")) }
        for name in ["-rf", "two words", "a..b", "ends.lock", "", "x~1", "what?"] {
            await #expect(throws: RemoteError.self, "accepted \(name)") { try await adapter.changeCheckout(threadID, .createBranch(name)) }
        }
        #expect(try await currentBranch(repository) == "main")
        #expect(RemoteStoreAdapter.isAcceptableBranchName("feature/remote-checkout"))
        #expect(RemoteStoreAdapter.isAcceptableBranchName("v1.2"))
        #expect(!RemoteStoreAdapter.isAcceptableBranchName("@"))
        // An unknown thread is refused.
        await #expect(throws: RemoteError.self) { try await adapter.checkout(UUID()) }
    }

    @Test func chatsHaveNoCheckoutToChange() async throws {
        let (adapter, store, _, _, folders) = try fixture("remote-checkout-chats")
        defer { _ = folders }
        let chats = store.ensureChatsProject()
        let chat = store.createThread(in: chats.id)
        let checkout = try await adapter.checkout(chat.id)
        #expect(!checkout.canPickBranch && !checkout.canChangeWorkspace && checkout.branches.isEmpty)
    }

    @Test func checkoutRequestsAndResultSurviveEncoding() throws {
        let thread = UUID()
        let requests: [RemoteRequest] = [
            .checkout(threadID: thread), .changeCheckout(threadID: thread, action: .useLocal),
            .changeCheckout(threadID: thread, action: .useNewWorktree), .changeCheckout(threadID: thread, action: .usePreviousWorktree),
            .changeCheckout(threadID: thread, action: .pickBranch("feature")), .changeCheckout(threadID: thread, action: .createBranch("x")),
        ]
        for request in requests {
            let data = try RemoteProtocol.makeEncoder().encode(RemoteClientMessage(id: "1", request: request))
            #expect(try RemoteProtocol.makeDecoder().decode(RemoteClientMessage.self, from: data).request == request)
        }
        let checkout = RemoteCheckout(
            workspace: .newWorktree, canChangeWorkspace: true, hasPreviousWorktree: true, previousWorktreeBranch: "old", branch: "main",
            baseBranch: "main", canPickBranch: true, branches: [RemoteBranch(name: "main", isCurrent: true)])
        let response = RemoteServerMessage.response(id: "1", result: .checkout(checkout))
        #expect(try RemoteProtocol.makeDecoder().decode(RemoteServerMessage.self, from: try RemoteProtocol.makeEncoder().encode(response)) == response)
        // A workspace a newer Mac adds reads as unknown.
        let newer = #"{"workspace":"somewhereElse","canChangeWorkspace":false,"hasPreviousWorktree":false,"canPickBranch":false,"canCreateBranch":false,"branches":[],"isBusy":false}"#
        #expect(try JSONDecoder().decode(RemoteCheckout.self, from: Data(newer.utf8)).workspace == .unknown)
    }
}
