import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private struct ProjectionUIFixtureState: Codable {
    var descriptor: RemoteEnvironmentDescriptor
    var sequence: Int64
    var hostID: UUID
    var projects: [RemoteProjectSummary]
    var threads: [RemoteThreadSummary]
    var detail: RemoteThreadDetail
    var messages: [RemoteMessageSummary]
    var documents: [String: Data]
    var dropCommand = false
    var runs: [RemoteRunSummary] = []
}
private final class ProjectionUIFixture: @unchecked Sendable {
    let root: URL, stateURL: URL, script: URL, wire: URL
    let connection: RemoteEnvironmentConnection
    let thread: CodingThread
    let hostID = UUID()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-projection-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        stateURL = root.appendingPathComponent("state.json"); script = root.appendingPathComponent("peer.py"); wire = root.appendingPathComponent("wire.jsonl")
        let environment = UUID(), project = WorkspaceProject(path: "/remote/projection-fixture")
        thread = CodingThread(project: project)
        connection = .init(name: "Projection fixture", configuration: .init(target: "offline-projection", helperPath: "/remote/CoincideEnvironment", dataDirectory: "/remote/data"), environmentID: environment)
        var documents: [String: Data] = [:]
        func document<T: Encodable>(_ value: T, kind: RemoteProjectionContentKind) throws -> RemoteProjectionContentReference {
            let data = try RemoteProjectionProtocol.payload(value), id = UUID(); documents[id.uuidString] = data
            return .init(id: id, kind: kind, totalBytes: data.count, digest: RemoteProjectionProtocol.digest(data))
        }
        let config = try document(ProviderConfiguration(thread: thread), kind: .configuration)
        let attachments = try document([ChatAttachment](), kind: .attachmentReferences)
        let requests = try document([RuntimeRequest](), kind: .runtimeRequests)
        let summary = RemoteThreadSummary(id: thread.id, projectID: project.id, title: .init(preview: "Paged conversation", complete: true),
            workspacePath: project.path, provider: thread.provider, providerName: thread.providerName, model: .init(preview: thread.model, complete: true),
            permission: thread.permission, state: thread.state, isPinned: false, isArchived: false, createdAt: Date(), updatedAt: Date(), messageCount: 600, runCount: 0, queueCount: 0)
        let detail = RemoteThreadDetail(summary: summary, configuration: config, draft: .init(preview: "Host draft sentinel", complete: true),
            draftAttachments: attachments, runtimeRequests: requests, requestCount: 0, queuePaused: false, checkpointPolicy: .disabled,
            workspaceReady: true, isBusy: false, submit: .init(allowed: true), resumeQueue: .init(allowed: false), mutateFiles: .init(allowed: true),
            openTerminal: .init(allowed: true), chooseWorktree: .init(allowed: false, reason: "Conversation already has messages."))
        let rows = (0..<600).map { RemoteMessageSummary(id: "message-\($0)", role: .assistant, createdAt: Date(timeIntervalSince1970: Double(600 - $0)),
            text: .init(preview: "Message \($0)", complete: true), attachmentCount: 0) }
        let capabilities = RemoteEnvironmentCapabilities(supportsBoundedProjections: true)
        let state = ProjectionUIFixtureState(descriptor: .init(environmentID: environment, label: "Offline projection", capabilities: capabilities), sequence: 10,
            hostID: hostID, projects: [.init(id: project.id, name: .init(preview: "Remote project", complete: true), workspacePath: project.path)],
            threads: [summary], detail: detail, messages: rows, documents: documents)
        try JSONEncoder().encode(state).write(to: stateURL)
        try Self.peer.write(to: script, atomically: false, encoding: .utf8)
        try RemoteEnvironmentRegistry.save([connection], rootURL: root)
    }
    func factory(_ configuration: SSHRemoteEnvironmentConfiguration, _ expected: UUID?) throws -> RemoteEnvironmentClient {
        RemoteEnvironmentClient(factory: { [self] in
            try JSONRPCConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, root.path], cwd: root,
                dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
                environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], drainProcessOnClose: true)
        }, expectedEnvironmentID: expected)
    }
    func update(sequence: Int64? = nil, drop: Bool? = nil) throws {
        var state = try JSONDecoder().decode(ProjectionUIFixtureState.self, from: Data(contentsOf: stateURL))
        if let sequence { state.sequence = sequence }; if let drop { state.dropCommand = drop }
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }
    func checkpointRun() throws -> RemoteRunSummary {
        var state = try JSONDecoder().decode(ProjectionUIFixtureState.self, from: Data(contentsOf: stateURL))
        let path = thread.workspacePath, now = Date(), allowed = RemoteProjectionAvailability(allowed: true)
        let baseline = RemoteCheckpointAttemptSummary(id: UUID(), stage: .baseline, workspacePath: path, phase: .ready,
            requestedAt: now, updatedAt: now, isLaterObservation: false, hasReceipt: true, digest: String(repeating: "a", count: 64), restore: allowed)
        let post = RemoteCheckpointAttemptSummary(id: UUID(), stage: .postRun, workspacePath: path, phase: .ready,
            requestedAt: now, updatedAt: now, isLaterObservation: false, hasReceipt: true, digest: String(repeating: "b", count: 64), restore: allowed)
        let run = RemoteRunSummary(id: UUID(), origin: .user, status: .completed, startedAt: now, endedAt: now,
            stopRequested: false, turnCount: 1, checkpointAttempts: [baseline, post], checkpointAttemptCount: 2,
            checkpointAttemptsComplete: true, checkpointDiff: allowed, fork: .init(allowed: false), rewind: .init(allowed: false),
            provider: thread.provider, providerName: thread.providerName, model: .init(preview: thread.model, complete: true),
            permission: thread.permission, workspacePath: path, checkpointPolicy: .automatic)
        state.runs = [run]
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        return run
    }
    func emptyCatalog(sequence: Int64) throws {
        var state = try JSONDecoder().decode(ProjectionUIFixtureState.self, from: Data(contentsOf: stateURL))
        state.threads = []; state.sequence = sequence
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }
    func addStaleCatalogRow() throws -> UUID {
        var state = try JSONDecoder().decode(ProjectionUIFixtureState.self, from: Data(contentsOf: stateURL))
        let bytes = try JSONEncoder().encode(state.threads[0]), id = UUID()
        guard var object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw CoincideError("Owned catalog fixture is malformed") }
        object["id"] = id.uuidString
        state.threads.append(try JSONDecoder().decode(RemoteThreadSummary.self, from: JSONSerialization.data(withJSONObject: object)))
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        return id
    }
    func manyCatalogThreads() throws {
        var state = try JSONDecoder().decode(ProjectionUIFixtureState.self, from: Data(contentsOf: stateURL))
        let original = try JSONEncoder().encode(state.threads[0])
        for index in 1..<600 {
            guard var object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw CoincideError("Owned catalog fixture is malformed") }
            object["id"] = UUID().uuidString
            object["title"] = ["preview": "Catalog row \(index)", "complete": true]
            state.threads.append(try JSONDecoder().decode(RemoteThreadSummary.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }
    func hold(_ name: String) throws { try Data().write(to: root.appendingPathComponent("hold-" + name)) }
    func release(_ name: String) { try? Data().write(to: root.appendingPathComponent("release-" + name)) }
    func entered(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("entered-" + name).path) }
    func heldBinding(_ name: String) throws -> RemoteProjectionBinding {
        try JSONDecoder().decode(RemoteProjectionBinding.self, from: Data(contentsOf: root.appendingPathComponent("entered-" + name)))
    }
    func releasedViews() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: wire.path) else { return [] }
        return try Data(contentsOf: wire).split(separator: 10).compactMap { line in
            let frame = try JSONDecoder().decode(JSONValue.self, from: Data(line))
            guard frame["method"].string == RemoteProjectionProtocol.releaseMethod,
                  let id = frame["params"]["binding"]["viewID"].string else { return nil }
            return UUID(uuidString: id)
        }
    }
    func giantMessageAndDraft(oversizedDraft: Bool = false) throws -> (RemoteProjectionContentReference, String) {
        var state = try JSONDecoder().decode(ProjectionUIFixtureState.self, from: Data(contentsOf: stateURL))
        let literal = "A" + String(repeating: "😇अé工作/", count: 90_000), data = Data(literal.utf8)
        let reference = RemoteProjectionContentReference(id: UUID(), kind: .text, totalBytes: data.count, digest: RemoteProjectionProtocol.digest(data))
        state.documents[reference.id.uuidString] = data
        let old = state.messages[0]
        state.messages[0] = .init(id: old.id, role: old.role, createdAt: old.createdAt,
            text: .init(preview: String(literal.prefix(256)), complete: false, content: reference), attachmentCount: 0)
        if oversizedDraft {
            let draft = RemoteProjectionContentReference(id: UUID(), kind: .draft, totalBytes: data.count, digest: reference.digest)
            state.documents[draft.id.uuidString] = data
            let old = state.detail
            state.detail = .init(summary: old.summary, configuration: old.configuration,
                draft: .init(preview: String(literal.prefix(256)), complete: false, content: draft), draftAttachments: old.draftAttachments,
                runtimeRequests: old.runtimeRequests, requestCount: old.requestCount, queuePaused: false, checkpointPolicy: .disabled,
                workspaceReady: true, isBusy: false, submit: .init(allowed: true), resumeQueue: .init(allowed: false), mutateFiles: .init(allowed: true),
                openTerminal: .init(allowed: true), chooseWorktree: .init(allowed: false))
        }
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        return (reference, literal)
    }
    func busy() throws -> (UUID, UUID, ApprovalRequest) {
        var state = try JSONDecoder().decode(ProjectionUIFixtureState.self, from: Data(contentsOf: stateURL))
        let runID = UUID(), runtimeID = UUID()
        let request = ApprovalRequest(id: .string("exact-projection-approval"), method: "item/commandExecution/requestApproval", params: .object(["command": .string("fixture command")]))
        let bytes = try RemoteProjectionProtocol.payload([RuntimeRequest(request: request)])
        let reference = RemoteProjectionContentReference(id: UUID(), kind: .runtimeRequests, totalBytes: bytes.count, digest: RemoteProjectionProtocol.digest(bytes))
        state.documents[reference.id.uuidString] = bytes
        let old = state.detail, row = old.summary
        let summary = RemoteThreadSummary(id: row.id, projectID: row.projectID, title: row.title, workspacePath: row.workspacePath,
            provider: row.provider, providerName: row.providerName, model: row.model, permission: row.permission, state: .awaitingApproval,
            isPinned: row.isPinned, isArchived: false, createdAt: row.createdAt, updatedAt: row.updatedAt,
            messageCount: row.messageCount, runCount: row.runCount, queueCount: row.queueCount)
        state.detail = .init(summary: summary, configuration: old.configuration, draft: old.draft, draftAttachments: old.draftAttachments,
            runtimeRequests: reference, requestCount: 1, queuePaused: false, checkpointPolicy: .disabled,
            activeRun: .init(id: runID, runtimeID: runtimeID, startedAt: Date(), stopRequested: false), runtimeID: runtimeID,
            workspaceReady: true, isBusy: true, submit: .init(allowed: true), resumeQueue: .init(allowed: false),
            mutateFiles: .init(allowed: false, reason: "Provider owns this checkout."), openTerminal: .init(allowed: false), chooseWorktree: .init(allowed: false))
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        return (runID, runtimeID, request)
    }
    func commands() throws -> [RemoteEnvironmentCommandRequest] {
        guard FileManager.default.fileExists(atPath: wire.path) else { return [] }
        return try Data(contentsOf: wire).split(separator: 10).compactMap { line in
            let frame = try JSONDecoder().decode(JSONValue.self, from: Data(line))
            guard frame["method"].string == RemoteEnvironmentProtocol.commandMethod else { return nil }
            return try RemoteEnvironmentProtocol.decode(RemoteEnvironmentCommandRequest.self, from: frame["params"])
        }
    }
    func methods() throws -> [String] {
        guard FileManager.default.fileExists(atPath: wire.path) else { return [] }
        return try Data(contentsOf: wire).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0))["method"].string ?? "" }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    private static let peer = #"""
