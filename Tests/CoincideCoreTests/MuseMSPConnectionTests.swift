import Darwin
import Foundation
import Testing
@testable import CoincideCore

private actor MuseWireRecord {
    var notifications: [(String, JSONValue)] = []
    var requests: [(Int, String)] = []
    var closed: MuseMSPError?
    var didClose = false
    var callbackSucceeded = false
    var order: [String] = []
    var callbackFailures: [MuseMSPError] = []
    var started = false
    func markStarted() { started = true }
    func receive(_ event: MuseMSPEvent, connection: MuseMSPConnection) async throws {
        switch event {
        case .notification(let method, let params): notifications.append((method, params)); order.append(method)
        case .serverRequest(let id, let method, _): requests.append((id, method)); try await connection.acknowledgePresentation(id: id)
        case .callback(let action): await action()
        case .closed(let error): closed = error; didClose = true
        }
    }
    func callback(_ result: Result<JSONValue, MuseMSPError>, label: String = "callback") {
        order.append(label)
        switch result {
        case .success: callbackSucceeded = true
        case .failure(let error): callbackFailures.append(error)
        }
    }
}

private struct MuseWirePeer {
    let root: URL
    let connection: MuseMSPConnection
    init(mode: String = "ordinary", timeout: Duration = .seconds(2), buffer: Int = 128) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-muse-wire-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let script = root.appendingPathComponent("peer.py")
        try Data(Self.python.utf8).write(to: script)
        guard let python = ProcessChannel.findExecutable("python3") else { throw CoincideError("Python is needed for synthetic MSP tests.") }
        connection = try .init(executable: python, arguments: [script.path, mode], cwd: root,
                               environment: ["MeTa_ApI_KeY": "synthetic-private", "MUSE_NO_AUTO_UPDATE": "0"],
                               requestTimeout: timeout, shutdownTimeout: .milliseconds(150), eventBufferLimit: buffer)
    }
    func proof() -> JSONValue {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("proof.json")) else { return .null }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }
    func cleanup() async { await connection.close(); try? FileManager.default.removeItem(at: root) }
    // JSON-RPC envelopes from SDK1.4.6; sequence based on T3 recorded simple,
    // turn_interrupt and muse_permission frames. This executable is synthetic.
    static let python = #"""
import json, os, pathlib, sys, time
mode=sys.argv[1]
root=pathlib.Path.cwd()
S='019a0000-0000-7000-8000-000000000001'
T='019a0000-0000-7000-8000-000000000002'
proof={'pid':os.getpid(),'keyPresent':any(k.upper()=='META_API_KEY' for k in os.environ),'noUpdate':os.environ.get('MUSE_NO_AUTO_UPDATE')=='1','queries':0,'commands':0,'initialized':False,'presentationAck':False,'eof':False}
def save():
 p=root/'proof.tmp';p.write_text(json.dumps(proof));p.replace(root/'proof.json')
def send(x):
 data=(json.dumps(x,ensure_ascii=False,separators=(',',':'))+'\n').encode()
 if mode=='same-cursor':
  for i in range(0,len(data),3):os.write(1,data[i:i+3]);time.sleep(.001)
 else:os.write(1,data)
