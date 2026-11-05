//! Synthetic authenticated HTTP/SSE server; no provider credentials or model calls.
#![cfg(unix)]
use coincide_core::agent::{Event, ImageAttachment, Launch, Provider, Session};
use serde_json::json;
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    time::{Duration, Instant},
};

const SERVER: &str = r#"
import base64,json,os,queue,socket,sys,threading,time
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from socketserver import TCPServer
from urllib.parse import urlparse,unquote
assert sys.argv[1:]==['serve','--hostname=127.0.0.1','--port=0']
assert 'OPENCODE_SERVER_PASSWORD' not in os.environ
password=os.environ['OPENCODE_PASSWORD'];assert len(password)>=40
auth='Basic '+base64.b64encode(('opencode:'+password).encode()).decode()
def mark(stage):
 with open('fixture-stage','w') as f: f.write(stage)
mark('imports-ready')
def forbidden_dns(*args):
 raise AssertionError('The numeric loopback fixture must not perform reverse DNS')
socket.getfqdn=forbidden_dns
class LoopbackServer(ThreadingHTTPServer):
 def server_bind(self):
  # HTTPServer.server_bind otherwise calls getfqdn, which can block on hosted
  # macOS DNS even though the socket itself only needs a numeric loopback host.
  TCPServer.server_bind(self)
  self.server_name='127.0.0.1'
  self.server_port=self.server_address[1]
frames=queue.Queue();connected=False;prompt=None
sid='native/id' if RESUME else 'new-session'
def emit(kind,data): frames.put({'type':kind,'data':dict({'sessionID':sid},**data)})
def end():
 emit('session.text.ended',{'assistantMessageID':'assistant','ordinal':0,'text':'Hello world'})
 emit('session.execution.succeeded',{})