import base64,copy,json,os,sys,threading,time,uuid
from pathlib import Path
root=Path(sys.argv[1]); assert root.name.startswith('coincide-projection-ui-') and os.stat(root).st_mode&0o077==0
views={}; cursors={}; output_lock=threading.Lock()
def emit(frame):
    with output_lock: print(json.dumps(frame),flush=True)
def defer_response(frame,result,name):
    if name is None or not (root/('hold-'+name)).exists(): return False
    (root/('entered-'+name)).write_text(json.dumps(result))
    def owned_reply():
        deadline=time.monotonic()+5
        while not (root/('release-'+name)).exists() and time.monotonic()<deadline: time.sleep(.005)
        emit({'jsonrpc':'2.0','id':frame['id'],'result':result})
    threading.Thread(target=owned_reply,daemon=True).start(); return True
def state(): return json.loads((root/'state.json').read_text())
def page(binding,items,cursor=None):
    offset=0 if cursor is None else cursors[cursor]
    end=min(len(items),offset+300); next=None
    if end<len(items): next=str(uuid.uuid5(uuid.NAMESPACE_URL,binding['viewID']+str(items[0].get('id','empty'))+str(end))).upper(); cursors[next]=end
    return {'binding':binding,'offset':offset,'items':items[offset:end],'totalCount':len(items),'nextCursor':next,'complete':end==len(items)}
