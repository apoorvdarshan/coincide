import Darwin
import Foundation
import Testing
@testable import CoincideCore

private func remotePrivateRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-remote-private-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
}
private func remoteSavedConnection() -> RemoteEnvironmentConnection {
    .init(name: "Remote Mac 工作", configuration: .init(target: "studio-mac", port: 2222,
        helperPath: "/Applications/Coincide Tools/CoincideEnvironment", dataDirectory: "/Users/remote/Private Data/Coincide"), environmentID: UUID())
}
private func remotePending(connection: UUID = UUID()) -> RemoteEnvironmentPendingCommand {
    .init(connectionID: connection, environmentID: UUID(), id: UUID(), command: .addProject(id: UUID(), path: "/remote/project", title: "Remote project"))
}

@Test func sshRemoteEnvironmentKeepsHostKeyAuthenticationAndShellQuotesRemotePaths() throws {
    let configuration = SSHRemoteEnvironmentConfiguration(target: "developer@remote-mac", port: 2200,
        helperPath: "/Applications/Remote ' Tools/$literal/CoincideEnvironment",
        dataDirectory: "/Users/remote/Private ' Data/$(never-execute)")
    let arguments = try SSHRemoteEnvironment.arguments(configuration: configuration)
    #expect(arguments.contains("BatchMode=yes") && arguments.contains("StrictHostKeyChecking=yes"))
    #expect(arguments.contains("PermitLocalCommand=no") && arguments.contains("RequestTTY=no"))
    #expect(Array(arguments.suffix(5).prefix(4)) == ["-p", "2200", "--", "developer@remote-mac"])
    #expect(arguments.last == "exec '/Applications/Remote '\\'' Tools/$literal/CoincideEnvironment' --stdio --data-directory '/Users/remote/Private '\\'' Data/$(never-execute)'")
    #expect(!arguments.contains("StrictHostKeyChecking=no") && !arguments.contains("StrictHostKeyChecking=accept-new"))
    // Neither remote path exists on this Mac; validating it must not open it.
    try configuration.validate()
}

@Test func sshRemoteEnvironmentRejectsOptionsCredentialsInvalidPortsAndNonabsoluteHelpers() throws {
    let base = SSHRemoteEnvironmentConfiguration(target: "my-alias", helperPath: "/opt/coincide/CoincideEnvironment", dataDirectory: "/remote/state")
    for target in ["", "-oProxyCommand=bad", "alias another", "alias\nother", "user:password@host", "ssh://host", "host;command", "user@@host", "host/path", "user@-host"] {
        var value = base; value.target = target
        #expect(throws: RemoteEnvironmentClientError(.invalidConfiguration)) { try value.validate() }
    }
    for port in [0, -1, 65_536] {
        var value = base; value.port = port
        #expect(throws: RemoteEnvironmentClientError(.invalidConfiguration)) { try value.validate() }
    }
    for path in ["relative/CoincideEnvironment", "~/CoincideEnvironment", "/", "/bin/sh", "/opt/../CoincideEnvironment", "/opt//CoincideEnvironment", "/opt/\0/CoincideEnvironment"] {
        var value = base; value.helperPath = path
        #expect(throws: RemoteEnvironmentClientError(.invalidConfiguration)) { try value.validate() }
    }
    for path in ["relative", "~/.coin", "/", "/remote/../state", "/remote\nstate"] {
        var value = base; value.dataDirectory = path
        #expect(throws: RemoteEnvironmentClientError(.invalidConfiguration)) { try value.validate() }
    }
}

