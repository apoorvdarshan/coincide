import Darwin
import Foundation
import Testing
@testable import CoincideCore

struct AntigravityWireFixture {
    let root: URL
    let cwd: URL
    let stateRoot: URL
    let executable: URL
    let harness: URL
    let instanceID = UUID()
    let authGeneration = UUID()
    init(mode: String = "ordinary") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-antigravity-\(UUID())", isDirectory: true)
        cwd = root.appendingPathComponent("workspace", isDirectory: true)
        stateRoot = root.appendingPathComponent("state", isDirectory: true)
        executable = root.appendingPathComponent("agy_acp_server.par")
        harness = root.appendingPathComponent("localharness_external")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let python = ProcessChannel.findExecutable("python3") else { throw CoincideError("Python is needed for offline Antigravity fixtures.") }
        try Data(("#!" + python.path + "\n" + Self.server).utf8).write(to: executable)
        try Data(("#!" + python.path + "\n" + Self.harness).utf8).write(to: harness)
        for url in [executable, harness] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        try Data(mode.utf8).write(to: cwd.appendingPathComponent("mode"))
    }
    func configuration(method: AntigravityAuthMethod = .oauthPersonal, generation: UUID? = nil) -> AntigravityConfiguration {
        .init(instanceID: instanceID, executable: executable.path, authMethod: method,
              gcpProject: method == .oauthBusiness || method == .agentPlatform ? "synthetic-project" : nil,
              gcpLocation: method == .oauthBusiness || method == .agentPlatform ? "us-central1" : nil,
              authGeneration: generation ?? authGeneration)
    }
    func runtime(method: AntigravityAuthMethod = .oauthPersonal, credential: AntigravityRuntimeCredential? = nil, environment: [String: String]? = nil) throws -> AntigravityRuntime {
        try .init(executable: executable, configuration: configuration(method: method), cwd: cwd, stateRoot: stateRoot,
                  credential: credential, environment: environment, shutdownGrace: .milliseconds(80))
    }
    func proof(_ pid: Int32) -> JSONValue {
        guard let data = try? Data(contentsOf: cwd.appendingPathComponent("proof-\(pid).json")) else { return .null }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    // Synthetic stdio peer. Initialize uses the actual flat Antigravity 1.1.1
    // recording from pinned T3, not generic ACP2's nested compatibility shape.
    static let server = #"""
import json, os, pathlib, shlex, signal, subprocess, sys, time
root=pathlib.Path.cwd();mode=(root/'mode').read_text();pid=os.getpid()
proof={'pid':pid,'pgid':os.getpgrp(),'argv':sys.argv[1:],'queries':0,'prompts':0,'cancels':0,'largeFrames':0,'profile':os.environ.get('GEMINI_HOME'),'tmp':os.environ.get('TMPDIR'),'harness':os.environ.get('ANTIGRAVITY_HARNESS_PATH'),'geminiKey':'GEMINI_API_KEY' in os.environ,'googleKey':'GOOGLE_API_KEY' in os.environ,'keyMatches':any(os.environ.get(k)=='synthetic-selected-key' for k in ('GEMINI_API_KEY','GOOGLE_API_KEY')),'badAliases':any(k.lower() in ('gemini_api_key','google_api_key','google_application_credentials','google_cloud_project','google_cloud_location','google_cloud_quota_project','google_genai_use_vertexai','gcloud_project','cloudsdk_core_project','cloudsdk_auth_credential_file_override','agy_acp_ccpa_project','agy_acp_enable_oauth') and k not in ('GEMINI_API_KEY','GOOGLE_API_KEY') for k in os.environ),'forced':os.environ.get('AGY_ACP_FORCE_FILE_STORAGE')=='1','eof':False,'acks':[]}
def save():
 p=root/('proof-'+str(pid)+'.tmp');p.write_text(json.dumps(proof));p.replace(root/('proof-'+str(pid)+'.json'))
def send(x):
 data=(json.dumps(x,ensure_ascii=False,separators=(',',':'))+'\n').encode()
 if mode=='split':
  for i in range(0,len(data),3):os.write(1,data[i:i+3]);time.sleep(.001)
 else:os.write(1,data)
def reply(i,value):send({'jsonrpc':'2.0','id':i,'result':value})
def notice():send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'synthetic-session','update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'工作🌍'}}}})
url='https://accounts.google.com/o/oauth2/v2/auth?response_type=code&state=synthetic-private-state&redirect_uri=http%3A%2F%2F127.0.0.1%3A48123%2F'
held=None
save()
if mode=='descendants':
 child=subprocess.Popen([os.environ['ANTIGRAVITY_HARNESS_PATH']]);proof['harnessPID']=child.pid;save()
 deadline=time.monotonic()+2
 while not (root/('harness-'+str(child.pid)+'.json')).exists() and time.monotonic()<deadline:time.sleep(.002)
def term(signum,frame):
 proof['term']=True;save();sys.exit(0)
signal.signal(signal.SIGTERM,term)
for line in sys.stdin.buffer:
 f=json.loads(line);i=f.get('id');m=f.get('method');p=f.get('params',{})
 if m=='initialize':
  if p.get('protocolVersion')!=2 or 'clientInfo' not in p or 'clientCapabilities' not in p:sys.exit(10)
  init={'protocolVersion':2,'agentCapabilities':{'loadSession':True,'promptCapabilities':{'image':True,'audio':True,'embeddedContext':True},'mcpCapabilities':{'http':True,'sse':True},'sessionCapabilities':{'list':{},'resume':{}},'auth':{'logout':{}}},'authMethods':[{'id':x,'name':x} for x in ('oauth-personal','oauth-business','gemini-api-key','agent-platform')],'agentInfo':{'name':'antigravity-acp','title':'Google Antigravity','version':'agy_acp_server_1.1.1'}}
  if mode=='nested':init={'protocolVersion':2,'agent':{'capabilities':{},'info':{}}}
  reply(i,init)
 elif m=='authenticate':
  if mode=='stdout-auth':os.write(1,('Open the following link to authenticate the ACP server: '+url+'\n').encode())
  if mode=='invalid-auth':os.write(1,b'Open the following link to authenticate the ACP server: https://example.invalid/?state=private\n')
  if mode=='stderr-auth':subprocess.run([url if x=='%s' else x for x in shlex.split(os.environ['BROWSER'])],check=True)
  if mode=='remote':send({'jsonrpc':'2.0','id':i,'error':{'code':-32000,'message':'synthetic-private-token '+url,'data':{'secret':'synthetic-private-token'}}});continue
  reply(i,{})
 elif m=='session/new':
  proof['queries']+=1;save()
  if mode=='malformed':os.write(1,b'private arbitrary stdout must not be filtered\n');continue
  if mode=='partial':os.write(1,b'{"jsonrpc":"2.0"');sys.exit(0)
  if mode=='oversize':os.write(1,b'x'*(16*1024*1024+1)+b'\n');continue
  if mode=='stderr-noise':
   for _ in range(10):os.write(2,b'synthetic-private-token'*5000);time.sleep(.002)
   os.write(2,b'\n')
  if mode=='requests':
   for rid in (1,'1'):send({'jsonrpc':'2.0','id':rid,'method':'fs/read_text_file','params':{'sessionId':'synthetic-session','path':str(root/'safe.txt')}})
  if mode=='string-id':reply(str(i),{});continue
  reply(i,{'sessionId':'synthetic-session','configOptions':[]})
  if mode=='writer-blocked':
   prefix=sys.stdin.buffer.read(64);proof['writerPrefix']=len(prefix)>0;save()
   while not (root/'release-writer').exists():time.sleep(.002)
   payload=json.loads(prefix+sys.stdin.buffer.readline())
   if payload.get('method')!='fixture/payload':sys.exit(12)
   proof['largeFrames']+=1;save()
 elif m=='session/prompt':
  proof['prompts']+=1;save()
  notice()
  if mode=='held':held=i;continue
  if mode=='flood':
   # Fill the decoded wire queue, not the separate 64-chunk native pipe queue.
   burst=(json.dumps({'jsonrpc':'2.0','method':'session/update','params':{}},separators=(',',':'))+'\n').encode()*7
   assert len(burst)<=512
   os.write(1,burst)
  reply(i,{'stopReason':'end_turn'})
 elif m=='session/cancel':proof['cancels']+=1;save()
 elif m=='session/list':
  if held is not None:reply(held,{'stopReason':'end_turn'});held=None
  reply(i,{'sessions':[]})
 elif m is None and i is not None:proof['acks'].append({'type':type(i).__name__,'value':i,'result':f.get('result')});save()
 else:sys.exit(11)
proof['eof']=True;save()
"""#
    static let harness = #"""
import json, os, pathlib, signal, time
root=pathlib.Path.cwd();signal.signal(signal.SIGTERM,signal.SIG_IGN)
grandchild=os.fork()
if grandchild==0:
 signal.signal(signal.SIGTERM,signal.SIG_IGN)
 while True:time.sleep(.05)
p=root/('harness-'+str(os.getpid())+'.tmp');p.write_text(json.dumps({'pid':os.getpid(),'grandchild':grandchild,'pgid':os.getpgrp()}));p.replace(root/('harness-'+str(os.getpid())+'.json'))
while True:time.sleep(.05)
"""#
}

func antigravityEventually(_ body: () async -> Bool) async throws {
    let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(3))
    while clock.now < deadline { if await body() { return }; try await Task.sleep(for: .milliseconds(5)) }
    throw CoincideError("The synthetic Antigravity peer did not reach the expected milestone.")
}

@Test(arguments: AntigravityAuthMethod.allCases)
func antigravityRuntimeIsolatesSelectedCredentialAndWritesOnlyNonsecretProfile(_ method: AntigravityAuthMethod) async throws {
    let fixture = try AntigravityWireFixture()
    var runtime: AntigravityRuntime?
    do {
        var inherited = ProcessChannel.environment()
        for name in ["gEmInI_aPi_KeY", "gOoGlE_aPi_KeY", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_LOCATION", "GOOGLE_CLOUD_QUOTA_PROJECT", "GOOGLE_GENAI_USE_VERTEXAI", "GCLOUD_PROJECT", "CLOUDSDK_CORE_PROJECT", "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE", "AGY_ACP_CCPA_PROJECT", "AGY_ACP_ENABLE_OAUTH"] { inherited[name] = "synthetic-inherited-private" }
        let credential = try AntigravityRuntimeCredential(apiKey: "synthetic-selected-key")
        let owner = try fixture.runtime(method: method, credential: credential, environment: inherited); runtime = owner
        try await antigravityEventually { fixture.proof(owner.processIdentifier).object != nil }
        let proof = fixture.proof(owner.processIdentifier)
        #expect(proof["badAliases"] == .bool(false) && proof["forced"] == .bool(true))
        #expect(proof["geminiKey"] == .bool(method == .geminiAPIKey))
        #expect(proof["googleKey"] == .bool(method == .agentPlatform))
        #expect(proof["keyMatches"] == .bool(method == .geminiAPIKey || method == .agentPlatform))
        #expect(proof["argv"] == .array([]) && proof["harness"] == .string(owner.executablePair.harness.path))
        let settings = try Data(contentsOf: owner.profileDirectory.appendingPathComponent("antigravity-acp/settings.json"))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: settings)
        #expect(decoded["auth"]["type"] == .string(method.rawValue))
        #expect((decoded["gcp"].object != nil) == (method == .oauthBusiness || method == .agentPlatform))
        #expect(!String(decoding: settings, as: UTF8.self).contains("synthetic-selected-key"))
        #expect(!String(describing: credential).contains("synthetic-selected-key"))
        let mode = try FileManager.default.attributesOfItem(atPath: owner.temporaryDirectory.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700)
        await owner.close()
        #expect(!FileManager.default.fileExists(atPath: owner.temporaryDirectory.path))
        #expect(FileManager.default.fileExists(atPath: owner.profileDirectory.path))
    } catch { await runtime?.close(); fixture.cleanup(); throw error }
    fixture.cleanup()
}

@Test func antigravityRuntimeAgentPlatformProjectModeDoesNotInheritAnAPIKey() async throws {
    let fixture = try AntigravityWireFixture()
    var runtime: AntigravityRuntime?
    do {
        var environment = ProcessChannel.environment()
        environment["GOOGLE_API_KEY"] = "synthetic-inherited-private"
        environment["GEMINI_API_KEY"] = "synthetic-inherited-private"
        let owner = try fixture.runtime(method: .agentPlatform, environment: environment); runtime = owner
        try await antigravityEventually { fixture.proof(owner.processIdentifier).object != nil }
        let proof = fixture.proof(owner.processIdentifier)
        #expect(proof["geminiKey"] == .bool(false) && proof["googleKey"] == .bool(false))
        let data = try Data(contentsOf: owner.profileDirectory.appendingPathComponent("antigravity-acp/settings.json"))
        let settings = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(settings["gcp"]["project"] == .string("synthetic-project") && settings["gcp"]["location"] == .string("us-central1"))
        await owner.close()
    } catch { await runtime?.close(); fixture.cleanup(); throw error }
    fixture.cleanup()
}

@Test func antigravityRuntimeRejectsMissingOrMismatchedHarnessBeforeLaunchAndSeparatesGenerations() async throws {
    let fixture = try AntigravityWireFixture()
    do {
        try FileManager.default.removeItem(at: fixture.harness)
        #expect(throws: AntigravityWireError.self) { try AntigravityRuntime.resolvePair(configuration: fixture.configuration()) }
        #expect((try FileManager.default.contentsOfDirectory(atPath: fixture.cwd.path)) == ["mode"])
    } catch { fixture.cleanup(); throw error }
    fixture.cleanup()
    let other = try AntigravityWireFixture()
    var first: AntigravityRuntime?, second: AntigravityRuntime?
    do {
        let a = try other.runtime(); first = a
        let conversation = a.profileDirectory.appendingPathComponent("antigravity-acp/conversations/synthetic.meta")
        try Data("shared-native-conversation".utf8).write(to: conversation)
        try Data("synthetic-generation-token".utf8).write(to: a.profileDirectory.appendingPathComponent("antigravity-acp/acp_token.json"))
        let config = other.configuration(generation: UUID())
        let b = try AntigravityRuntime(executable: other.executable, configuration: config, cwd: other.cwd, stateRoot: other.stateRoot, shutdownGrace: .milliseconds(80)); second = b
        #expect(a.profileDirectory != b.profileDirectory && a.temporaryDirectory != b.temporaryDirectory)
        #expect(a.sessionStateDirectory == b.sessionStateDirectory)
        let shared = b.profileDirectory.appendingPathComponent("antigravity-acp/conversations/synthetic.meta")
        let content = try String(contentsOf: shared, encoding: .utf8)
        #expect(content == "shared-native-conversation")
        #expect(!FileManager.default.fileExists(atPath: b.profileDirectory.appendingPathComponent("antigravity-acp/acp_token.json").path))
        await a.close()
        try FileManager.default.removeItem(at: a.profileDirectory)
        #expect(FileManager.default.fileExists(atPath: shared.path))
        #expect(FileManager.default.fileExists(atPath: b.temporaryDirectory.path))
        await b.close()
    } catch { await first?.close(); await second?.close(); other.cleanup(); throw error }
    other.cleanup()
}

@Test func antigravityRuntimeRejectsRedirectedHistoryLinksWithoutTouchingExternalFiles() async throws {
    let fixture = try AntigravityWireFixture()
    var runtime: AntigravityRuntime?
    do {
        let owner = try fixture.runtime(); runtime = owner; await owner.close()
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let marker = outside.appendingPathComponent("preserve.txt")
        try Data("preserve".utf8).write(to: marker)
        let link = owner.profileDirectory.appendingPathComponent("antigravity-acp/conversations")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: AntigravityWireError.self) { try fixture.runtime() }
        let preserved = try String(contentsOf: marker, encoding: .utf8)
        #expect(preserved == "preserve")
        #expect(FileManager.default.fileExists(atPath: owner.sessionStateDirectory.appendingPathComponent("antigravity-acp/conversations").path))
    } catch { await runtime?.close(); fixture.cleanup(); throw error }
    fixture.cleanup()
}

@Test func antigravityRuntimeCloseDrainsOwnedHarnessAndGrandchildPreservingIndependentOwner() async throws {
    let fixture = try AntigravityWireFixture(mode: "descendants"), sibling = try AntigravityWireFixture()
    var owner: AntigravityRuntime?, other: AntigravityRuntime?
    do {
        let a = try fixture.runtime(), b = try sibling.runtime(); owner = a; other = b
        try await antigravityEventually { fixture.proof(a.processIdentifier)["harnessPID"] != .null && sibling.proof(b.processIdentifier).object != nil }
        guard case .number(let raw) = fixture.proof(a.processIdentifier)["harnessPID"], let harnessPID = Int32(exactly: raw) else { throw CoincideError("Synthetic harness proof was missing.") }
        let path = fixture.cwd.appendingPathComponent("harness-\(harnessPID).json")
        try await antigravityEventually { FileManager.default.fileExists(atPath: path.path) }
        let data = try Data(contentsOf: path), proof = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .number(let rawGrandchild) = proof["grandchild"], let grandchild = Int32(exactly: rawGrandchild) else { throw CoincideError("Synthetic descendant proof was missing.") }
        #expect(proof["pgid"] == .number(Double(a.processIdentifier)))
        async let first: Void = a.close(); async let second: Void = a.close(); _ = await (first, second)
        try await antigravityEventually { [a.processIdentifier, harnessPID, grandchild].allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        #expect(!FileManager.default.fileExists(atPath: a.temporaryDirectory.path))
        #expect(kill(b.processIdentifier, 0) == 0 && FileManager.default.fileExists(atPath: b.temporaryDirectory.path))
        await b.close()
    } catch { await owner?.close(); await other?.close(); fixture.cleanup(); sibling.cleanup(); throw error }
    fixture.cleanup(); sibling.cleanup()
}
