//! Owner-only local transport. No TCP port or browser-accessible endpoint.
#[cfg(windows)]
#[path = "control_windows.rs"]
mod windows;
#[cfg(not(windows))]
use crate::api::SharedEngine;
use anyhow::{Context, Result, ensure};
use serde_json::Value;
#[cfg(unix)]
use std::os::unix::{
    fs::PermissionsExt,
    net::{UnixListener, UnixStream},
};
#[cfg(not(windows))]
use std::path::Path;
#[cfg(unix)]
use std::time::Duration;
use std::{
    io::{BufRead, BufReader, Read, Write},
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU8, Ordering},
    },
    thread,
};
#[cfg(windows)]
pub(crate) use windows::{
    current_sid, private_descriptor, private_directory_descriptor, verify_file_owner,
    verify_private_path,
};
const MAX_FRAME: u64 = 4 * 1024 * 1024;
/// Settings › General › Command Line's "Command-line control". Off, every
/// request on the socket is refused; the socket itself stays, as it also
/// keeps a second instance from starting. Unset or unreadable means on.
fn dispatch_command_line(engine: &mut crate::api::Engine, request: Value) -> Value {
    let refused = engine
        .store
        .document("settings.json")
        .ok()
        .flatten()
        .is_some_and(|settings| settings["commandLineControl"] == false);
    if refused {
        return serde_json::json!({"id":request["id"],"error":{"message":"Command-line control is off. Turn it on in Coincide's Settings › General › Command Line."}});
    }
    engine.dispatch(request)
}
/// Observation of the retained control worker, not application quiescence or
/// proof that every operating-system resource has been released.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WorkerStatus {
    Running,
    /// A background observer joined the serve worker with a normal return.
    Returned,
    /// The observer joined a panicked serve worker and resumed its panic.
    Panicked,
    /// No retained handle, or a finished handle with no classified outcome.
    Unclassified,
}
pub struct Server {
    stop: Arc<AtomicBool>,
    // The observer exclusively owns/joins the actual serve worker. Retaining
    // this handle keeps Drop's blocking completion behavior without joining
    // from request_stop or worker_status.
    worker: Option<thread::JoinHandle<()>>,
    outcome: Arc<AtomicU8>,
}
impl Server {
    /// Ask the worker to stop without joining, waiting, or interrupting an
    /// accepted client exchange. This is a request, not an exit acknowledgement.
    pub fn request_stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }

    /// Observe the background join acknowledgement without waiting or joining.
    /// Owners must observe a non-Running status before dropping this server,
    /// outside Engine/UI locks: Drop still joins the retained observer.
    /// JoinHandle::is_finished alone can precede native TLS cleanup. The outcome
    /// is therefore published only after the observer's actual worker.join()
    /// returns, and the observer handle must also report finished.
    pub fn worker_status(&self) -> WorkerStatus {
        let Some(worker) = self.worker.as_ref() else {
            return WorkerStatus::Unclassified;
        };
        if !worker.is_finished() {
            return WorkerStatus::Running;
        }
        match self.outcome.load(Ordering::Acquire) {
            1 => WorkerStatus::Returned,
            2 => WorkerStatus::Panicked,
            _ => WorkerStatus::Unclassified,
        }
    }

    fn spawn(work: impl FnOnce(Arc<AtomicBool>) + Send + 'static) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let outcome = Arc::new(AtomicU8::new(0));
        let observed = outcome.clone();
        let serving = thread::spawn(move || work(stopping));
        let worker = thread::spawn(move || {
            // Joining happens only on this dedicated observer thread, never on
            // an Engine/UI owner. The acknowledgement follows native worker
            // completion, including TLS teardown. Preserve the panic payload
            // instead of converting a failed serve worker into a clean return.
            match serving.join() {
                Ok(()) => observed.store(1, Ordering::Release),
                Err(panic) => {
                    observed.store(2, Ordering::Release);
                    std::panic::resume_unwind(panic);
                }
            }
        });
        Self {
            stop,
            worker: Some(worker),
            outcome,
        }
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
#[cfg(unix)]
pub fn serve(path: PathBuf, engine: SharedEngine) -> Result<Server> {
    let parent = path
        .parent()
        .context("Socket requires a parent directory")?;
    let existed = parent.exists();
    std::fs::create_dir_all(parent)?;
    if !existed {
        std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?;
    }
    ensure!(
        std::fs::metadata(parent)?.permissions().mode() & 0o077 == 0,
        "Control directory must be private (mode 700)"
    );
    if path.exists() {
        use std::os::unix::fs::{FileTypeExt, MetadataExt};
        let metadata = std::fs::symlink_metadata(&path)?;
        ensure!(
            metadata.file_type().is_socket() && metadata.uid() == std::fs::metadata(parent)?.uid(),
            "Control path is not an owned socket"
        );
        match UnixStream::connect(&path) {
            Ok(_) => anyhow::bail!("Another Rust instance is running"),
            Err(error) if error.kind() == std::io::ErrorKind::ConnectionRefused => {
                std::fs::remove_file(&path)?
            }
            Err(error) => return Err(error.into()),
        }
    }
    let listener = UnixListener::bind(&path)?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    Ok(Server::spawn(move |stopping| {
        while !stopping.load(Ordering::Relaxed) {
            if let Ok(mut engine) = engine.lock() {
                engine.poll();
            }
            match listener.accept() {
                Ok((mut stream, _)) => {
                    let response = (|| -> Result<Value> {
                        configure_client_stream(&stream)?;
                        let request = read_frame(&mut stream)?;
                        let mut engine = engine
                            .lock()
                            .map_err(|_| anyhow::anyhow!("Engine lock failed"))?;
                        Ok(dispatch_command_line(&mut engine, request))
                    })()
                    .unwrap_or_else(|e| serde_json::json!({"error":{"message":e.to_string()}}));
                    if serde_json::to_vec(&response)
                        .is_ok_and(|bytes| bytes.len() as u64 >= MAX_FRAME)
                    {
                        let _ = write_frame(
                            &mut stream,
                            &serde_json::json!({"id":response["id"],"error":{"message":"Response exceeds 4 MiB; use itemLimit/itemOffset with threads.read"}}),
                        );
                    } else {
                        let _ = write_frame(&mut stream, &response);
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(20))
                }
                Err(_) => break,
            }
        }
        let _ = std::fs::remove_file(path);
    }))
}
#[cfg(windows)]
pub use windows::{request, serve};
#[cfg(not(any(unix, windows)))]
pub fn serve(_path: PathBuf, _engine: SharedEngine) -> Result<Server> {
    anyhow::bail!("Local control transport is unavailable on this platform")
}
#[cfg(unix)]
fn configure_client_stream(stream: &UnixStream) -> Result<()> {
    // Darwin/BSD accept() inherits O_NONBLOCK from the listener; Linux does not.
    // The listener must remain nonblocking for the polling loop, but each framed
    // exchange needs blocking I/O with a deadline. Otherwise a client connected
    // just before writing is rejected with WouldBlock and then sees BrokenPipe.
    stream
        .set_nonblocking(false)
        .context("Configuring control client blocking I/O")?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    Ok(())
}
#[cfg(unix)]
pub fn request(path: &Path, request: &Value) -> Result<Value> {
    let mut stream =
        UnixStream::connect(path).context("Cannot reach the Rust Coincide instance")?;
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    stream.set_write_timeout(Some(Duration::from_secs(10)))?;
    write_frame(&mut stream, request).context("Sending control request")?;
    read_frame(&mut stream).context("Reading control reply")
}
#[cfg(not(any(unix, windows)))]
pub fn request(_path: &Path, _request: &Value) -> Result<Value> {
    anyhow::bail!("Local control transport is unavailable on this platform")
}
fn read_frame(stream: &mut impl Read) -> Result<Value> {
    let mut bytes = Vec::new();
    let n = BufReader::new(stream.take(MAX_FRAME + 1)).read_until(b'\n', &mut bytes)?;
    ensure!(
        n > 0 && n as u64 <= MAX_FRAME && bytes.last() == Some(&b'\n'),
        "Invalid or oversized control frame"
    );
    Ok(serde_json::from_slice(&bytes)?)
}
fn write_frame(stream: &mut impl Write, frame: &Value) -> Result<()> {
    let bytes = serde_json::to_vec(frame)?;
    ensure!(
        (bytes.len() as u64) < MAX_FRAME,
        "Control response exceeds 4 MiB"
    );
    stream.write_all(&bytes)?;
    stream.write_all(b"\n")?;
    Ok(())
}
pub fn data_directory() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("COINCIDE_RUST_DATA_DIR") {
        return Ok(path.into());
    }
    #[cfg(windows)]
    {
        std::env::var_os("LOCALAPPDATA")
            .filter(|path| !path.is_empty())
            .map(|path| PathBuf::from(path).join("Coincide Rust"))
            .context("LOCALAPPDATA is missing; set COINCIDE_RUST_DATA_DIR explicitly")
    }
    #[cfg(not(windows))]
    {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .context("HOME is missing")?;
        Ok(if cfg!(target_os = "macos") {
            home.join("Library/Application Support/Coincide Rust")
        } else {
            home.join(".local/share/coincide-rust")
        })
    }
}