@Test func remoteConnectionRegistryIsBoundedPrivateAndPreservesCorruptData() throws {
    let root = try remotePrivateRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let connection = remoteSavedConnection()
    #expect(try RemoteEnvironmentRegistry.load(rootURL: root).isEmpty)
    try RemoteEnvironmentRegistry.save([connection], rootURL: root)
    #expect(try RemoteEnvironmentRegistry.load(rootURL: root) == [connection])
    let file = root.appendingPathComponent("connections.json")
    #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let before = try Data(contentsOf: file)
    #expect(throws: RemoteEnvironmentStorageError.self) { try RemoteEnvironmentRegistry.save([connection, connection], rootURL: root) }
    #expect(try Data(contentsOf: file) == before)
    let tooMany = (0...RemoteEnvironmentRegistry.maximumConnections).map { _ in remoteSavedConnection() }
    #expect(throws: RemoteEnvironmentStorageError(.limitExceeded)) { try RemoteEnvironmentRegistry.save(tooMany, rootURL: root) }
    let corrupt = Data("{broken-private-registry".utf8); try corrupt.write(to: file)
    #expect(throws: RemoteEnvironmentStorageError(.corruptFile)) { try RemoteEnvironmentRegistry.load(rootURL: root) }
    #expect(throws: RemoteEnvironmentStorageError(.corruptFile)) { try RemoteEnvironmentRegistry.save([], rootURL: root) }
    #expect(try Data(contentsOf: file) == corrupt)
}

@Test(arguments: ["symlink", "hardlink", "fifo", "permissions"])
func remotePrivateRegistryRefusesUnsafeFilesWithoutFollowingOrReplacingThem(kind: String) throws {
    let root = try remotePrivateRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("connections.json"), target = root.appendingPathComponent("preserve-private-source")
    let original = Data("preserved-source-bytes".utf8)
    try original.write(to: target); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    switch kind {
    case "symlink": try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    case "hardlink": #expect(Darwin.link(target.path, file.path) == 0)
    case "fifo": #expect(mkfifo(file.path, 0o600) == 0)
    default:
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    }
    #expect(throws: RemoteEnvironmentStorageError(.unsafeFile)) { try RemoteEnvironmentRegistry.load(rootURL: root) }
    #expect(throws: RemoteEnvironmentStorageError(.unsafeFile)) { try RemoteEnvironmentRegistry.save([], rootURL: root) }
    #expect(try Data(contentsOf: target) == original)
}

@Test func remotePendingCommandSurvivesRestartRequiresExactRemovalAndRetainsExplicitAbandonment() async throws {
    let root = try remotePrivateRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let pending = remotePending(), first = RemoteEnvironmentPendingStore(root: root)
    try await first.save(pending); try await first.save(pending)
    let restarted = RemoteEnvironmentPendingStore(root: root)
    #expect(try await restarted.load(connectionID: pending.connectionID) == pending)
    await #expect(throws: RemoteEnvironmentStorageError(.pendingCommandExists)) { try await restarted.save(remotePending(connection: pending.connectionID)) }
    await #expect(throws: RemoteEnvironmentStorageError(.commandChanged)) { try await restarted.remove(connectionID: pending.connectionID, commandID: UUID()) }
    #expect(try await restarted.load(connectionID: pending.connectionID) == pending)
    try await restarted.archive(connectionID: pending.connectionID, commandID: pending.id)
    #expect(try await restarted.load(connectionID: pending.connectionID) == nil)
    let audit = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("abandoned-") })
    #expect(try JSONDecoder().decode(RemoteEnvironmentPendingCommand.self, from: Data(contentsOf: audit)) == pending)
    #expect((try FileManager.default.attributesOfItem(atPath: audit.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let next = remotePending(connection: pending.connectionID)
    try await restarted.save(next); try await restarted.remove(connectionID: next.connectionID, commandID: next.id)
    #expect(try await restarted.load(connectionID: next.connectionID) == nil)
}