def reply(i,result):send({'jsonrpc':'2.0','id':i,'result':result})
def notice(method,params):send({'jsonrpc':'2.0','method':method,'params':params})
catalog={'providerId':'meta','profileId':None,'source':'fakeCatalog','models':[]}
session={'sessionId':S,'workspaceRoot':str(root),'path':str(root/'session.jsonl'),'modelId':None,'providerId':'meta','activeTurnId':None,'createdAt':'2026-10-22T00:00:00Z','updatedAt':'2026-10-22T00:00:00Z','forkedFrom':None,'status':'idle','turnCount':0}
source={'stream':{'kind':'session','id':S},'first':{'id':T,'sequence':1},'last':{'id':T,'sequence':1}}
held=None;heldResult=catalog;commands={}
save()
for line in sys.stdin:
 frame=json.loads(line)
 if frame.get('jsonrpc')!='2.0':sys.exit(9)
 method=frame.get('method');i=frame.get('id');p=frame.get('params',{})
 if method=='initialize':
  if p.get('clientInfo',{}).get('name')!='coincide':sys.exit(10)
  reply(i,{'serverInfo':{'name':'muse','version':'synthetic'},'userAgent':'synthetic','museHome':str(root),'platformFamily':'unix','platformOs':'macos','schema':{'version':1,'fingerprint':'sha256:eae467ab60cb9a5d5af4de616830f065e59375c987fd59269c8cc33ed2a1137f'},'grantedCapabilities':['sessionMcp'],'experimentalApi':False,'sessionDurability':'durable'})
 elif method=='initialized':proof['initialized']=True;save()
 elif method=='model/list':
  if not proof['initialized']:sys.exit(11)
  proof['queries']+=1;save()
  if mode=='held':held=i;continue
  if mode=='partial':os.write(1,b'{"jsonrpc":"2.0"');sys.exit(0)
  if mode=='bad-version':send({'jsonrpc':'1.0','id':i,'result':catalog});continue
  if mode=='string-id':reply(str(i),catalog);continue
  if mode=='wrong-id':reply(i+99,catalog);continue
  if mode=='both':send({'jsonrpc':'2.0','id':i,'result':catalog,'error':{'code':-32001,'message':'synthetic-private'}});continue
  if mode=='bad-error':send({'jsonrpc':'2.0','id':i,'error':{'code':None,'message':'synthetic-private'}});continue
  if mode=='remote':send({'jsonrpc':'2.0','id':i,'error':{'code':-32001,'message':'synthetic-private bearer token','data':{'kind':'overloaded','privateConfig':'synthetic-private'}}});continue
  if mode=='presentation':
   params={'sessionId':S,'turnId':T,'approvalId':'approval-1','taskId':'task-1','itemId':'tool-1','toolCallId':'call-1','toolName':'shell','rawArgs':'{}','viewCursor':'opaque-approval','sourceRange':source,'subject':{'kind':'shell','command':'printf synthetic'},'currentRequirementId':{'approvalId':'approval-1','sourceIndex':0},'availableChoices':[{'choiceId':'once','label':'Allow once','decision':'approved','scope':'once'}],'protectedWrite':False,'judgeEscalated':False}
   send({'jsonrpc':'2.0','id':1,'method':'approval/request','params':params})
  reply(i,catalog)
  if mode=='same-cursor':
   notice('session/statusChanged',{'sessionId':S,'status':'idle','viewCursor':'shared-position'})
   notice('turn/completed',{'sessionId':S,'turnId':T,'terminal':'completed','viewCursor':'shared-position','sourceRange':source,'reason':'工作🌍'})
  if mode=='flood':
   for n in range(100):notice('session/statusChanged',{'sessionId':S,'status':'idle','viewCursor':'opaque-'+str(n)})
 elif method=='session/read':
  if held is not None:reply(held,heldResult);held=None
  reply(i,{'session':session,'viewCursor':'opaque-read','pendingRequests':[],'history':{'mode':'none','items':None,'snapshot':None,'noneReason':'excluded'}})
 elif method=='turn/start':
  proof['commands']+=1;save()
  c=p['commandId'];previous=commands.get(c);commands[c]=p
  if previous is not None and previous!=p:sys.exit(12)
  ack={'commandId':c,'status':'accepted','turnId':c,'startedNewTurn':True,'disposition':'started'}
  if mode=='wrong-echo':ack['commandId']=S
  if mode=='changed-replay' and previous is not None:ack.update({'disposition':'queued','startedNewTurn':False})
  if mode=='terminal-held':
   notice('turn/completed',{'sessionId':S,'turnId':c,'terminal':'completed','viewCursor':'opaque-terminal','sourceRange':source})
   held=i;heldResult=ack;continue
  reply(i,ack)
 elif method is None and i==1 and frame.get('result')=={}:proof['presentationAck']=True;save()
 else:sys.exit(13)
