import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private struct HistoryUIFixtureState: Codable {
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
    var historyReview: RemoteHistoryReview?
    var historyFilesReview: RemoteHistoryReview?
    var historyView: RemoteHistoryOperationView?
    var historyControls: RemoteHistoryThreadControls?
    var historyRecall: RemoteHistoryRecallPayload?
}
private final class HistoryUIFixture: @unchecked Sendable {
    let root: URL, stateURL: URL, script: URL, wire: URL
    let connection: RemoteEnvironmentConnection
    let thread: CodingThread
    let hostID = UUID(), rootID = UUID(), runID = UUID(), operationID = UUID()
    let originalPrompt = "Original recalled prompt 工作 e\u{301}"
    init(provider: ProviderKind = .codex) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-projection-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        stateURL = root.appendingPathComponent("state.json"); script = root.appendingPathComponent("peer.py"); wire = root.appendingPathComponent("wire.jsonl")
        let environment = UUID(), project = WorkspaceProject(path: "/remote/projection-fixture")
        var conversation = CodingThread(project: project); conversation.provider = provider; thread = conversation
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
        let capabilities = RemoteEnvironmentCapabilities(providers: [.codex, .claude, .opencode, .pi], supportsBoundedProjections: true, supportsRemoteHistory: true)
        var state = HistoryUIFixtureState(descriptor: .init(environmentID: environment, label: "Offline projection", capabilities: capabilities), sequence: 10,
            hostID: hostID, projects: [.init(id: project.id, name: .init(preview: "Remote project", complete: true), workspacePath: project.path)],
            threads: [summary], detail: detail, messages: rows, documents: documents)
        let target = RemoteWorkspaceTarget(environmentID: environment, projectID: project.id, threadID: thread.id,
            configuration: .init(thread: thread), rootID: rootID)
        let allowed = RemoteProjectionAvailability(allowed: true)
        let run = RemoteRunSummary(id: runID, origin: .user, status: .completed, startedAt: Date(), endedAt: Date(),
            stopRequested: false, turnCount: 1, checkpointAttempts: [], checkpointAttemptCount: 0, checkpointAttemptsComplete: true,
            checkpointDiff: .init(allowed: false), fork: allowed, rewind: allowed, provider: thread.provider, providerName: thread.providerName,
            model: .init(preview: thread.model, complete: true), permission: thread.permission, workspacePath: thread.workspacePath)
        state.runs = [run]
        func binding(_ id: UUID) -> RemoteHistoryBinding { .init(environmentID: environment, hostID: hostID, leaseID: UUID(), threadID: thread.id, objectID: id, digest: String(repeating: "a", count: 64)) }
        func reviewSummary(files: Bool) -> RemoteHistoryReviewSummary {
            .init(kind: .rewindBeforeRun, runID: runID, reviewedAt: Date(), provider: thread.provider, workspacePath: thread.workspacePath,
                sourceConfiguration: config, targetConfiguration: config, retainedMessageCount: 600, removedMessageCount: 2, removedRunCount: 1,
                targetThreadID: nil, suggestedTitle: .init(preview: "Retained fork title", complete: true),
                files: files ? .init(id: UUID(), checkpointRunID: runID, attemptID: UUID(), stage: .baseline, affectedPathCount: 2,
                    patch: .init(preview: "Reviewed patch 工作", complete: true), patchTruncated: true) : nil,
                recallPromptOnSuccess: true, restoreFiles: allowed,
                mutatingPaths: files ? [thread.workspacePath, thread.workspacePath + "/.git"] : [],
                coordinationPaths: files ? [thread.workspacePath + "/.git"] : [],
                details: [.init(label: "Boundary", value: .init(preview: "Exact selected opening input", complete: true))])
        }
        let keepID = UUID(), filesID = UUID(), keepBinding = binding(keepID), filesBinding = binding(filesID)
        state.historyReview = .init(target: target, id: keepID, digest: keepBinding.digest, binding: keepBinding, value: reviewSummary(files: false))
        state.historyFilesReview = .init(target: target, id: filesID, digest: filesBinding.digest, binding: filesBinding, value: reviewSummary(files: true))
        let op = RemoteOperationSummary(id: operationID, kind: .conversationHistory, projectID: project.id, threadID: thread.id, runID: runID,
            phase: "applied", updatedAt: Date(), title: .init(preview: "Rewind before run", complete: true), acknowledged: false, cancelRequested: false,
            actions: ["recallPrompt": allowed, "dismissRecall": allowed], fingerprint: String(repeating: "b", count: 64), workspacePaths: [thread.workspacePath])
        state.historyView = .init(binding: binding(operationID), operation: op, kind: .rewindBeforeRun, provider: thread.provider,
            filesPhase: nil, filesAcknowledged: false, needsPromptRecall: true, recalled: false, recallDismissed: false, piSessionID: nil, piRequests: nil)
        state.historyControls = .init(claudeSelectionID: nil, claudeConsumerRunID: nil, piIntentID: nil, piConsumerRunID: nil,
            canInspectClaudeResume: false, canInspectPiFresh: false)
        let originalData = Data(originalPrompt.utf8), textID = UUID()
        state.documents[textID.uuidString] = originalData
        let originalRef = RemoteProjectionContentReference(id: textID, kind: .text, totalBytes: originalData.count, digest: RemoteProjectionProtocol.digest(originalData))
        state.historyRecall = .init(binding: binding(operationID), operationID: operationID, runID: runID, messageID: "opening-user",
            text: .init(preview: "Original", complete: false, content: originalRef), attachments: attachments)
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
    func state() throws -> HistoryUIFixtureState { try JSONDecoder().decode(HistoryUIFixtureState.self, from: Data(contentsOf: stateURL)) }
    func dropNextCommand() throws { var value = try state(); value.dropCommand = true; try JSONEncoder().encode(value).write(to: stateURL, options: .atomic) }
    func holdControls() throws { try? FileManager.default.removeItem(at: root.appendingPathComponent("release-controls")); try? FileManager.default.removeItem(at: root.appendingPathComponent("entered-controls")); try Data().write(to: root.appendingPathComponent("hold-controls")) }
    func releaseControls() { try? Data().write(to: root.appendingPathComponent("release-controls")) }
    var controlsEntered: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("entered-controls").path) }
    func publishFork(_ review: RemoteHistoryReview) throws {
        var value = try state(); value.sequence += 1
        let old = value.historyView!, summary = RemoteOperationSummary(id: review.id, kind: .conversationHistory,
            projectID: review.target.projectID, threadID: review.target.threadID, runID: review.value.runID, targetThreadID: review.value.targetThreadID,
            phase: "applied", updatedAt: Date(), title: .init(preview: "Fork applied", complete: true), acknowledged: false, cancelRequested: false,
            actions: ["openConversation": .init(allowed: true)], fingerprint: String(repeating: "d", count: 64), workspacePaths: [review.target.workspacePath])
        value.historyView = .init(binding: .init(environmentID: old.binding.environmentID, hostID: old.binding.hostID, leaseID: UUID(),
            threadID: review.target.threadID, objectID: review.id, digest: String(repeating: "b", count: 64)), operation: summary,
            kind: .forkAfterRun, provider: review.value.provider, filesPhase: nil, filesAcknowledged: false, needsPromptRecall: false,
            recalled: false, recallDismissed: false, piSessionID: nil, piRequests: nil)
        try JSONEncoder().encode(value).write(to: stateURL, options: .atomic)
    }
    func releaseRecall() { try? Data().write(to: root.appendingPathComponent("release-recall")) }
    func holdRecall() throws { try Data().write(to: root.appendingPathComponent("hold-recall")) }
    var recallEntered: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("entered-recall").path) }
    func commands() throws -> [RemoteEnvironmentCommandRequest] {
        guard FileManager.default.fileExists(atPath: wire.path) else { return [] }
        return try Data(contentsOf: wire).split(separator: 10).compactMap { line in
            let frame = try JSONDecoder().decode(JSONValue.self, from: Data(line))
            guard frame["method"].string == RemoteEnvironmentProtocol.commandMethod else { return nil }
            return try RemoteEnvironmentProtocol.decode(RemoteEnvironmentCommandRequest.self, from: frame["params"])
        }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    private static let peer = #"""
import base64,copy,json,os,sys,threading,time,uuid
from pathlib import Path
root=Path(sys.argv[1]); assert root.name.startswith('coincide-projection-ui-') and os.stat(root).st_mode&0o077==0
views={}; cursors={}; lock=threading.Lock()
def emit(frame):
    with lock: print(json.dumps(frame),flush=True)
def state(): return json.loads((root/'state.json').read_text())
def page(binding,items,cursor=None):
    offset=0 if cursor is None else cursors[cursor]; end=min(len(items),offset+200); next=None
    if end<len(items): next=str(uuid.uuid5(uuid.NAMESPACE_URL,binding['viewID']+str(items[0].get('id','empty'))+str(end))).upper(); cursors[next]=end
    return {'binding':binding,'offset':offset,'items':items[offset:end],'totalCount':len(items),'nextCursor':next,'complete':end==len(items)}
def history_binding(template,target):
    result=copy.deepcopy(template)
    result['leaseID']=str(uuid.uuid5(uuid.NAMESPACE_URL,result['objectID']+json.dumps(target,sort_keys=True))).upper()
    return result
for line in sys.stdin:
    f=json.loads(line); m=f['method']; p=f.get('params',{}); s=state(); environment=s['descriptor']['environmentID']
    with (root/'wire.jsonl').open('a') as wire: wire.write(json.dumps(f)+'\n')
    if m=='remoteEnvironment.describe': result=s['descriptor']
    elif m in ('remoteEnvironment.projection.open','remoteEnvironment.projection.subscribe'):
        binding={'environmentID':environment,'hostID':s['hostID'],'viewID':str(uuid.uuid4()).upper(),'sequence':s['sequence'],'fingerprint':'a'*64,'scope':p.get('scope',{'catalog':{}})}
        views[binding['viewID']]=copy.deepcopy(s); result=binding
    elif m.startswith('remoteEnvironment.projection.'):
        b=p['binding']; source=views[b['viewID']]
        if m.endswith('.catalog'):
            kind='projects' if 'projects' in p['query'] else 'threads'; result={kind:{'_0':page(b,source[kind],p.get('cursor'))}}
        elif m.endswith('.thread'): result={'binding':b,'thread':source['detail']}
        elif m.endswith('.messages'): result=page(b,source['messages'],p.get('cursor'))
        elif m.endswith('.runs'): result=page(b,source['runs'],p.get('cursor'))
        elif m.endswith('.operations'): result=page(b,[source['historyView']['operation']])
        elif m.endswith('.content'):
            ref=p['reference']; raw=base64.b64decode(source['documents'][ref['id']]); offset=p['offset']; end=min(len(raw),offset+131072)
            result={'binding':b,'reference':ref,'offset':offset,'data':base64.b64encode(raw[offset:end]).decode(),'nextCursor':None if end==len(raw) else str(uuid.uuid4()).upper(),'complete':end==len(raw)}
        elif m.endswith('.release'): result={'binding':b,'released':True}; views.pop(b['viewID'],None)
        else: raise AssertionError('Unexpected projection fixture method')
    elif m=='remoteEnvironment.history.bind': result=copy.deepcopy(p); result['rootID']=s['historyReview']['target']['rootID']
    elif m=='remoteEnvironment.history.read':
        target=p['target']; query=p['query']; kind=next(iter(query)); q=query[kind]; gate=False; gate_name='recall'
        if kind=='controls':
            value={'controls':{'_0':s['historyControls']}}; gate_name='controls'; gate=(root/'hold-controls').exists() and not (root/'release-controls').exists()
        elif kind=='operation':
            operation=copy.deepcopy(s['historyView']); operation['binding']=history_binding(operation['binding'],target); value={'operation':{'_0':operation}}
        elif kind=='recall':
            recall=copy.deepcopy(s['historyRecall']); recall['binding']=history_binding(recall['binding'],target); value={'recall':{'_0':recall}}
        elif kind=='content':
            ref=q['reference']; raw=base64.b64decode(s['documents'][ref['id']]); offset=q['offset']; end=min(len(raw),offset+131072)
            value={'content':{'_0':{'binding':q['binding'],'reference':ref,'offset':offset,'data':base64.b64encode(raw[offset:end]).decode(),'nextCursor':None if end==len(raw) else str(uuid.uuid4()).upper(),'complete':end==len(raw)}}}
            gate=ref['id']==s['historyRecall']['text']['content']['id'] and (root/'hold-recall').exists() and not (root/'release-recall').exists()
        elif kind=='release': value={'released':{'_0':True}}
        else: raise AssertionError('Unexpected history read query')
        result={'target':target,'value':value}
        if gate:
            (root/('entered-'+gate_name)).touch()
            def reply(identifier=f['id'],payload=result,owned_gate=gate_name):
                deadline=time.monotonic()+5
                while not (root/('release-'+owned_gate)).exists() and time.monotonic()<deadline:time.sleep(.005)
                emit({'jsonrpc':'2.0','id':identifier,'result':payload})
            threading.Thread(target=reply,daemon=True).start(); continue
    elif m=='remoteEnvironment.history.discard': result={'request':p,'discarded':True}
    elif m=='remoteEnvironment.command':
        (root/'original-command.json').write_text(json.dumps(p))
        if s['dropCommand']:
            s['dropCommand']=False;(root/'state.json').write_text(json.dumps(s));sys.exit(0)
        result={'environmentID':environment,'receipt':{'commandID':p['id'],'sequence':s['sequence'],'eventCount':0,'acceptedAt':0}}
    elif m=='remoteEnvironment.receipt':
        assert p==json.loads((root/'original-command.json').read_text())
        result={'environmentID':environment,'receipt':{'commandID':p['id'],'sequence':s['sequence'],'eventCount':0,'acceptedAt':0}}
    elif m=='remoteEnvironment.close':emit({'jsonrpc':'2.0','id':f['id'],'result':{'environmentID':environment}});break
    else: raise AssertionError('Unexpected history fixture method')
    emit({'jsonrpc':'2.0','id':f['id'],'result':result})
"""#
}

@MainActor private func historyEventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The owned history UI fixture did not reach its boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private actor HistoryUIBoundary {
    private var started = false, released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async { started = true; observers.forEach { $0.resume() }; observers = []; if !released { await withCheckedContinuation { waiter = $0 } } }
    func entered() async { if !started { await withCheckedContinuation { observers.append($0) } } }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
private actor HistoryUIPeer {
    let state: HistoryUIFixtureState
    private var rootID = UUID()
    private var binds = 0
    private var reviews: [RemoteHistoryReviewRequest] = []
    private var discards: [RemoteHistoryDiscardRequest] = []
    private var releases: [RemoteWorkspaceTarget] = []
    private var targets: [UUID: RemoteWorkspaceTarget] = [:]
    private var reviewGate: HistoryUIBoundary?
    private var latestFork: RemoteHistoryReview?
    func completedFork() -> RemoteHistoryReview? { latestFork }
    private var actionKeys: [RemoteOperationAction] = [.recallPrompt, .dismissRecall]
    private var sessionID: UUID?
    private var requests: [RuntimeRequest] = []
    private var controlsValue: RemoteHistoryThreadControls
    private var freshState = RemoteHistoryPiFreshInspection.State.unwritten
    init(_ state: HistoryUIFixtureState) {
        self.state = state
        controlsValue = state.historyControls!
    }
    nonisolated var transport: RemoteHistoryTransport {
        .init(bind: { await self.bind($0) }, read: { try await self.read($0) }, review: { try await self.review($0) },
            discard: { await self.discard($0) }, document: { try await self.document($0, binding: $1, target: $2) })
    }
    func setGate(_ gate: HistoryUIBoundary) { reviewGate = gate }
    func setActions(_ keys: [RemoteOperationAction], session: UUID? = nil, requests: [RuntimeRequest] = []) { actionKeys = keys; sessionID = session; self.requests = requests }
    func setControls(_ value: RemoteHistoryThreadControls) { controlsValue = value }
    func setFresh(_ value: RemoteHistoryPiFreshInspection.State) { freshState = value }
    func rotateRoot() -> UUID { rootID = UUID(); return rootID }
    func counts() -> [Int] { [binds, reviews.count, discards.count, releases.count] }
    func releaseTargets() -> [RemoteWorkspaceTarget] { releases }
    func bind(_ target: RemoteWorkspaceTarget) -> RemoteWorkspaceTarget {
        binds += 1
        return .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID,
            configuration: target.configuration, rootID: rootID)
    }
    func review(_ request: RemoteHistoryReviewRequest) async throws -> RemoteHistoryReview {
        reviews.append(request)
        let base = request.files == .keep ? state.historyReview! : state.historyFilesReview!, old = base.value
        let id = UUID(), digest = String(repeating: "a", count: 64)
        let binding = RemoteHistoryBinding(environmentID: request.target.environmentID, hostID: state.hostID, leaseID: UUID(),
            threadID: request.target.threadID, objectID: id, digest: digest)
        let value = RemoteHistoryReview(target: request.target, id: id, digest: digest, binding: binding,
            value: .init(kind: request.kind, runID: request.runID, reviewedAt: old.reviewedAt, provider: request.target.configuration.provider,
                workspacePath: request.target.workspacePath, sourceConfiguration: old.sourceConfiguration, targetConfiguration: old.targetConfiguration,
                retainedMessageCount: old.retainedMessageCount, removedMessageCount: old.removedMessageCount, removedRunCount: old.removedRunCount,
                targetThreadID: request.kind == .forkAfterRun ? UUID() : nil, suggestedTitle: old.suggestedTitle, files: old.files,
                recallPromptOnSuccess: request.recallPromptOnSuccess, restoreFiles: old.restoreFiles,
                mutatingPaths: old.mutatingPaths, coordinationPaths: old.coordinationPaths, details: old.details, warnings: old.warnings))
        targets[binding.leaseID] = request.target
        if request.kind == .forkAfterRun { latestFork = value }
        if let reviewGate { await reviewGate.pause() }
        return value
    }
    func discard(_ request: RemoteHistoryDiscardRequest) -> RemoteHistoryDiscardResult {
        discards.append(request); return .init(request: request, discarded: true)
    }
    private func operation(_ target: RemoteWorkspaceTarget, id requestedID: UUID? = nil, maintenance: Bool) throws -> RemoteHistoryOperationView {
        let original = state.historyView!, old = original.operation
        let id = requestedID ?? old.id, fork = latestFork.flatMap { $0.id == id ? $0 : nil }
        let binding = RemoteHistoryBinding(environmentID: target.environmentID, hostID: state.hostID, leaseID: UUID(),
            threadID: target.threadID, objectID: id, digest: String(repeating: "b", count: 64))
        targets[binding.leaseID] = target
        let summary = RemoteOperationSummary(id: id, kind: .conversationHistory, projectID: target.projectID, threadID: target.threadID,
            runID: old.runID, targetThreadID: fork?.value.targetThreadID, phase: actionKeys.contains(.clearMaintenance) || actionKeys.contains(.keepOriginal) ? "unconfirmed" : "applied", updatedAt: old.updatedAt,
            title: old.title, error: state.historyRecall!.text, acknowledged: false, cancelRequested: false,
            actions: Dictionary(uniqueKeysWithValues: (fork == nil ? actionKeys : [.openConversation]).map { ($0.rawValue, .init(allowed: true)) }), fingerprint: old.fingerprint,
            details: old.details, workspacePaths: old.workspacePaths)
        let requestRef: RemoteProjectionContentReference?
        if requests.isEmpty { requestRef = nil }
        else {
            let data = try RemoteHistoryProtocol.payload(requests)
            requestRef = .init(id: UUID(), kind: .runtimeRequests, totalBytes: data.count, digest: RemoteProjectionProtocol.digest(data))
            requestDocuments[requestRef!.id] = data
        }
        return .init(binding: binding, operation: summary, kind: fork?.value.kind ?? original.kind, provider: target.configuration.provider,
            filesPhase: original.filesPhase, filesAcknowledged: false, needsPromptRecall: original.needsPromptRecall,
            recalled: false, recallDismissed: false, piSessionID: sessionID, piRequests: requestRef,
            maintenanceClaim: maintenance ? .init(id: UUID(), digest: String(repeating: "c", count: 64)) : nil)
    }
    private var requestDocuments: [UUID: Data] = [:]
    func read(_ request: RemoteHistoryReadRequest) throws -> RemoteHistoryReadResult {
        switch request.query {
        case .controls: return .init(target: request.target, value: .controls(controlsValue))
        case .operation(let id): return .init(target: request.target, value: .operation(try operation(request.target, id: id, maintenance: false)))
        case .maintenance: return .init(target: request.target, value: .operation(try operation(request.target, maintenance: true)))
        case .piFresh(let intent, let consumer): return .init(target: request.target, value: .piFresh(.init(intentID: intent, consumerRunID: consumer, state: freshState)))
        case .release(let binding):
            if let expected = targets[binding.leaseID] { guard try RemoteHistoryProtocol.payload(expected) == RemoteHistoryProtocol.payload(request.target) else { throw RemoteHistoryFailure(.staleReview) } }
            releases.append(request.target); targets.removeValue(forKey: binding.leaseID)
            return .init(target: request.target, value: .released(true))
        case .content(let binding, let reference, let offset, _):
            let bytes = try document(reference, binding: binding, target: request.target), end = min(bytes.count, offset + RemoteHistoryProtocol.maximumContentChunkBytes)
            return .init(target: request.target, value: .content(.init(binding: binding, reference: reference, offset: offset,
                data: Data(bytes[offset..<end]), nextCursor: end == bytes.count ? nil : UUID(), complete: end == bytes.count)))
        default: throw RemoteHistoryFailure(.invalidRequest)
        }
    }
    func document(_ reference: RemoteProjectionContentReference, binding: RemoteHistoryBinding, target: RemoteWorkspaceTarget) throws -> Data {
        guard let expected = targets[binding.leaseID], try RemoteHistoryProtocol.payload(expected) == RemoteHistoryProtocol.payload(target),
              let bytes = requestDocuments[reference.id] ?? state.documents[reference.id.uuidString], bytes.count == reference.totalBytes,
              RemoteProjectionProtocol.digest(bytes) == reference.digest else { throw RemoteHistoryFailure(.staleReview) }
        return bytes
    }
}
@MainActor private final class HistoryUICommands {
    var values: [RemoteEnvironmentCommand] = []
    var restoreAllowed = true
    var accepted = true
    var opened: [UUID] = []
    var after: (@MainActor (RemoteEnvironmentCommand) async -> Void)?
    func perform(_ value: RemoteEnvironmentCommand) async -> Bool { values.append(value); await after?(value); return accepted }
}

@MainActor private func connectedHistoryRoot(_ fixture: HistoryUIFixture) async throws -> RemoteWorkspaceStore {
    let root = RemoteWorkspaceStore(root: fixture.root, clientFactory: { try fixture.factory($0, $1) })
    await root.connect(fixture.connection)
    do { try await historyEventually { root.projection.control != nil && !root.projection.isLoading }; return root }
    catch { await root.shutdown(); throw error }
}
@MainActor private func selectHistory(_ store: RemoteHistoryStore, root: RemoteWorkspaceStore, peer: HistoryUIPeer, commands: HistoryUICommands) async {
    await store.select(target: root.pullRequestTarget, projection: root.projection, transport: peer.transport, supported: true, canWrite: true,
        canRestoreFiles: { _ in commands.restoreAllowed }, perform: { await commands.perform($0) }, openConversation: { commands.opened.append($0) })
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteHistoryReviewedKeepAndSeparateFileAcceptanceUseExactOpaqueClaimsAndDirtyPreflight() async throws {
    let f = try HistoryUIFixture(); defer { f.remove() }
    let root = try await connectedHistoryRoot(f), peer = HistoryUIPeer(try f.state()), store = RemoteHistoryStore(), commands = HistoryUICommands()
    await selectHistory(store, root: root, peer: peer, commands: commands)
    let model = try #require(store.current)
    await model.prepare(runID: f.runID, kind: .rewindBeforeRun)
    let keep = try #require(model.keepReview)
    #expect(keep.value.files == nil && model.canAccept(keep))
    await model.prepare(runID: f.runID, kind: .rewindBeforeRun, files: .restore)
    let files = try #require(model.filesReview)
    #expect(files.id != keep.id && files.value.files?.affectedPathCount == 2)
    commands.restoreAllowed = false
    #expect(!model.canAccept(files) && model.canAccept(keep))
    await model.accept(files); #expect(commands.values.isEmpty)
    commands.restoreAllowed = true
    await model.accept(files)
    #expect(commands.values == [.history(target: files.target, action: .begin(reviewID: files.id, digest: files.digest, title: nil))])
    await store.shutdown(); await root.shutdown()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteHistoryLateCancelledReviewIsDisposedAndSameCaptureReconnectRebindsNewPhysicalRoot() async throws {
    let f = try HistoryUIFixture(); defer { f.remove() }
    let root = try await connectedHistoryRoot(f), peer = HistoryUIPeer(try f.state()), store = RemoteHistoryStore(), commands = HistoryUICommands(), gate = HistoryUIBoundary()
    await selectHistory(store, root: root, peer: peer, commands: commands)
    let model = try #require(store.current)
    await peer.setGate(gate)
    let preparing = Task { await model.prepare(runID: f.runID, kind: .rewindBeforeRun) }
    await gate.entered(); model.disconnect(); await gate.release(); let result = await preparing.value
    await model.drain()
    let counts = await peer.counts()
    #expect(result == nil && model.keepReview == nil && counts[2] == 1)
    #expect(model.target.rootID == nil && model.operationViews.isEmpty && model.controls == nil)
    let newRoot = await peer.rotateRoot()
    await selectHistory(store, root: root, peer: peer, commands: commands)
    await model.prepare(runID: f.runID, kind: .rewindBeforeRun)
    #expect(model.target.rootID == newRoot && model.keepReview != nil)
    #expect(commands.values.isEmpty)
    await store.shutdown(); await root.shutdown()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteHistoryReadonlyLeaseKeepsOriginalRootlessTargetAfterReviewBindsAndDisconnectReleasesExactTarget() async throws {
    let f = try HistoryUIFixture(); defer { f.remove() }
    let root = try await connectedHistoryRoot(f), peer = HistoryUIPeer(try f.state()), store = RemoteHistoryStore(), commands = HistoryUICommands()
    await selectHistory(store, root: root, peer: peer, commands: commands)
    let model = try #require(store.current), operation = try #require(model.operationViews[f.operationID]), reference = try #require(operation.operation.error?.content)
    #expect(model.target.rootID == nil)
    await model.prepare(runID: f.runID, kind: .rewindBeforeRun)
    #expect(model.target.rootID != nil)
    let bytes = try await model.document(reference, binding: operation.binding)
    #expect(String(data: bytes, encoding: .utf8) == f.originalPrompt)
    let leased = try await model.leasedRead(.content(binding: operation.binding, reference: reference, offset: 0, cursor: nil))
    if case .content(let content) = leased { #expect(content.data == bytes) } else { Issue.record("Expected exact history content") }
    await store.shutdown()
    let released = await peer.releaseTargets()
    #expect(released.contains { $0.rootID == nil && $0.threadID == f.thread.id })
    await root.shutdown()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteHistoryMaintenanceClearRequiresExplicitExactInspectedClaimAndSurvivesUnrelatedRefresh() async throws {
    let f = try HistoryUIFixture(provider: .opencode); defer { f.remove() }
    let root = try await connectedHistoryRoot(f), peer = HistoryUIPeer(try f.state()), store = RemoteHistoryStore(), commands = HistoryUICommands()
    await peer.setActions([.inspectMaintenance, .clearMaintenance])
    await selectHistory(store, root: root, peer: peer, commands: commands)
    let model = try #require(store.current)
    await model.act(.clearMaintenance, operationID: f.operationID)
    #expect(commands.values.isEmpty)
    await model.act(.inspectMaintenance, operationID: f.operationID)
    let inspected = try #require(model.operationViews[f.operationID]), claim = try #require(inspected.maintenanceClaim)
    await selectHistory(store, root: root, peer: peer, commands: commands)
    #expect(model.operationViews[f.operationID]?.maintenanceClaim == claim)
    await model.act(.clearMaintenance, operationID: f.operationID)
    #expect(commands.values == [.history(target: model.target,
        action: .clearMaintenance(operationID: f.operationID, reviewID: claim.id, digest: claim.digest))])
    await store.shutdown(); await root.shutdown()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteHistoryPiWorkerAnswersFenceSessionAndExactQuestionAndFreshContextActionsKeepExactIDs() async throws {
    let f = try HistoryUIFixture(provider: .pi); defer { f.remove() }
    let root = try await connectedHistoryRoot(f), peer = HistoryUIPeer(try f.state()), store = RemoteHistoryStore(), commands = HistoryUICommands()
    let session = UUID(), request = ApprovalRequest(id: .string("same-question"), method: "pi/extension", params: .object([
        "method": .string("confirm"), "title": .string("Keep exact branch 工作?"), "message": .string("History worker input")]))
    await peer.setActions([.respondPi, .cancelPi, .keepOriginal], session: session, requests: [.init(request: request, sessionScoped: true)])
    let intent = UUID(), consumer = UUID()
    await peer.setControls(.init(claudeSelectionID: nil, claudeConsumerRunID: nil, piIntentID: intent, piConsumerRunID: consumer,
        canInspectClaudeResume: false, canInspectPiFresh: true))
    await selectHistory(store, root: root, peer: peer, commands: commands)
    let model = try #require(store.current)
    await model.respondPi(operationID: f.operationID, sessionID: UUID(), request: request, response: .decision(true))
    #expect(commands.values.isEmpty)
    await model.respondPi(operationID: f.operationID, sessionID: session, request: request, response: .decision(true))
    #expect(commands.values.last == .history(target: model.target, action: .respondPi(operationID: f.operationID,
        sessionID: session, request: request, response: .decision(true))))
    let newer = UUID()
    await peer.setActions([.respondPi, .cancelPi, .keepOriginal], session: newer, requests: [.init(request: request, sessionScoped: true)])
    await model.loadOperation(f.operationID)
    let count = commands.values.count
    await model.respondPi(operationID: f.operationID, sessionID: session, request: request, response: .decision(false))
    #expect(commands.values.count == count)
    await model.cancelPi(f.operationID)
    #expect(commands.values.last == .history(target: model.target, action: .cancelPi(operationID: f.operationID)))
    await model.act(.keepOriginal, operationID: f.operationID)
    #expect(commands.values.last == .history(target: model.target, action: .keepPiOriginal(operationID: f.operationID)))
    await model.inspectPiFresh(); await model.resolvePiFresh()
    #expect(commands.values.last == .history(target: model.target, action: .acknowledgePiFreshUnwritten(intentID: intent, consumerRunID: consumer)))
    await peer.setFresh(.persisted); await model.inspectPiFresh(); await model.resolvePiFresh()
    #expect(commands.values.last == .history(target: model.target, action: .confirmPiFreshPersisted(intentID: intent, consumerRunID: consumer)))
    await store.shutdown(); await root.shutdown()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteHistoryRootLostRecallReceiptMergesOnceIntoLatestPrivateDraftAndKeepsNewImport() async throws {
    let f = try HistoryUIFixture(); defer { f.remove() }
    let first = try await connectedHistoryRoot(f)
    var reopened: RemoteWorkspaceStore?, checking: Task<Void, Never>?
    do {
        first.setDraft("Old local draft", threadID: f.thread.id)
        try f.dropNextCommand()
        let target = try #require(first.pullRequestTarget)
        #expect(!(await first.perform(.history(target: target, action: .recallPrompt(operationID: f.operationID)))))
        let pending = try #require(first.pending)
        #expect(first.draft == "Old local draft")
        await first.shutdown()
        let next = try await connectedHistoryRoot(f); reopened = next
        #expect(next.pending == pending)
        await next.updateAttachments()
        try f.holdRecall()
        checking = Task { await next.checkPendingResult() }
        try await historyEventually { f.recallEntered }
        next.setDraft("New local edit while recall payload waits", threadID: f.thread.id)
        await next.attachments.importData(Data("Newer local attachment sentinel".utf8), name: "newer.txt")
        let attachment = try #require(next.attachments.current?.entries.first?.id)
        f.releaseRecall(); await checking?.value
        let expected = "New local edit while recall payload waits\n\n" + f.originalPrompt
        #expect(next.pending == nil && next.draft == expected)
        #expect(next.attachments.current?.entries.map(\.id) == [attachment])
        await next.checkPendingResult()
        #expect(next.draft == expected)
        #expect(try f.commands().count == 1)
        // Intentional edits after a completed merge must stay edited; replaying
        // a locally retained receipt must never append the old prompt again.
        next.setDraft("Intentionally replaced recalled text", threadID: f.thread.id)
        await next.shutdown()
        let final = try await connectedHistoryRoot(f); reopened = final
        await final.updateAttachments()
        #expect(final.pending == nil && final.draft == "Intentionally replaced recalled text")
        #expect(final.attachments.current?.entries.map(\.id) == [attachment])
        #expect(try f.commands().count == 1)
        await final.shutdown()
    } catch { f.releaseRecall(); await checking?.value; await first.shutdown(); await reopened?.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteHistoryOffscreenKeepRestoreAndProviderRecoveryFitBothAppearancesWithoutRPCOrCommands() async throws {
    _ = NSApplication.shared
    let f = try HistoryUIFixture(provider: .opencode); defer { f.remove() }
    let root = try await connectedHistoryRoot(f), peer = HistoryUIPeer(try f.state()), store = RemoteHistoryStore(), commands = HistoryUICommands()
    await peer.setActions([.inspectProvider, .inspectFiles, .acknowledgeFiles, .inspectMaintenance, .clearMaintenance])
    await selectHistory(store, root: root, peer: peer, commands: commands)
    let model = try #require(store.current)
    await model.prepare(runID: f.runID, kind: .rewindBeforeRun)
    await model.prepare(runID: f.runID, kind: .rewindBeforeRun, files: .restore)
    let operation = try #require(model.operationViews[f.operationID]), before = await peer.counts()
    for scheme in [ColorScheme.light, .dark] {
        for bounds in [CGSize(width: 480, height: 560), CGSize(width: 640, height: 680)] {
            let views: [AnyView] = [AnyView(RemoteHistoryReviewContent(model: model, runID: f.runID, kind: .rewindBeforeRun,
                reviewFiles: { Issue.record("Layout cannot review files") }, accept: { _ in Issue.record("Layout cannot accept history") }, close: { })),
                AnyView(ScrollView { RemoteHistoryOperationContent(model: model, value: operation) })]
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
    let after = await peer.counts()
    #expect(after == before && commands.values.isEmpty)
    await store.shutdown(); await root.shutdown()
}

@Test @MainActor
func remoteHistoryContiguousPagesRejectRepeatedRetainedIdentitiesAndPreserveExactUnicodePaths() throws {
    let binding = RemoteHistoryBinding(environmentID: UUID(), hostID: UUID(), leaseID: UUID(), threadID: UUID(), objectID: UUID(), digest: String(repeating: "a", count: 64))
    let row = RemoteMessageSummary(id: "retained-message", role: .assistant, createdAt: Date(), text: .init(preview: "Retained", complete: true), attachmentCount: 0)
    let duplicate = RemoteHistoryPage(binding: binding, offset: 1, items: [row], totalCount: 2, nextCursor: nil, complete: true)
    #expect(throws: RemoteHistoryFailure.self) { try RemoteHistoryPageValidation.messages(duplicate, binding: binding, offset: 1, total: 2, retained: [row]) }
    let composed = "directory/Caf\u{00e9}", decomposed = "directory/Cafe\u{0301}"
    let exact = RemoteHistoryPage(binding: binding, offset: 1, items: [composed], totalCount: 2, nextCursor: nil, complete: true)
    #expect(throws: RemoteHistoryFailure.self) { try RemoteHistoryPageValidation.paths(exact, binding: binding, offset: 1, total: 2, retained: [composed]) }
    try RemoteHistoryPageValidation.paths(exact, binding: binding, offset: 1, total: 2, retained: [decomposed])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteHistoryOwnedSynchronizationSurvivesCallerCancellationAndDisconnectDrainsWithoutRetiringTransport() async throws {
    let f = try HistoryUIFixture(); defer { f.remove() }
    let root = try await connectedHistoryRoot(f)
    var selecting: Task<Void, Never>?, following: Task<Void, Never>?
    do {
        try f.holdControls()
        selecting = Task { await root.updateHistory() }
        try await historyEventually { f.controlsEntered }
        selecting?.cancel()
        following = Task { await root.updateHistory() }
        f.releaseControls(); await selecting?.value; await following?.value
        #expect(root.isConnected && root.history.current?.controls != nil && root.history.current?.operationViews[f.operationID] != nil)
        root.history.disconnect(); try f.holdControls()
        selecting = Task { await root.updateHistory() }
        try await historyEventually { f.controlsEntered }
        root.history.disconnect(); f.releaseControls(); await selecting?.value
        await root.history.shutdown()
        #expect(root.isConnected)
        await root.shutdown()
    } catch { f.releaseControls(); await selecting?.value; await following?.value; await root.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteHistoryFastAppliedForkOpensFromAlreadyLoadedStateAndCleanupAloneNeverClaimsAccepted() async throws {
    let f = try HistoryUIFixture(); defer { f.remove() }
    let root = try await connectedHistoryRoot(f), peer = HistoryUIPeer(try f.state()), store = RemoteHistoryStore(), commands = HistoryUICommands()
    await selectHistory(store, root: root, peer: peer, commands: commands)
    let model = try #require(store.current)
    await model.prepare(runID: f.runID, kind: .forkAfterRun)
    let fork = try #require(model.keepReview)
    model.title = String(repeating: "界", count: 1_366)
    #expect(!model.canAccept(fork))
    model.title = String(repeating: "界", count: 1_000)
    #expect(model.canAccept(fork))
    commands.after = { command in
        if case .history(_, .begin) = command {
            if let completed = await peer.completedFork() { try? f.publishFork(completed); await root.projection.refreshControl() }
        }
    }
    let accepted = await model.accept(fork)
    #expect(accepted && commands.opened == [fork.value.targetThreadID!])
    commands.after = nil
    await selectHistory(store, root: root, peer: peer, commands: commands)
    await model.prepare(runID: f.runID, kind: .rewindBeforeRun)
    let refused = try #require(model.keepReview)
    commands.accepted = false
    commands.after = { _ in model.disconnect() }
    let result = await model.accept(refused)
    #expect(!result && model.review(id: refused.id) == nil)
    await store.shutdown(); await root.shutdown()
}
