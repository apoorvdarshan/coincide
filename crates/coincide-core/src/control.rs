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
        atomic::{AtomicBool, Ordering},
    },
    thread,
};
const MAX_FRAME: u64 = 4 * 1024 * 1024;
pub struct Server {
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
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
    let stop = Arc::new(AtomicBool::new(false));
    let stopping = stop.clone();
    let worker = thread::spawn(move || {
        while !stopping.load(Ordering::Relaxed) {
            if let Ok(mut engine) = engine.lock() {
                engine.poll();
            }
            match listener.accept() {
                Ok((mut stream, _)) => {
                    let response = (|| -> Result<Value> {
                        configure_client_stream(&stream)?;
                        let request = read_frame(&mut stream)?;
                        Ok(engine
                            .lock()
                            .map_err(|_| anyhow::anyhow!("Engine lock failed"))?
                            .dispatch(request))
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
    });
    Ok(Server {
        stop,
        worker: Some(worker),
    })
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