proof['eof']=True;save()
"""#
}

private func museEventually(_ condition: () async -> Bool) async throws {
    let clock = ContinuousClock(), limit = clock.now.advanced(by: .seconds(3))
    while clock.now < limit { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
    throw CoincideError("Synthetic Muse peer did not reach the expected milestone.")
}

@Test func museMSPNativeHandshakeScrubsInheritedKeyAndMetadataDoesNotCreateSession() async throws {
    let peer = try MuseWirePeer()
    do {
        let result = try await peer.connection.initialize()
        #expect(result.schemaFingerprint == MuseProtocol.schemaFingerprint)
        let catalog = try await peer.connection.query("model/list")
        #expect(catalog["source"] == .string("fakeCatalog"))
        #expect(peer.proof()["keyPresent"] == .bool(false) && peer.proof()["noUpdate"] == .bool(true))
        #expect(peer.proof()["initialized"] == .bool(true) && peer.proof()["queries"] == .number(1))
        await peer.connection.close()
        #expect(peer.proof()["eof"] == .bool(true))
    } catch { await peer.cleanup(); throw error }
    await peer.cleanup()
}

@Test func museMSPRecordedSameCursorIdleAndTerminalAreBothDeliveredWithSplitUnicode() async throws {
    let peer = try MuseWirePeer(mode: "same-cursor"), record = MuseWireRecord()
    let reader = Task { for await event in peer.connection.events { try await record.receive(event, connection: peer.connection) } }
    do {
        _ = try await peer.connection.initialize(); _ = try await peer.connection.query("model/list")
        try await museEventually { await record.notifications.count == 2 }
        let events = await record.notifications
        #expect(events.map { $0.0 } == ["session/statusChanged", "turn/completed"])
        #expect(events[0].1["viewCursor"] == events[1].1["viewCursor"] && events[1].1["reason"] == .string("工作🌍"))
        await peer.connection.close(); try await reader.value
    } catch { await peer.cleanup(); _ = try? await reader.value; throw error }
    await peer.cleanup()
}

@Test func museMSPServerRequestIDsBelongToTheirDirectionAndPresentationACKIsSeparate() async throws {
    let peer = try MuseWirePeer(mode: "presentation"), record = MuseWireRecord()
    let reader = Task { for await event in peer.connection.events { try await record.receive(event, connection: peer.connection) } }
    do {
        _ = try await peer.connection.initialize(); _ = try await peer.connection.query("model/list")
        try await museEventually { peer.proof()["presentationAck"] == .bool(true) }
        let requests = await record.requests
        #expect(requests.first?.0 == 1 && requests.first?.1 == "approval/request")
        await peer.connection.close(); try await reader.value
    } catch { await peer.cleanup(); _ = try? await reader.value; throw error }
    await peer.cleanup()
}

@Test(arguments: ["bad-version", "string-id", "wrong-id", "both", "bad-error", "partial"])
func museMSPMalformedWireAlwaysResolvesMatchedCallerWithSafeError(_ mode: String) async throws {
    let peer = try MuseWirePeer(mode: mode)
    do {
        _ = try await peer.connection.initialize()
        do { _ = try await peer.connection.query("model/list"); Issue.record("Malformed MSP response accepted") }
        catch let error as MuseMSPError { #expect(error.kind == .protocolViolation && !error.localizedDescription.contains("synthetic-private")) }
    } catch { await peer.cleanup(); throw error }
    await peer.cleanup()
}

@Test func museMSPRemoteFailureIsRedactedAndNeverBlindlyRetries() async throws {
    let peer = try MuseWirePeer(mode: "remote")
    do {
        _ = try await peer.connection.initialize()
        do { _ = try await peer.connection.query("model/list"); Issue.record("Remote failure accepted") }
        catch let error as MuseMSPError {
            #expect(error.kind == .remoteFailure && error.code == -32001 && error.nativeKind == "overloaded")
            #expect(!String(describing: error).contains("synthetic-private") && !error.localizedDescription.contains("token"))
        }
        #expect(peer.proof()["queries"] == .number(1))
    } catch { await peer.cleanup(); throw error }
    await peer.cleanup()
}

@Test func museMSPTimedOutOwnedRequestCanArriveLateWithoutKillingHealthyConnection() async throws {
    let peer = try MuseWirePeer(mode: "held", timeout: .milliseconds(80))
    do {
        _ = try await peer.connection.initialize()
        do { _ = try await peer.connection.query("model/list"); Issue.record("Held query completed") }
        catch let error as MuseMSPError { #expect(error.kind == .timedOut) }
        let result = try await peer.connection.query("session/read", params: .object(["sessionId": .string("019a0000-0000-7000-8000-000000000001")]))
        #expect(result["session"]["status"] == .string("idle"))
    } catch { await peer.cleanup(); throw error }
    await peer.cleanup()
}

@Test func museMSPFailureCallbackCannotOvertakeEarlierNativeTerminalWhileConsumerIsPaused() async throws {
    let peer = try MuseWirePeer(mode: "terminal-held"), record = MuseWireRecord()
    var reader: Task<Void, any Error>?
    var turn: Task<JSONValue, any Error>?
    do {
        _ = try await peer.connection.initialize()
        let command = await peer.connection.mintCommandID()
        let pending = Task {
            try await peer.connection.command("turn/start", params: .object(["sessionId": .string("019a0000-0000-7000-8000-000000000001")]), commandID: command,
                                              onResponse: { await record.callback($0) })
        }
        turn = pending
        try await museEventually { peer.proof()["commands"] == .number(1) }
        // This reply follows the terminal on the same pipe, so the decoder has
        // accepted that terminal before cancellation can enqueue its failure.
        _ = try await peer.connection.query("model/list")
        pending.cancel()
        do {
            _ = try await pending.value
            Issue.record("Held turn acknowledgement completed")
        } catch let error as MuseMSPError { #expect(error.kind == .cancelled) }
        // Deliberately do not consume events until the direct await has thrown.
        // Native terminal proof must still precede its ordered failure callback.
        let beforeConsumer = await record.order
        #expect(beforeConsumer.isEmpty)
        reader = Task { for await event in peer.connection.events { try await record.receive(event, connection: peer.connection) } }
        try await museEventually { await record.callbackFailures.count == 1 }
        let ordered = await record.order, failures = await record.callbackFailures
        #expect(ordered == ["turn/completed", "callback"])
        #expect(failures.map(\.kind) == [.cancelled])
        let result = try await peer.connection.query("session/read", params: .object(["sessionId": .string("019a0000-0000-7000-8000-000000000001")]))
        #expect(result["session"]["status"] == .string("idle"))
        await peer.connection.close(); try await reader?.value
        let finalFailures = await record.callbackFailures
        #expect(finalFailures.count == 1 && peer.proof()["commands"] == .number(1))
    } catch { turn?.cancel(); await peer.cleanup(); _ = try? await turn?.value; _ = try? await reader?.value; throw error }
    await peer.cleanup()
}

@Test func museMSPLocalRejectionsAndPreRegistrationCancellationDeliverOneCallbackWithoutWriting() async throws {
    let peer = try MuseWirePeer(), record = MuseWireRecord()
    var reader: Task<Void, any Error>?
    do {
        _ = try await peer.connection.initialize()
        do {
            _ = try await peer.connection.command("turn/start", commandID: UUID().uuidString, onResponse: { await record.callback($0, label: "command-rejected") })
            Issue.record("Non-v7 command accepted")
        } catch let error as MuseMSPError { #expect(error.kind == .invalidInput) }
        do {
            _ = try await peer.connection.query("initialized", onResponse: { await record.callback($0, label: "query-rejected") })
            Issue.record("Reserved query accepted")
        } catch let error as MuseMSPError { #expect(error.kind == .invalidInput) }
        do {
            _ = try await peer.connection.query("model/list", params: .array([]), onResponse: { await record.callback($0, label: "request-rejected") })
            Issue.record("Non-object request parameters accepted")
        } catch let error as MuseMSPError { #expect(error.kind == .invalidInput) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await peer.connection.query("model/list", onResponse: { await record.callback($0, label: "pre-cancelled") })
        }
        do { _ = try await cancelled.value; Issue.record("Pre-cancelled query accepted") }
        catch let error as MuseMSPError { #expect(error.kind == .cancelled) }
        let beforeConsumer = await record.order
        #expect(beforeConsumer.isEmpty)
        #expect(peer.proof()["queries"] == .number(0) && peer.proof()["commands"] == .number(0))
        reader = Task { for await event in peer.connection.events { try await record.receive(event, connection: peer.connection) } }
        try await museEventually { await record.callbackFailures.count == 4 }
        let ordered = await record.order, failures = await record.callbackFailures
        #expect(ordered == ["command-rejected", "query-rejected", "request-rejected", "pre-cancelled"])
        #expect(failures.map(\.kind) == [.invalidInput, .invalidInput, .invalidInput, .cancelled])
        _ = try await peer.connection.query("model/list")
        #expect(peer.proof()["queries"] == .number(1))
        await peer.connection.close(); try await reader?.value
        let finalFailures = await record.callbackFailures
        #expect(finalFailures.count == 4)
    } catch { await peer.cleanup(); _ = try? await reader?.value; throw error }
    await peer.cleanup()
}

@Test func museMSPCommandReplayRequiresSamePayloadAndValueIdenticalAcknowledgement() async throws {
    let peer = try MuseWirePeer(mode: "changed-replay")
    do {
        _ = try await peer.connection.initialize(); let command = await peer.connection.mintCommandID()
        let params: JSONValue = .object(["sessionId": .string("019a0000-0000-7000-8000-000000000001"), "input": .array([.object(["type": .string("text"), "text": .string("synthetic")])])])
        _ = try await peer.connection.command("turn/start", params: params, commandID: command)
        do { _ = try await peer.connection.command("turn/start", params: .object(["different": .bool(true)]), commandID: command); Issue.record("Changed command payload accepted") }
        catch let error as MuseMSPError { #expect(error.kind == .invalidInput) }
        do { _ = try await peer.connection.command("turn/start", params: params, commandID: command); Issue.record("Changed replay ACK accepted") }
        catch let error as MuseMSPError { #expect(error.kind == .protocolViolation) }
    } catch { await peer.cleanup(); throw error }
    await peer.cleanup()
}

@Test func museMSPCancellingExactQueryPreservesAnotherOwnedRequestAndLateReply() async throws {
    let peer = try MuseWirePeer(mode: "held")
    do {
        _ = try await peer.connection.initialize()
        let query = Task { try await peer.connection.query("model/list") }
        try await museEventually { peer.proof()["queries"] == .number(1) }
        query.cancel()
        do { _ = try await query.value; Issue.record("Cancelled query completed") }
        catch let error as MuseMSPError { #expect(error.kind == .cancelled) }
        let current = try await peer.connection.query("session/read", params: .object(["sessionId": .string("019a0000-0000-7000-8000-000000000001")]))
        #expect(current["session"]["status"] == .string("idle"))
    } catch { await peer.cleanup(); throw error }
    await peer.cleanup()
}

@Test func museMSPEventConsumerCancellationInitiatesOwnedClose() async throws {
    let peer = try MuseWirePeer(), record = MuseWireRecord()
    do {
        _ = try await peer.connection.initialize()
        let consumer = Task {
            await record.markStarted()
            for await event in peer.connection.events { try await record.receive(event, connection: peer.connection) }
        }
        try await museEventually { await record.started }
        consumer.cancel(); _ = try? await consumer.value
        try await museEventually { peer.proof()["eof"] == .bool(true) }
    } catch { await peer.cleanup(); throw error }
    await peer.cleanup()
}

@Test func museMSPWrongCommandEchoNeverReachesOrderedSuccessCallback() async throws {
    let peer = try MuseWirePeer(mode: "wrong-echo"), record = MuseWireRecord()
    let reader = Task { for await event in peer.connection.events { try await record.receive(event, connection: peer.connection) } }
    do {
        _ = try await peer.connection.initialize(); let command = await peer.connection.mintCommandID()
        do { _ = try await peer.connection.command("turn/start", params: .object(["input": .array([.object(["type": .string("text"), "text": .string("synthetic")])])]), commandID: command, onResponse: { await record.callback($0) }); Issue.record("Wrong echo accepted") }
        catch let error as MuseMSPError { #expect(error.kind == .protocolViolation) }
        await peer.connection.close(); try await reader.value
        let callbackSucceeded = await record.callbackSucceeded
        let failures = await record.callbackFailures
        #expect(!callbackSucceeded && failures.isEmpty)
    } catch { await peer.cleanup(); _ = try? await reader.value; throw error }
    await peer.cleanup()
}

@Test func museMSPSlowConsumerGetsExplicitOverflowInsteadOfDroppedDurableNotifications() async throws {
    let peer = try MuseWirePeer(mode: "flood", buffer: 8)
    do {
        _ = try await peer.connection.initialize(); _ = try await peer.connection.query("model/list")
        try await museEventually {
            guard case .number(let raw) = peer.proof()["pid"], let pid = Int32(exactly: raw) else { return false }
            return kill(pid, 0) == -1 && errno == ESRCH
        }
        var notifications = 0, overflow = false
        for await event in peer.connection.events {
            if case .notification = event { notifications += 1 }
            if case .closed(let error) = event { overflow = error?.kind == .overflow }
        }
        #expect(notifications > 0 && notifications <= 7 && overflow)
    } catch { await peer.cleanup(); throw error }
    await peer.cleanup()
}

@Test func museMSPCloseIsCoalescedDrainsExactOwnedPIDAndSettlesPendingQuery() async throws {
    let peer = try MuseWirePeer(mode: "held")
    do {
        _ = try await peer.connection.initialize()
        let query = Task { try await peer.connection.query("model/list") }
        try await museEventually { peer.proof()["queries"] == .number(1) }
        async let first: Void = peer.connection.close()
        async let second: Void = peer.connection.close()
        _ = await (first, second)
        do { _ = try await query.value; Issue.record("Closed pending query completed") } catch let error as MuseMSPError { #expect(error.kind == .closed) }
        let proof = peer.proof()
        #expect(proof["eof"] == .bool(true))
        if case .number(let raw) = proof["pid"], let pid = Int32(exactly: raw) { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
    } catch { await peer.cleanup(); throw error }
    await peer.cleanup()
}