for line in sys.stdin:
    frame=json.loads(line)
    with (root/'wire.jsonl').open('a') as output: output.write(json.dumps(frame)+'\n')
    method=frame['method']; p=frame.get('params',{}); current=state(); environment=current['descriptor']['environmentID']; gate=None
    if method=='remoteEnvironment.describe': result=current['descriptor']
    elif method in ('remoteEnvironment.projection.open','remoteEnvironment.projection.subscribe'):
        scope=p.get('scope',{'catalog':{}})
        binding={'environmentID':environment,'hostID':current['hostID'],'viewID':str(uuid.uuid4()).upper(),'sequence':current['sequence'],'fingerprint':'a'*64,'scope':scope}
        views[binding['viewID']]=copy.deepcopy(current); result=binding
        if 'catalog' in scope and method.endswith('.open'): gate='catalog-open-'+str(binding['sequence'])
    elif method.startswith('remoteEnvironment.projection.'):
        binding=p['binding']; snapshot=views[binding['viewID']]
        if method.endswith('.catalog'):
            kind='projects' if 'projects' in p['query'] else 'threads'
            result={kind:{'_0':page(binding,snapshot[kind],p.get('cursor'))}}
            if p.get('cursor') is not None: gate='catalog-page-'+str(binding['sequence'])
        elif method.endswith('.thread'):
            if p['threadID'] != snapshot['detail']['summary']['id']:
                emit({'jsonrpc':'2.0','id':frame['id'],'error':{'code':-32006,'message':'Owned thread unavailable','data':{'kind':'notFound'}}}); continue
            result={'binding':binding,'thread':snapshot['detail']}
        elif method.endswith('.messages'): result=page(binding,snapshot['messages'],p.get('cursor'))
        elif method.endswith('.runs'): result=page(binding,snapshot.get('runs',[]),p.get('cursor'))
        elif method.endswith('.operations'): result=page(binding,[])
        elif method.endswith('.content'):
            ref=p['reference']; raw=base64.b64decode(snapshot['documents'][ref['id']]); offset=p['offset']; end=min(len(raw),offset+131072)
            result={'binding':binding,'reference':ref,'offset':offset,'data':base64.b64encode(raw[offset:end]).decode(),'nextCursor':None if end==len(raw) else str(uuid.uuid4()).upper(),'complete':end==len(raw)}
        elif method.endswith('.release'): result={'binding':binding,'released':True}; views.pop(binding['viewID'],None)
        else: raise AssertionError('Unexpected projection fixture method')
    elif method=='remoteEnvironment.command':
        if current['dropCommand']: sys.exit(0)
        result={'environmentID':environment,'receipt':{'commandID':p['id'],'sequence':current['sequence'],'eventCount':0,'acceptedAt':0}}
    elif method=='remoteEnvironment.close':
        emit({'jsonrpc':'2.0','id':frame['id'],'result':{'environmentID':environment}}); break
    else: raise AssertionError('Legacy snapshot or unexpected method reached projected UI')
    if defer_response(frame,result,gate): continue
    emit({'jsonrpc':'2.0','id':frame['id'],'result':result})
