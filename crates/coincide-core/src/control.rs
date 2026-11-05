//! Owner-only local socket. No listening TCP port and no browser-accessible endpoint.
use crate::api::SharedEngine;
use anyhow::{Context, Result, ensure};
use serde_json::Value;
#[cfg(unix)]
use std::os::unix::{
    fs::PermissionsExt,
    net::{UnixListener, UnixStream},
};
use std::{
    io::{BufRead, BufReader, Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
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
    std::fs::create_dir_all(parent)?;
    // Callers use the dedicated Rust data directory, never the legacy directory.
    std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?;
    ensure!(
        !path.exists(),
        "Control socket already exists; another Rust instance may be running"
    );
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
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
                    let response = (|| -> Result<Value> {
                        let request = read_frame(&mut stream)?;
                        Ok(engine
                            .lock()
                            .map_err(|_| anyhow::anyhow!("Engine lock failed"))?
                            .dispatch(request))
                    })()
                    .unwrap_or_else(|e| serde_json::json!({"error":{"message":e.to_string()}}));
                    let _ = write_frame(&mut stream, &response);
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
#[cfg(not(unix))]
pub fn serve(_path: PathBuf, _engine: SharedEngine) -> Result<Server> {
    anyhow::bail!("Windows named-pipe transport is not implemented yet")
}
#[cfg(unix)]
pub fn request(path: &Path, request: &Value) -> Result<Value> {
    let mut stream =
        UnixStream::connect(path).context("Cannot reach the Rust Coincide instance")?;
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    stream.set_write_timeout(Some(Duration::from_secs(10)))?;
    write_frame(&mut stream, request)?;
    read_frame(&mut stream)
}
#[cfg(not(unix))]
pub fn request(_path: &Path, _request: &Value) -> Result<Value> {
    anyhow::bail!("Windows named-pipe transport is not implemented yet")
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
        bytes.len() as u64 <= MAX_FRAME,
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
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME is missing")?;
    Ok(if cfg!(target_os = "macos") {
        home.join("Library/Application Support/Coincide Rust")
    } else {
        home.join(".local/share/coincide-rust")
    })
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
            Store::open(&dir.path().join("db")).unwrap(),
        )));
        let path = dir.path().join("control.sock");
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
}