#[cfg(test)]
mod framing_tests {
    use super::*;
    #[test]
    fn frame_limit_includes_newline_and_rejects_partial_frames() {
        let largest = Value::String("x".repeat(MAX_FRAME as usize - 3));
        let mut bytes = Vec::new();
        write_frame(&mut bytes, &largest).unwrap();
        assert_eq!(bytes.len() as u64, MAX_FRAME);
        assert_eq!(read_frame(&mut bytes.as_slice()).unwrap(), largest);
        bytes.pop();
        assert!(read_frame(&mut bytes.as_slice()).is_err());
        let oversized = Value::String("x".repeat(MAX_FRAME as usize - 2));
        assert!(write_frame(&mut Vec::new(), &oversized).is_err());
    }
}
#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::{api::Engine, store::Store};
    use serde_json::json;
    use std::sync::Mutex;
    #[test]
    fn command_line_control_off_refuses_socket_requests_until_turned_back_on() {
        let dir = tempfile::tempdir().unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(
            Store::open(&dir.path().join("instance/db")).unwrap(),
        )));
        let path = dir.path().join("instance/control.sock");
        let server = serve(path.clone(), engine.clone()).unwrap();
        let list = json!({"id":7,"method":"threads.list","params":{}});
        assert!(request(&path, &list).unwrap()["result"].is_array());
        engine.lock().unwrap().dispatch(
            json!({"method":"settings.patch","params":{"patch":{"commandLineControl":false}}}),
        );
        let refused = request(&path, &list).unwrap();
        assert_eq!(refused["id"], 7);
        assert!(
            refused["error"]["message"]
                .as_str()
                .unwrap()
                .contains("Command-line control is off")
        );
        // Restore Defaults clears the key, which reads as on.
        engine.lock().unwrap().dispatch(
            json!({"method":"settings.patch","params":{"patch":{"commandLineControl":null}}}),
        );
        assert!(request(&path, &list).unwrap()["result"].is_array());
        drop(server);
    }
    #[test]
    fn socket_commands_reach_shared_state_and_do_not_replace_active_socket() {
        let dir = tempfile::tempdir().unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(
            Store::open(&dir.path().join("instance/db")).unwrap(),
        )));
        let path = dir.path().join("instance/control.sock");
        let server = serve(path.clone(), engine.clone()).unwrap();
        assert!(serve(path.clone(), engine.clone()).is_err());
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let created = request(
            &path,
            &json!({"id":1,"method":"threads.create","params":{}}),
        )
        .unwrap();
        assert!(created["result"]["id"].is_string());
        let listed = request(&path, &json!({"id":2,"method":"threads.list","params":{}})).unwrap();
        assert_eq!(listed["result"].as_array().unwrap().len(), 1);
        assert_eq!(
            engine
                .lock()
                .unwrap()
                .store
                .summaries("", false)
                .unwrap()
                .len(),
            1
        );
        drop(server);
        assert!(!path.exists());
    }
    #[test]
    fn accepted_nonblocking_listener_stream_becomes_blocking() {
        use std::os::fd::AsRawFd;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("stream.sock");
        let listener = UnixListener::bind(&path).unwrap();
        listener.set_nonblocking(true).unwrap();
        let _client = UnixStream::connect(&path).unwrap();
        let (stream, _) = listener.accept().unwrap();
        configure_client_stream(&stream).unwrap();
        // This deterministically catches inherited nonblocking mode on Darwin,
        // independent of the timing of a client's first write.
        let flags = unsafe { libc::fcntl(stream.as_raw_fd(), libc::F_GETFL) };
        assert!(flags >= 0);
        assert_eq!(flags & libc::O_NONBLOCK, 0);
        assert!(stream.read_timeout().unwrap().is_some());
        assert!(stream.write_timeout().unwrap().is_some());
    }

    #[test]
    fn server_waits_for_delayed_and_split_request_frame() {
        use std::sync::mpsc;
        let dir = tempfile::tempdir().unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(
            Store::open(&dir.path().join("instance/db")).unwrap(),
        )));
        let path = dir.path().join("instance/control.sock");
        let _server = serve(path.clone(), engine).unwrap();
        let mut client = UnixStream::connect(&path).unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let mut reader = client.try_clone().unwrap();
        let (sender, response) = mpsc::channel();
        let worker = thread::spawn(move || {
            let _ = sender.send(read_frame(&mut reader));
        });
        // A valid connection must wait for the request, not immediately return
        // an error because the first read arrived before any bytes did.
        assert!(matches!(
            response.recv_timeout(Duration::from_millis(50)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        client
            .write_all(b"{\"id\":7,\"method\":\"app.status\"")
            .unwrap();
        // Frame boundaries are newlines, not the currently available bytes.
        assert!(matches!(
            response.recv_timeout(Duration::from_millis(50)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        client.write_all(b",\"params\":{}}\n").unwrap();
        let reply = response
            .recv_timeout(Duration::from_secs(3))
            .unwrap()
            .unwrap();
        worker.join().unwrap();
        assert_eq!(reply["id"], 7);
        assert_eq!(reply["result"]["preview"], true);
        assert!(reply.get("error").is_none());
    }
}

#[cfg(test)]
mod worker_status_tests {
    use super::*;
    use std::{
        cell::RefCell,
        sync::mpsc,
        time::{Duration, Instant},
    };

    // The deadline bounds a broken test; completion is established only by the
    // retained handle, never by assuming that a sleep was long enough.
    fn finished(server: &Server) -> WorkerStatus {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let status = server.worker_status();
            if status != WorkerStatus::Running {
                return status;
            }
            assert!(Instant::now() < deadline, "gated worker did not finish");
            thread::yield_now();
        }
    }

    #[test]
    fn stop_request_does_not_wait_for_accepted_exchange_or_cleanup() {
        let (accepted_tx, accepted_rx) = mpsc::channel();
        let (request_tx, request_rx) = mpsc::channel::<Vec<u8>>();
        let (reply_tx, reply_rx) = mpsc::channel();
        let (ack_tx, ack_rx) = mpsc::channel();
        let cleaned = Arc::new(AtomicBool::new(false));
        let worker_cleaned = cleaned.clone();
        let server = Server::spawn(move |stop| {
            accepted_tx.send(()).unwrap();
            // A fake accepted exchange, without Engine discovery or transport
            // permissions changes. Stop does not truncate an accepted frame,
            // its reply, or the completion acknowledgement/cleanup boundary.
            let bytes = request_rx.recv_timeout(Duration::from_secs(5)).unwrap();
            assert!(stop.load(Ordering::Relaxed));
            let request = read_frame(&mut bytes.as_slice()).unwrap();
            let mut reply = Vec::new();
            write_frame(
                &mut reply,
                &serde_json::json!({"id":request["id"],"done":true}),
            )
            .unwrap();
            reply_tx.send(reply).unwrap();
            ack_rx.recv_timeout(Duration::from_secs(5)).unwrap();
            worker_cleaned.store(true, Ordering::Release);
        });
        accepted_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        server.request_stop();
        server.request_stop();
        assert!(server.stop.load(Ordering::Relaxed));
        assert_eq!(server.worker_status(), WorkerStatus::Running);
        assert!(!cleaned.load(Ordering::Acquire));
        request_tx.send(b"{\"id\":7}\n".to_vec()).unwrap();
        let reply = reply_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(
            read_frame(&mut reply.as_slice()).unwrap(),
            serde_json::json!({"id":7,"done":true})
        );
        assert_eq!(server.worker_status(), WorkerStatus::Running);
        assert!(!cleaned.load(Ordering::Acquire));
        ack_tx.send(()).unwrap();
        assert_eq!(finished(&server), WorkerStatus::Returned);
        assert!(cleaned.load(Ordering::Acquire));
        drop(server);
    }

    struct ExitGate {
        entered: mpsc::Sender<()>,
        release: mpsc::Receiver<()>,
    }
    impl Drop for ExitGate {
        fn drop(&mut self) {
            // A broken assertion must not panic inside a TLS destructor or
            // leave Server::drop joining a permanently gated fixture.
            let _ = self.entered.send(());
            let _ = self.release.recv_timeout(Duration::from_secs(5));
        }
    }
    thread_local! { static EXIT_GATE: RefCell<Option<ExitGate>> = const { RefCell::new(None) }; }

    #[test]
    fn recorded_return_stays_running_until_thread_local_cleanup_finishes() {
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let server = Server::spawn(move |_| {
            EXIT_GATE.with(|slot| {
                *slot.borrow_mut() = Some(ExitGate {
                    entered: entered_tx,
                    release: release_rx,
                })
            });
        });
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        // The serve closure has returned, but its TLS destructor is gated.
        // No actual-join acknowledgement may be published yet, even on hosts
        // where the serve JoinHandle::is_finished is already true here.
        assert_eq!(server.outcome.load(Ordering::Acquire), 0);
        assert!(!server.worker.as_ref().unwrap().is_finished());
        assert_eq!(server.worker_status(), WorkerStatus::Running);
        server.request_stop();
        release_tx.send(()).unwrap();
        assert_eq!(finished(&server), WorkerStatus::Returned);
    }

    #[test]
    fn worker_panic_is_recorded_and_resumed_not_a_clean_return() {
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let mut server = Server::spawn(move |_| {
            entered_tx.send(()).unwrap();
            release_rx.recv_timeout(Duration::from_secs(5)).unwrap();
            std::panic::panic_any(73_u32);
        });
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(server.worker_status(), WorkerStatus::Running);
        release_tx.send(()).unwrap();
        assert_eq!(finished(&server), WorkerStatus::Panicked);
        let panic = server.worker.take().unwrap().join().unwrap_err();
        assert_eq!(*panic.downcast::<u32>().unwrap(), 73);
        assert_eq!(server.worker_status(), WorkerStatus::Unclassified);
    }

    #[test]
    fn finished_worker_without_observed_outcome_is_unclassified() {
        let server = Server {
            stop: Arc::new(AtomicBool::new(false)),
            worker: Some(thread::spawn(|| {})),
            outcome: Arc::new(AtomicU8::new(0)),
        };
        assert_eq!(finished(&server), WorkerStatus::Unclassified);
    }
}