@Test func remotePendingStoresSerializeCompetingWindowsAndPreserveCorruptPendingPayload() async throws {
    let root = try remotePrivateRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let connection = UUID(), a = remotePending(connection: connection), b = remotePending(connection: connection)
    let first = RemoteEnvironmentPendingStore(root: root), second = RemoteEnvironmentPendingStore(root: root)
    async let one: Bool = { do { try await first.save(a); return true } catch { return false } }()
    async let two: Bool = { do { try await second.save(b); return true } catch { return false } }()
    let results = await [one, two]
    #expect(results.filter { $0 }.count == 1)
    let saved = try #require(await first.load(connectionID: connection))
    #expect(saved == a || saved == b)
    let file = root.appendingPathComponent("pending-" + connection.uuidString.lowercased() + ".json")
    let corrupt = Data("private-broken-command".utf8); try corrupt.write(to: file)
    await #expect(throws: RemoteEnvironmentStorageError(.corruptFile)) { try await first.save(a) }
    await #expect(throws: RemoteEnvironmentStorageError(.corruptFile)) { try await first.remove(connectionID: connection, commandID: saved.id) }
    #expect(try Data(contentsOf: file) == corrupt)
}

@Test func remotePendingIdentityRequiresExactEncodedTextIncludingUnicodeRepresentation() async throws {
    let root = try remotePrivateRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let connection = UUID(), environment = UUID(), command = UUID(), project = UUID()
    let first = RemoteEnvironmentPendingCommand(connectionID: connection, environmentID: environment, id: command,
        command: .addProject(id: project, path: "/remote/project", title: "Caf\u{00e9}"))
    let changed = RemoteEnvironmentPendingCommand(connectionID: connection, environmentID: environment, id: command,
        command: .addProject(id: project, path: "/remote/project", title: "Cafe\u{0301}"))
    #expect(try RemoteEnvironmentProtocol.payload(first.request) != RemoteEnvironmentProtocol.payload(changed.request))
    let store = RemoteEnvironmentPendingStore(root: root)
    try await store.save(first)
    await #expect(throws: RemoteEnvironmentStorageError(.pendingCommandExists)) { try await store.save(changed) }
    try await store.archive(connectionID: connection, commandID: command)
    // A different exact payload must not overwrite an existing abandonment audit
    // even if its strings compare canonically equal in Swift.
    try await store.save(changed)
    await #expect(throws: RemoteEnvironmentStorageError(.commandChanged)) { try await store.archive(connectionID: connection, commandID: command) }
    let retained = try #require(await store.load(connectionID: connection))
    #expect(try RemoteEnvironmentProtocol.payload(retained.request) == RemoteEnvironmentProtocol.payload(changed.request))
}

@Test func remoteDraftsAreIsolatedBoundedPrivateAndNeverOverwriteCorruptSavedText() async throws {
    let root = try remotePrivateRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let environment = UUID(), thread = UUID(), drafts = [thread: "Keep this draft 工作 😀\nwhile disconnected"]
    let first = RemoteEnvironmentDraftStore(root: root)
    try await first.save(environmentID: environment, drafts: drafts)
    let restarted = RemoteEnvironmentDraftStore(root: root)
    #expect(try await restarted.load(environmentID: environment) == drafts)
    #expect(try await restarted.load(environmentID: UUID()).isEmpty)
    await #expect(throws: RemoteEnvironmentStorageError(.limitExceeded)) {
        try await restarted.save(environmentID: environment, drafts: [thread: String(repeating: "😀", count: 60_001)])
    }
    await #expect(throws: RemoteEnvironmentStorageError(.limitExceeded)) {
        try await restarted.save(environmentID: environment, drafts: Dictionary(uniqueKeysWithValues: (0...256).map { _ in (UUID(), "draft") }))
    }
    #expect(try await restarted.load(environmentID: environment) == drafts)
    let file = root.appendingPathComponent("drafts-" + environment.uuidString.lowercased() + ".json")
    #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let corrupt = Data("private-corrupt-drafts".utf8); try corrupt.write(to: file)
    await #expect(throws: RemoteEnvironmentStorageError(.corruptFile)) { try await restarted.save(environmentID: environment, drafts: [:]) }
    #expect(try Data(contentsOf: file) == corrupt)
}