class Handler(BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*args): pass
 def body(self):
  size=int(self.headers.get('Content-Length','0'))
  return json.loads(self.rfile.read(size)) if size else None
 def send(self,data=None,status=200):
  body=json.dumps(data).encode() if data is not None else b''
  self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);self.wfile.flush()
 def check(self):
  assert self.headers['Authorization']==auth
  assert '?' not in self.path
  path=unquote(urlparse(self.path).path)
  mark(self.command+' '+path)
  return path
 def do_GET(self):
  global connected
  path=self.check()
  if path=='/api/info': return self.send({'version':'2.fixture','pid':os.getpid()})
  if path=='/api/event':
   self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
   connected=True
   self.wfile.write(b'data: {"type":"server.connected"}\r\n\r\n');self.wfile.flush()
   while True:
    try: item=frames.get(timeout=1)
    except queue.Empty:
     self.wfile.write(b': heartbeat\n\n');self.wfile.flush();continue
    if item is None: self.close_connection=True;return
    self.wfile.write(('data: '+json.dumps(item)+'\n\n').encode());self.wfile.flush()
  if path=='/api/session/active': return self.send({'data':{sid:{}} if MODE=='active' else {}})
  if path=='/api/session/'+sid:
   if MODE=='missing': return self.send({'_tag':'SessionNotFoundError'},404)
   return self.send({'data':{'id':sid,'location':{'directory':os.getcwd()},'agent':'build'}})
  if path in ['/api/session/'+sid+'/permission','/api/session/'+sid+'/form']:return self.send({'data':[]})
  self.send({},404)
 def do_PATCH(self):
  path=self.check();body=self.body();assert path=='/api/session/'+sid
  self.check_permissions(body['permissions']);self.send({})
 def check_permissions(self,rules):
  assert rules==[{'action':action,'resource':'*','effect':'ask'} for action in ['shell','edit','external_directory']]
 def do_DELETE(self):
  path=self.check();self.body()
  if '/inbox/' in path:
   with open('withdrawn','w') as f:f.write(path)
  self.send({})
 def do_POST(self):
  global prompt
  path=self.check();body=self.body()
  if path=='/api/session':
   assert not RESUME and MODE not in ['missing','active'];assert connected
   assert os.path.realpath(body['location']['directory'])==os.getcwd()
   assert body['agent']=='build';self.check_permissions(body['permissions'])
   assert body.get('model')=={'providerID':'vendor','id':'model/variant'}
   return self.send({'data':{'id':sid}})
  if path=='/api/session/'+sid+'/model':
   assert body=={'model':{'providerID':'vendor','id':'model/variant'}};return self.send({})
  if path=='/api/session/'+sid+'/prompt':
   assert connected
   assert body['id'].startswith('msg_coincide_');prompt=body['id']
   assert body['text'].startswith('fixture prompt')
   if IMAGE:
    assert len(body['files'])==1
    file=body['files'][0];url=urlparse(file['uri']);assert url.scheme=='file'
    assert open(unquote(url.path),'rb').read()==b'\x89PNG\r\n\x1a\n'
    assert file['name']=='image space.png'
   else: assert 'files' not in body
   with open('prompt-ready','w') as f:f.write(prompt)
   if MODE=='stop-http': time.sleep(30);return
   self.send({})
   emit('session.execution.succeeded',{}) # stale execution before this prompt reached the agent
   emit('session.inbox.delivered',{'inboxID':prompt})
   emit('session.execution.started',{})
   if MODE=='stop':return
   if MODE=='failed':emit('session.execution.failed',{'error':{'message':'fixture provider failure'}});return
   emit('session.text.delta',{'assistantMessageID':'assistant','ordinal':0,'delta':'Hello '})
   if MODE=='disconnect':frames.put(None);return
   emit('session.reasoning.delta',{'assistantMessageID':'assistant','ordinal':0,'delta':'Thinking'})
   emit('session.tool.input.started',{'id':'tool','name':'shell'})
   emit('session.tool.called',{'id':'tool','input':{'command':'echo fixture'}})
   emit('permission.asked',{'id':'permission','action':'shell','resources':['echo fixture'],'save':['*'],'source':{'id':'tool'}})
   return
  if path=='/api/session/'+sid+'/permission/permission/reply':
   assert body=={'decision':'once'}
   self.send({})
   emit('session.tool.success',{'id':'tool','content':[{'type':'text','text':'fixture'}]})
   emit('form.created',{'form':{'id':'form','sessionID':sid,'fields':[{'key':'choice','type':'string','options':[{'label':'Friendly','value':'actual'}]},{'key':'count','type':'integer'},{'key':'flag','type':'boolean'}]}})
   return
  if path=='/api/session/'+sid+'/form/form/reply':
   assert body=={'answer':{'choice':'actual','count':2,'flag':True}}
   self.send({});end();return
  if path=='/api/session/'+sid+'/interrupt':
   with open('interrupted','w') as f:f.write('yes')
   return self.send({'interrupted':True})
  self.send({},404)
mark('binding-loopback')
server=LoopbackServer(('127.0.0.1',0),Handler)
mark('listening-loopback')
open('pid','w').write(str(os.getpid()))
print('opencode server listening on http://127.0.0.1:'+str(server.server_port),flush=True)
server.serve_forever()
"#;

