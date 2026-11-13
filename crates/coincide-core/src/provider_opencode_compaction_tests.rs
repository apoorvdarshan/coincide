use super::*;
use std::{fs, os::unix::fs::PermissionsExt};

fn fixture_diagnostics(directory: &std::path::Path, session: &Session) -> String {
    let mut limit: libc::rlimit = unsafe { std::mem::zeroed() };
    let nofile = if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } == 0 {
        Some(limit.rlim_cur)
    } else {
        None
    };
    let open_files = fs::read_dir("/dev/fd").ok().map(|entries| entries.count());
    format!(
        "worker={:?}, prelude={}, python={}, imports={}, open_files={open_files:?}, nofile={nofile:?}, stderr={:?}",
        session.worker_completion().status(),
        directory.join("worker-started").is_file(),
        directory.join("python-started").is_file(),
        directory.join("python-imported").is_file(),
        fs::read_to_string(directory.join("fixture-stderr")).ok(),
    )
}

#[test]
fn compact_uses_the_session_endpoint_and_waits_for_execution() {
    for mode in ["accepted", "wrong-receipt", "goal-command"] {
        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join(mode);
        fs::write(&executable, r#"#!/usr/bin/env python3
open('python-started','w').write('ready')
import sys
sys.stderr=open('fixture-stderr','w',buffering=1)
import http.server,json,os,queue,socket,socketserver
open('python-imported','w').write('ready')
events=queue.Queue()
def mark(name):
  with open(name,'w') as marker: marker.write('ready')
class Handler(http.server.BaseHTTPRequestHandler):
  def log_message(self,*args): pass
  def reply(self,data):
    body=json.dumps(data).encode(); self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
  def do_GET(self):
    if self.path=='/api/event':
      self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
      mark('event-connected')
      self.wfile.write(b'data: {"type":"server.connected"}\n\n'); self.wfile.flush()
      while True:
        item=events.get(); self.wfile.write(('data: '+json.dumps(item)+'\n\n').encode()); self.wfile.flush()
    elif self.path=='/api/info': self.reply({'version':'synthetic','pid':os.getpid()})
    elif self.path=='/api/session/active': self.reply({'data':{}})
    elif self.path in ('/api/session/native/permission','/api/session/native/form'): self.reply({'data':[]})
    elif self.path=='/api/session/native': self.reply({'data':{'id':'native','location':{'directory':os.getcwd()},'agent':'build'}})
    elif self.path.startswith('/api/command?'): self.reply({'location':{'directory':os.getcwd()},'data':[{'name':'goal'}]})
    else: self.send_error(404)
  def do_PATCH(self):
    self.rfile.read(int(self.headers.get('Content-Length',0))); self.reply({'data':{}})
  def do_POST(self):
    data=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))))
    mark('control-received')
    mode=os.path.basename(sys.argv[0])
    if mode=='goal-command':
      assert self.path=='/api/session/native/command' and data=={'name':'goal','text':'finish this'}
      self.send_response(204); self.end_headers()
    else:
      assert self.path=='/api/session/native/compact' and data['delivery']=='steer'
      received=data['id'] if mode=='accepted' else 'another-id'
      self.reply({'data':{'id':received,'sessionID':'native','type':'compaction'}})
    events.put({'type':'session.execution.started','data':{'sessionID':'native'}})
    events.put({'type':'session.execution.succeeded','data':{'sessionID':'native'}})
class LocalServer(http.server.ThreadingHTTPServer):
  daemon_threads=True
  def server_bind(self):
    # HTTPServer normally calls getfqdn(), which may block on reverse DNS on
    # macOS runners even though this fixture only binds an IPv4 loopback IP.
    socketserver.TCPServer.server_bind(self)
    self.server_name='127.0.0.1'
    self.server_port=self.server_address[1]
def no_dns(*args):
  raise AssertionError('the loopback fixture must not perform DNS lookups')
socket.getfqdn=no_dns
server=LocalServer(('127.0.0.1',0),Handler)
mark('server-ready')
print('server listening on http://127.0.0.1:%d/'%server.server_port,flush=True)
server.serve_forever()
"#).unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let session = Session::start_with_mode_policy_and_profile(
            Provider::OpenCode,
            Launch {
                executable,
                cwd: directory.path().into(),
                session: Some("native".into()),
                prompt: "old context is not the command".into(),
                model: None,
                variant: None,
                full_access: false,
            },
            Vec::new(),
            None,
            None,
            LaunchOptions {
                prelude: Some(Box::new({
                    let path = directory.path().join("worker-started");
                    move || {
                        fs::write(path, "ready").unwrap();
                    }
                })),
                compact: mode != "goal-command",
                opencode_command: Some(
                    if mode == "goal-command" {
                        "/goal finish this"
                    } else {
                        "/compact"
                    }
                    .into(),
                ),
                ..Default::default()
            },
        );
        // The provider allows up to 30 s for process startup, followed by a
        // separate event-stream connection and several HTTP requests. A single
        // 10 s event timeout incorrectly failed before those phases could end
        // on busy runners. Observe each actual fixture milestone instead.
        for marker in ["server-ready", "event-connected", "control-received"] {
            let deadline = Instant::now() + Duration::from_secs(30);
            while !directory.path().join(marker).is_file() {
                if let Ok(event) = session.events.try_recv() {
                    match event {
                        Event::Failed(error) => panic!(
                            "{mode} failed before {marker}: {error}; {}",
                            fixture_diagnostics(directory.path(), &session)
                        ),
                        Event::Finished => panic!(
                            "{mode} finished before {marker}; {}",
                            fixture_diagnostics(directory.path(), &session)
                        ),
                        _ => {}
                    }
                }
                assert!(
                    Instant::now() < deadline,
                    "{mode} did not reach {marker}; {}",
                    fixture_diagnostics(directory.path(), &session)
                );
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        loop {
            match session
                .events
                .recv_timeout(Duration::from_secs(16))
                .unwrap()
            {
                Event::Finished if mode != "wrong-receipt" => break,
                Event::Failed(error) if mode == "wrong-receipt" => {
                    assert!(error.contains("did not acknowledge"));
                    break;
                }
                Event::Finished => panic!("wrong receipt was accepted"),
                Event::Failed(error) => panic!("{error}"),
                _ => {}
            }
        }
        assert!(session.is_provider_control());
        // Finished is a provider event, not proof the owned server and its
        // stream workers have exited. Keep this fixture's directory alive
        // until the actual worker is joined before starting the next case.
        let completion = session.worker_completion();
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            match completion.status() {
                WorkerThreadStatus::Returned => break,
                WorkerThreadStatus::Running => {
                    assert!(
                        Instant::now() < deadline,
                        "{mode} worker did not finish cleanup"
                    );
                    std::thread::sleep(Duration::from_millis(10));
                }
                status => panic!("{mode} worker cleanup failed: {status:?}"),
            }
        }
    }
}