"""#
}
@MainActor private func projectionEventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The owned projection fixture did not reach its boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteProjectionStoreKeepsPinnedOlderPagesAndHydratesLatestControlsWithoutNativeSnapshot() async throws {
    let fixture = try ProjectionUIFixture(); defer { fixture.remove() }
    let store = RemoteWorkspaceStore(root: fixture.root, clientFactory: { try fixture.factory($0, $1) })
    do {
        await store.load(); await store.connect(fixture.connection)
        try await projectionEventually { store.selectedThreadExists && !store.projection.isLoading }
        #expect(store.usesProjection && store.snapshot == nil && store.selectedThread == nil && store.canSubmit)
        #expect(store.draft == "Host draft sentinel" && store.projection.messages.count == 300)
        let pinned = try #require(store.projection.browseBinding)
        store.projection.pauseFollowing()
        try fixture.update(sequence: 11)
        store.projection.invalidate(.init(environmentID: fixture.connection.environmentID, hostID: fixture.hostID, sequence: 11))
        try await projectionEventually { store.projection.control?.binding.sequence == 11 && !store.projection.isLoading }
        #expect(store.projection.browseBinding == pinned && store.projection.hasNewerContent)
        await store.projection.loadMore(.messages)
        #expect(store.projection.messages.count == 512 && store.projection.messageWindowStart == 88)
        #expect(store.projection.messages.first?.id == "message-88" && store.projection.messages.last?.id == "message-599")
        #expect(store.projection.messagesComplete && !store.projection.followsLatest)
        store.setDraft("Local newer draft", threadID: fixture.thread.id)
        await store.projection.followLatest()
        #expect(store.projection.browseBinding?.sequence == 11 && store.projection.messages.count == 300)
        #expect(store.draft == "Local newer draft")
        #expect(try !fixture.methods().contains(RemoteEnvironmentProtocol.snapshotMethod))
        await store.shutdown()
        #expect(store.projection.messages.count == 300 && !store.projection.connected && !store.canWrite)
    } catch { await store.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteProjectionStoreUncertainSubmitPreservesPrivateDraftWithoutLegacyRefreshOrReplay() async throws {
    let fixture = try ProjectionUIFixture(); defer { fixture.remove() }
    let store = RemoteWorkspaceStore(root: fixture.root, clientFactory: { try fixture.factory($0, $1) })
    do {
        await store.connect(fixture.connection)
        try await projectionEventually { store.canSubmit && !store.projection.isLoading }
        let text = "Private projected draft sentinel"
        store.setDraft(text, threadID: fixture.thread.id); try fixture.update(drop: true)
        await store.submit()
        #expect(store.pending != nil && store.draft == text)
        #expect(try fixture.methods().filter { $0 == RemoteEnvironmentProtocol.commandMethod }.count == 1)
        #expect(try !fixture.methods().contains(RemoteEnvironmentProtocol.snapshotMethod))
        await store.shutdown()
        let drafts = try await RemoteEnvironmentDraftStore(root: fixture.root.appendingPathComponent("Drafts")).load(environmentID: fixture.connection.environmentID)
        #expect(drafts[fixture.thread.id] == text)
    } catch { await store.shutdown(); throw error }
}

@Test @MainActor
func remoteProjectionPagesRejectMixedBindingsGapsAndFalseCompleteness() throws {
    let binding = RemoteProjectionBinding(environmentID: UUID(), hostID: UUID(), viewID: UUID(), sequence: 8, fingerprint: String(repeating: "a", count: 64), scope: .catalog)
    let row = RemoteProjectSummary(id: UUID(), name: .init(preview: "Summary", complete: true), workspacePath: "/remote")
    #expect(throws: RemoteProjectionFailure.self) { try RemoteProjectionStore.validate(.init(binding: binding, offset: 1, items: [row], totalCount: 2, complete: true), binding: binding, offset: 0) }
    #expect(throws: RemoteProjectionFailure.self) { try RemoteProjectionStore.validate(.init(binding: binding, items: [row,row], totalCount: 2, complete: true), binding: binding, offset: 0) }
    #expect(throws: RemoteProjectionFailure.self) { try RemoteProjectionStore.validate(.init(binding: binding, items: [row], totalCount: 2, complete: true), binding: binding, offset: 0) }
}

@Test @MainActor
func remoteProjectionTextWindowCarriesIncompleteUnicodeScalarsWithoutReplacement() throws {
    let literal = "A😇éकZ", data = Data(literal.utf8)
    for offset in 0...data.count {
        let visible = try RemoteProjectionTextReader.decodeWindow(data.prefix(offset), complete: offset == data.count)
        #expect(!visible.contains("�") && literal.hasPrefix(visible))
    }
    #expect(try RemoteProjectionTextReader.decodeWindow(data, complete: true) == literal)
    #expect(throws: RemoteProjectionFailure.self) { try RemoteProjectionTextReader.decodeWindow(Data([0xff]), complete: true) }
}


@Test(.timeLimit(.minutes(1))) @MainActor
func remoteProjectionCurrentCapturedStopAndApprovalStayAvailableDuringContinuousInvalidations() async throws {
    let fixture = try ProjectionUIFixture(); defer { fixture.remove() }
    let (runID, runtimeID, request) = try fixture.busy()
    let store = RemoteWorkspaceStore(root: fixture.root, clientFactory: { try fixture.factory($0, $1) })
    do {
        await store.connect(fixture.connection)
        try await projectionEventually { store.projection.control?.requests.count == 1 && !store.projection.isLoading }
        store.projection.pauseFollowing()
        // Every event is newer than the fully hydrated control. This must not
        // disable exact captured Stop/approval while another read is coalesced.
        for sequence in 11...40 {
            store.projection.invalidate(.init(environmentID: fixture.connection.environmentID, hostID: fixture.hostID, sequence: Int64(sequence)))
            #expect(store.canWrite)
        }
        try fixture.update(sequence: 40)
        await store.stopProjected()
        await store.respondProjected(request, response: .decision(false))
        let commands = try fixture.commands()
        #expect(commands.count == 2)
        #expect(commands[0].command == .stop(threadID: fixture.thread.id, runID: runID, runtimeID: runtimeID))
        #expect(commands[1].command == .respond(threadID: fixture.thread.id, runID: runID, runtimeID: runtimeID, request: request, response: .decision(false)))
        #expect(store.snapshot == nil && store.draft == "Host draft sentinel")
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteProjectionOffscreenConversationAndRecoveryFitBothAppearancesWithoutImplicitRPC() async throws {
    _ = NSApplication.shared
    let fixture = try ProjectionUIFixture(); defer { fixture.remove() }
    let store = RemoteWorkspaceStore(root: fixture.root, clientFactory: { try fixture.factory($0, $1) })
    do {
        await store.connect(fixture.connection)
        try await projectionEventually { store.projection.control != nil && !store.projection.isLoading }
        let before = try fixture.methods()
        let operation = RemoteOperationSummary(id: UUID(), kind: .checkpointRestore, projectID: fixture.thread.projectID, threadID: fixture.thread.id,
            phase: "unconfirmed", updatedAt: Date(), title: .init(preview: "Remote restore outcome", complete: true),
            error: .init(preview: "Inspect the exact saved result before continuing.", complete: true), acknowledged: false, cancelRequested: false,
            actions: [RemoteOperationAction.inspectRestore.rawValue: .init(allowed: true), RemoteOperationAction.acknowledgeRestore.rawValue: .init(allowed: true)],
            fingerprint: String(repeating: "b", count: 64), details: [.init(label: "Workspace", value: .init(preview: "/remote/projection-fixture", complete: true))])
        for scheme in [ColorScheme.light, .dark] {
            for bounds in [CGSize(width: 480, height: 560), CGSize(width: 640, height: 680)] {
                let views: [AnyView] = [AnyView(RemoteProjectedConversationView(store: store, chooseWorktree: { Issue.record("Layout cannot choose a worktree") })),
                    AnyView(ScrollView { RemoteProjectedOperationCard(operation: operation) { _ in Issue.record("Layout cannot recover an operation") }.padding(12) })]
                for view in views {
                    let hosting = NSHostingController(rootView: view.environment(\.colorScheme, scheme))
                    let size = hosting.sizeThatFits(in: bounds)
                    #expect(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0)
                    #expect(size.width <= bounds.width + 1 && size.height <= bounds.height + 1)
                    hosting.view.frame = CGRect(origin: .zero, size: size); hosting.view.layoutSubtreeIfNeeded()
                    #expect(hosting.view.window == nil)
                }
            }
        }
        #expect(try fixture.methods() == before)
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}


@Test(.timeLimit(.minutes(1))) @MainActor
func remoteProjectionGiantUnicodeTextUsesExactBoundedWindowsAndVerifiesWholeDocumentHash() async throws {
    let fixture = try ProjectionUIFixture(); defer { fixture.remove() }
    let (reference, literal) = try fixture.giantMessageAndDraft()
    let store = RemoteWorkspaceStore(root: fixture.root, clientFactory: { try fixture.factory($0, $1) })
    do {
        await store.connect(fixture.connection)
        try await projectionEventually { store.projection.browseBinding != nil && !store.projection.isLoading }
        let binding = try #require(store.projection.browseBinding), reader = RemoteProjectionTextReader()
        var pages = 0
        while !reader.complete {
            await reader.load(reference: reference, binding: binding, store: store.projection); pages += 1
            #expect(reader.error == nil && !reader.text.contains("�"))
            #expect(reader.text.utf8.count <= 1_048_576)
            guard reader.error == nil, pages <= 32 else { throw CoincideError("The owned giant text fixture did not advance.") }
        }
        #expect(pages > 8 && reader.verified && reader.offset == reference.totalBytes && reader.windowStart > 0)
        #expect(literal.hasSuffix(reader.text))
        #expect(reader.windowStart + reader.text.utf8.count == reference.totalBytes)
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteProjectionOversizedHostDraftCannotCreatePendingIntentUntilExplicitLocalReplacement() async throws {
    let fixture = try ProjectionUIFixture(); defer { fixture.remove() }
    let (_, literal) = try fixture.giantMessageAndDraft(oversizedDraft: true)
    let store = RemoteWorkspaceStore(root: fixture.root, clientFactory: { try fixture.factory($0, $1) })
    do {
        await store.connect(fixture.connection)
        try await projectionEventually { store.projection.control != nil && !store.projection.isLoading }
        #expect(store.draft == literal && store.draftExceedsLocalLimit && !store.canSubmit)
        await store.submit()
        let commands = try fixture.commands()
        #expect(store.pending == nil && commands.isEmpty)
        #expect(store.drafts[fixture.thread.id] == nil)
        store.replaceOversizedDraft()
        #expect(store.draft == "" && !store.draftExceedsLocalLimit && store.projection.control?.draft == literal)
        store.setDraft("Short replacement draft", threadID: fixture.thread.id)
        #expect(store.canSubmit && store.draft == "Short replacement draft")
        await store.shutdown()
        let saved = try await RemoteEnvironmentDraftStore(root: fixture.root.appendingPathComponent("Drafts")).load(environmentID: fixture.connection.environmentID)
        #expect(saved[fixture.thread.id] == "Short replacement draft")
    } catch { await store.shutdown(); throw error }
}


@Test(.timeLimit(.minutes(1))) @MainActor
func remoteProjectionCatalogOnlyConnectionRetainsObservedFloorAcrossReplacementClient() async throws {
    let fixture = try ProjectionUIFixture(); defer { fixture.remove() }
    try fixture.emptyCatalog(sequence: 42)
    let store = RemoteWorkspaceStore(root: fixture.root, clientFactory: { try fixture.factory($0, $1) })
    do {
        await store.connect(fixture.connection)
        #expect(store.isConnected && store.projection.catalogBinding?.sequence == 42 && store.projection.control == nil)
        await store.disconnect(); try fixture.update(sequence: 41)
        await store.reconnect()
        #expect(!store.isConnected && store.errorMessage != nil)
        #expect(try fixture.commands().isEmpty)
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteProjectionDeletedCatalogSelectionKeepsGlobalProjectCommandsAvailableWithoutPartialThreadControls() async throws {
    let fixture = try ProjectionUIFixture(); defer { fixture.remove() }
    let staleID = try fixture.addStaleCatalogRow()
    let store = RemoteWorkspaceStore(root: fixture.root, clientFactory: { try fixture.factory($0, $1) })
    do {
        await store.connect(fixture.connection)
        try await projectionEventually { store.projection.control != nil && !store.projection.isLoading }
        #expect(store.projection.threads.contains { $0.id == staleID })
        store.selectThread(staleID)
        try await projectionEventually { store.projection.control == nil && store.projection.errorMessage != nil && !store.projection.isLoading }
        #expect(store.isConnected && store.canWrite && !store.canSubmit && store.selectedConfiguration == nil)
        let project = UUID()
        #expect(await store.perform(.addProject(id: project, path: "/remote/new-project", title: nil)))
        let commands = try fixture.commands()
        #expect(commands.count == 1 && commands[0].command == .addProject(id: project, path: "/remote/new-project", title: nil))
        #expect(store.pending == nil && store.snapshot == nil)
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}


private actor ProjectionDiffBoundary {
    private var started = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        started = true; observers.forEach { $0.resume() }; observers = []
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func entered() async { if !started { await withCheckedContinuation { observers.append($0) } } }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteProjectionCheckpointDiffRefusesLatePatchAfterBrowseBindingReplacement() async throws {
    let fixture = try ProjectionUIFixture(); defer { fixture.remove() }
    let run = try fixture.checkpointRun(), boundary = ProjectionDiffBoundary()
    let store = RemoteWorkspaceStore(root: fixture.root, clientFactory: { try fixture.factory($0, $1) })
    var diffTask: Task<Void, Never>?
    var model: RemoteCheckpointWorkspace?
    do {
        await store.connect(fixture.connection)
        try await projectionEventually { store.projection.runs.count == 1 && !store.projection.isLoading }
        let target = try #require(store.pullRequestTarget), baseline = run.checkpointAttempts[0], post = run.checkpointAttempts[1], rootID = UUID()
        let transport = RemoteCheckpointTransport(bind: { target in
            .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID, configuration: target.configuration, rootID: rootID)
        }, read: { request in
            guard request.query == .runDiff(runID: run.id, baselineAttemptID: baseline.id, postRunAttemptID: post.id, maxBytes: 262_144) else { throw RemoteCheckpointFailure(.invalidRequest) }
            await boundary.pause()
            return .init(target: request.target, value: .diff(.init(runID: run.id, baselineAttemptID: baseline.id,
                postRunAttemptID: post.id, patch: "Exact captured diff", truncated: false)))
        }, review: { _ in throw RemoteCheckpointFailure(.invalidRequest) }, discard: { _ in throw RemoteCheckpointFailure(.invalidRequest) })
        let workspace = RemoteCheckpointWorkspace(target: target); model = workspace
        workspace.updateProjected(target: target, projection: store.projection, transport: transport, supported: true,
            canWrite: true, canMutate: true, perform: { _ in Issue.record("Diff must not submit a mutation"); return false }, canRestore: { _ in true })
        let previous = try #require(store.projection.browseBinding)
        diffTask = Task { await workspace.loadDiff(runID: run.id) }
        await boundary.entered()
        await store.projection.followLatest()
        #expect(store.projection.browseBinding != previous)
        await boundary.release(); await diffTask?.value
        #expect(workspace.diff == nil)
        await workspace.loadDiff(runID: run.id)
        #expect(workspace.diff?.patch == "Exact captured diff")
        workspace.disconnect(); await workspace.drainReads(); await store.shutdown()
    } catch {
        await boundary.release(); await diffTask?.value; model?.disconnect(); await model?.drainReads(); await store.shutdown(); throw error
    }
}


@Test(.timeLimit(.minutes(1))) @MainActor
func remoteProjectionCatalogRefreshOwnsTokenBeforeOpenAndReleasesOnlyReplacedOrUnusedLeases() async throws {
    let fixture = try ProjectionUIFixture(); defer { fixture.remove() }
    try fixture.emptyCatalog(sequence: 10)
    let store = RemoteWorkspaceStore(root: fixture.root, clientFactory: { try fixture.factory($0, $1) })
    var older: Task<Void, Never>?
    do {
        await store.connect(fixture.connection)
        let original = try #require(store.projection.catalogBinding)
        try fixture.update(sequence: 11); try fixture.hold("catalog-open-11")
        older = Task { await store.projection.refreshLatest() }
        try await projectionEventually { fixture.entered("catalog-open-11") }
        let unused = try fixture.heldBinding("catalog-open-11")
        try fixture.update(sequence: 12)
        await store.projection.refreshLatest()
        let current = try #require(store.projection.catalogBinding)
        #expect(current.sequence == 12 && store.projection.isLoading)
        fixture.release("catalog-open-11"); await older?.value
        #expect(store.projection.catalogBinding == current && !store.projection.isLoading)
        let released = try fixture.releasedViews()
        #expect(released.contains(original.viewID) && released.contains(unused.viewID) && !released.contains(current.viewID))
        #expect(store.errorMessage == nil && store.projection.errorMessage == nil)
        await store.shutdown()
    } catch { fixture.release("catalog-open-11"); await older?.value; await store.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteProjectionCatalogContinuationCannotAppendOldRowsAfterNewCatalogPublication() async throws {
    let fixture = try ProjectionUIFixture(); defer { fixture.remove() }
    try fixture.manyCatalogThreads()
    let store = RemoteWorkspaceStore(root: fixture.root, clientFactory: { try fixture.factory($0, $1) })
    var page: Task<Void, Never>?
    do {
        await store.connect(fixture.connection)
        try await projectionEventually { store.projection.control != nil && !store.projection.isLoading }
        store.selectThread(nil)
        try await projectionEventually { store.projection.selectedThreadID == nil && store.projection.control == nil }
        #expect(store.projection.threads.count == 300 && !store.projection.threadsComplete)
        try fixture.hold("catalog-page-10")
        page = Task { await store.projection.loadThreads() }
        try await projectionEventually { fixture.entered("catalog-page-10") }
        try fixture.update(sequence: 11)
        await store.projection.refreshLatest()
        let current = try #require(store.projection.catalogBinding)
        #expect(current.sequence == 11 && store.projection.isLoading)
        fixture.release("catalog-page-10"); await page?.value
        #expect(store.projection.catalogBinding == current && !store.projection.isLoading)
        #expect(store.projection.threads.count == 300 && store.projection.threadWindowStart == 0 && !store.projection.threadsComplete)
        #expect(store.projection.errorMessage == nil)
        await store.shutdown()
    } catch { fixture.release("catalog-page-10"); await page?.value; await store.shutdown(); throw error }
}