fn fixture(mode: &str, resume: bool, image: bool) -> (tempfile::TempDir, Session) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("fixture");
    let source = format!(
        "#!/usr/bin/env python3\nMODE={mode:?}\nRESUME={}\nIMAGE={}\n{SERVER}",
        if resume { "True" } else { "False" },
        if image { "True" } else { "False" }
    );
    fs::write(&path, source).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    let images = if image {
        let file = dir.path().join("image space.png");
        let bytes = b"\x89PNG\r\n\x1a\n".to_vec();
        fs::write(&file, &bytes).unwrap();
        vec![ImageAttachment::new(file, "image/png".into(), bytes).unwrap()]
    } else {
        vec![]
    };
    let session = Session::start_with_images(
        Provider::OpenCode,
        Launch {
            executable: path,
            cwd: dir.path().into(),
            session: resume.then(|| "native/id".into()),
            prompt: "fixture prompt".into(),
            model: Some("vendor/model/variant".into()),
        },
        images,
    );
    (dir, session)
}
fn receive(session: &Session, directory: &std::path::Path) -> Event {
    session
        .events
        .recv_timeout(Duration::from_secs(8))
        .unwrap_or_else(|error| {
            panic!(
                "OpenCode fixture timed out ({error}); last stage: {}",
                fixture_stage(directory)
            );
        })
}
fn fixture_stage(directory: &std::path::Path) -> String {
    fs::read_to_string(directory.join("fixture-stage"))
        .unwrap_or_else(|_| "before imports completed".into())
}
fn reap(dir: &std::path::Path) {
    let pid = fs::read_to_string(dir.join("pid"))
        .unwrap()
        .parse::<i32>()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while unsafe { libc::kill(pid, 0) } == 0 {
        assert!(Instant::now() < deadline, "OpenCode server was not reaped");
        std::thread::sleep(Duration::from_millis(10));
    }
}
#[test]
fn opencode_new_and_resumed_turns_stream_approve_ask_and_preserve_images() {
    for resume in [false, true] {
        let (dir, session) = fixture("success", resume, true);
        let mut frames = Vec::new();
        let mut native = None;
        loop {
            match receive(&session, dir.path()) {
                Event::Session(id) => native = Some(id),
                Event::Frame(frame) => {
                    match frame["method"].as_str(){
                    Some("item/commandExecution/requestApproval")=>session.reply(frame["id"].clone(),json!({"decision":"accept"})).unwrap(),
                    Some("item/tool/requestUserInput")=>session.reply(frame["id"].clone(),json!({"answers":{"choice":{"answers":["Friendly"]},"count":{"answers":["2"]},"flag":{"answers":["Yes"]}}})).unwrap(),
                    _=>{},
                }
                    frames.push(frame);
                }
                Event::Finished => break,
                Event::Failed(error) => panic!("{error}"),
            }
        }
        assert_eq!(
            native.as_deref(),
            Some(if resume { "native/id" } else { "new-session" })
        );
        assert!(
            frames
                .iter()
                .any(|frame| frame["method"] == "item/completed"
                    && frame["params"]["item"]["text"] == "Hello world")
        );
        let tool = frames
            .iter()
            .find(|frame| {
                frame["method"] == "item/completed" && frame["params"]["item"]["id"] == "tool"
            })
            .unwrap();
        assert_eq!(tool["params"]["item"]["input"]["command"], "echo fixture");
        assert!(!dir.path().join("withdrawn").exists());
        reap(dir.path());
    }
}
#[test]
fn opencode_lost_stream_or_provider_failure_never_reports_finished() {
    for mode in ["disconnect", "failed"] {
        let (dir, session) = fixture(mode, false, false);
        loop {
            match receive(&session, dir.path()) {
                Event::Finished => panic!("Incomplete turn reported success"),
                Event::Failed(error) => {
                    assert!(
                        error.contains(if mode == "failed" {
                            "fixture provider failure"
                        } else {
                            "disconnected"
                        }),
                        "{error}"
                    );
                    break;
                }
                _ => {}
            }
        }
        assert!(dir.path().join("withdrawn").exists());
        assert!(dir.path().join("interrupted").exists());
        reap(dir.path());
    }
}
#[test]
fn opencode_stop_withdraws_prompt_interrupts_and_reaps_owned_server() {
    for mode in ["stop", "stop-http"] {
        let (dir, session) = fixture(mode, false, false);
        let deadline = Instant::now() + Duration::from_secs(8);
        while !dir.path().join("prompt-ready").exists() {
            assert!(
                Instant::now() < deadline,
                "OpenCode prompt was not admitted; last stage: {}",
                fixture_stage(dir.path())
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        let stopped = Instant::now();
        session.stop();
        loop {
            match receive(&session, dir.path()) {
                Event::Finished => break,
                Event::Failed(error) => panic!("{error}"),
                _ => {}
            }
        }
        assert!(
            stopped.elapsed() < Duration::from_secs(3),
            "Stop waited for a blocked HTTP request"
        );
        assert!(dir.path().join("withdrawn").exists());
        assert!(dir.path().join("interrupted").exists());
        reap(dir.path());
    }
}
#[test]
fn opencode_missing_or_active_native_sessions_never_fork_or_run() {
    for mode in ["missing", "active"] {
        let (dir, session) = fixture(mode, true, false);
        loop {
            match receive(&session, dir.path()) {
                Event::Failed(_) => break,
                Event::Finished => panic!("Refused resume reported success"),
                Event::Session(_) => panic!("Refused resume replaced session"),
                _ => {}
            }
        }
        assert!(!dir.path().join("prompt-ready").exists());
        reap(dir.path());
    }
}
