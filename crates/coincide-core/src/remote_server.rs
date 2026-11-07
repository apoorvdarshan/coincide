//! The server Coincide Remote connects to, as `RemoteServer.swift` runs it: a
//! TLS 1.3 WebSocket listener on the local network (and Tailscale), advertised
//! with Bonjour. It runs only while "Allow Coincide Remote" is on, which it is
//! not by default, and the desktop works the same with or without phones
//! connected; everything a phone does goes through the adapter.
//!
//! Connections from outside loopback, private, link-local and Tailscale ranges
//! are dropped before TLS; at most `MAX_CONNECTIONS` exist at once, counting
//! those still authenticating. The certificate is self-signed and phones pin
//! its SHA-256 from the pairing code; no secret, token or hash is ever logged.
use super::{
    adapter::Adapter,
    addresses,
    bonjour::{self, Advertisement},
    identity::Identity,
    pairing::Pairing,
    protocol::{DEFAULT_PORT, Device, HostCandidate, MAX_MESSAGE_BYTES, PairingPayload, VERSION},
    secrets::{SecretBackend, SecretDeviceStorage},
    session::{Context, ITEM_INTERVAL, Session, WORKSPACE_INTERVAL},
};
use crate::api::SharedEngine;
use anyhow::{Context as _, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    io::ErrorKind,
    net::{IpAddr, Ipv6Addr, Shutdown, SocketAddr, TcpListener, TcpStream},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};
use tungstenite::{Message, protocol::WebSocketConfig};

/// At most this many phones at once, counting connections still authenticating.
pub const MAX_CONNECTIONS: usize = 12;
const ADDRESS_INTERVAL: Duration = Duration::from_secs(30);
const POLL: Duration = Duration::from_millis(50);

/// Coincide Remote's settings, in `remote.json` beside the app's data, with the
/// Mac's keys.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    /// Off by default: nothing listens until the user turns it on.
    #[serde(default)]
    pub is_enabled: bool,
    /// The port last listened on, reused so saved connections keep working.
    #[serde(default)]
    pub port: Option<u16>,
    /// Identifies this computer to phones, on Bonjour and in their saved connections.
    #[serde(rename = "serverID", default = "new_server_id")]
    pub server_id: String,
}
fn new_server_id() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            is_enabled: false,
            port: None,
            server_id: new_server_id(),
        }
    }
}
impl Settings {
    pub fn load(directory: &Path) -> Self {
        std::fs::read(directory.join("remote.json"))
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_default()
    }
    pub fn save(&self, directory: &Path) -> Result<()> {
        std::fs::create_dir_all(directory)?;
        let path = directory.join("remote.json");
        let temporary = directory.join("remote.json.tmp");
        std::fs::write(&temporary, serde_json::to_vec(self)?)?;
        std::fs::rename(temporary, path)?;
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Status {
    Off,
    Starting,
    Running { port: u16 },
    Failed(String),
}

/// What Settings shows.
#[derive(Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub enabled: bool,
    pub status: Status,
    pub fingerprint: Option<String>,
    pub candidates: Vec<HostCandidate>,
    pub devices: Vec<Device>,
    pub connected: HashSet<String>,
    /// The pairing code on screen, until it's used or cancelled.
    pub pairing: Option<PairingPayload>,
    /// The device that paired last, so the pairing sheet can say so.
    pub last_paired: Option<Device>,
    pub storage_error: Option<String>,
}

/// Where and how the server listens; tests listen on loopback without Bonjour.
#[derive(Clone, Debug)]
pub struct Options {
    pub bind: IpAddr,
    pub advertise: bool,
    pub name: String,
}
impl Default for Options {
    fn default() -> Self {
        Self {
            bind: IpAddr::V6(Ipv6Addr::UNSPECIFIED),
            advertise: true,
            name: addresses::computer_name(),
        }
    }
}

pub fn tls_config(identity: &Identity) -> Result<Arc<rustls::ServerConfig>> {
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_protocol_versions(&[&rustls::version::TLS13])?
    .with_no_client_auth()
    .with_single_cert(
        vec![CertificateDer::from(identity.certificate.clone())],
        PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(identity.key.to_vec())),
    )
    .context("Coincide couldn’t make a certificate for the remote server.")?;
    Ok(Arc::new(config))
}

/// The peer's address as rate limiting and the address policy see it.
fn canonical(address: IpAddr) -> IpAddr {
    match address {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(address),
        v4 => v4,
    }
}

struct Shared {
    stop: AtomicBool,
    pairing: Mutex<Pairing>,
    adapter: Adapter,
    sessions: Mutex<HashMap<u64, Arc<Mutex<Session>>>>,
    /// Authenticated devices by session, kept apart so Settings never waits
    /// on a session that's busy answering its phone.
    connected: Mutex<HashMap<u64, String>>,
    workers: Mutex<Vec<JoinHandle<()>>>,
    connections: AtomicUsize,
    // Owned descriptors include peers stalled before TLS/WebSocket authentication.
    sockets: Mutex<HashMap<u64, (TcpStream, Instant)>>,
    next_session: AtomicU64,
    server_id: String,
    name: String,
    port: u16,
    fingerprint: String,
    tls: Arc<rustls::ServerConfig>,
    candidates: Mutex<Vec<HostCandidate>>,
    tailscale_name: Mutex<Option<String>>,
    pairing_payload: Mutex<Option<PairingPayload>>,
    last_paired: Mutex<Option<Device>>,
}
impl Shared {
    fn with_context<T>(&self, work: impl FnOnce(&Context<'_>) -> T) -> T {
        let info = || self.adapter.server_info(&self.server_id, &self.name);
        work(&Context {
            adapter: &self.adapter,
            pairing: &self.pairing,
            server_info: &info,
        })
    }

    fn sessions(&self) -> Vec<Arc<Mutex<Session>>> {
        self.sessions
            .lock()
            .map(|sessions| sessions.values().cloned().collect())
            .unwrap_or_default()
    }

    fn refresh_addresses(self: &Arc<Self>) {
        let tailscale = self.tailscale_name.lock().ok().and_then(|n| n.clone());
        if let Ok(mut candidates) = self.candidates.lock() {
            *candidates = addresses::candidates(tailscale.as_deref());
        }
        let shared = self.clone();
        // The Tailscale tool can take seconds; the list updates when it answers.
        let worker = std::thread::spawn(move || {
            let name = addresses::tailscale_dns_name();
            if shared.stop.load(Ordering::Relaxed) {
                return;
            }
            if let Ok(mut known) = shared.tailscale_name.lock()
                && *known != name
            {
                *known = name.clone();
                if let Ok(mut candidates) = shared.candidates.lock() {
                    *candidates = addresses::candidates(name.as_deref());
                }
            }
        });
        if let Ok(mut workers) = self.workers.lock() {
            workers.retain(|w| !w.is_finished());
            workers.push(worker);
        }
    }
}

pub struct RemoteServer {
    directory: PathBuf,
    settings: Settings,
    secrets: Arc<dyn SecretBackend>,
    engine: SharedEngine,
    app_version: String,
    options: Options,
    status: Status,
    fingerprint: Option<String>,
    storage_error: Option<String>,
    running: Option<(Arc<Shared>, Option<Advertisement>)>,
}

impl RemoteServer {
    /// The app's server over its data directory, using the system secret store.
    pub fn new(directory: PathBuf, engine: SharedEngine, app_version: impl Into<String>) -> Self {
        let secrets = super::secrets::OsSecrets::for_directory(&directory);
        Self::with_options(directory, engine, app_version, secrets, Options::default())
    }

    pub fn with_options(
        directory: PathBuf,
        engine: SharedEngine,
        app_version: impl Into<String>,
        secrets: Arc<dyn SecretBackend>,
        options: Options,
    ) -> Self {
        let settings = Settings::load(&directory);
        Self {
            directory,
            settings,
            secrets,
            engine,
            app_version: app_version.into(),
            options,
            status: Status::Off,
            fingerprint: None,
            storage_error: None,
            running: None,
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.settings.is_enabled
    }

    pub fn status(&self) -> &Status {
        &self.status
    }

    /// Starts the server when Remote is on. Called once at launch.
    pub fn start_if_enabled(&mut self) {
        if self.settings.is_enabled {
            self.start();
        }
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        if enabled == self.settings.is_enabled {
            return;
        }
        self.settings.is_enabled = enabled;
        self.storage_error = self
            .settings
            .save(&self.directory)
            .err()
            .map(|_| "Coincide couldn’t save the Remote setting.".into());
        if enabled {
            self.start();
        } else {
            self.stop();
        }
    }

    fn start(&mut self) {
        if self.running.is_some() {
            return;
        }
        self.status = Status::Starting;
        match self.launch() {
            Ok((shared, advertisement)) => {
                self.status = Status::Running { port: shared.port };
                self.fingerprint = Some(shared.fingerprint.clone());
                if self.settings.port != Some(shared.port) {
                    self.settings.port = Some(shared.port);
                    let _ = self.settings.save(&self.directory);
                }
                self.running = Some((shared, advertisement));
            }
            Err(error) => self.status = Status::Failed(error.to_string()),
        }
    }

    fn launch(&mut self) -> Result<(Arc<Shared>, Option<Advertisement>)> {
        let identity = Identity::load_or_create(self.secrets.as_ref())?;
        self.fingerprint = Some(identity.fingerprint());
        let pairing = Pairing::new(Box::new(SecretDeviceStorage(self.secrets.clone())))
            .context("Coincide couldn’t read paired devices from the system secret store.")?;
        let tls = tls_config(&identity)?;
        let listener = self.listen(self.settings.port.unwrap_or(DEFAULT_PORT))?;
        let port = listener.local_addr()?.port();
        let shared = Arc::new(Shared {
            stop: AtomicBool::new(false),
            pairing: Mutex::new(pairing),
            adapter: Adapter::new(self.engine.clone(), self.app_version.clone()),
            sessions: Mutex::new(HashMap::new()),
            connected: Mutex::new(HashMap::new()),
            workers: Mutex::new(Vec::new()),
            connections: AtomicUsize::new(0),
            sockets: Mutex::new(HashMap::new()),
            next_session: AtomicU64::new(1),
            server_id: self.settings.server_id.clone(),
            name: self.options.name.clone(),
            port,
            fingerprint: identity.fingerprint(),
            tls,
            candidates: Mutex::new(Vec::new()),
            tailscale_name: Mutex::new(None),
            pairing_payload: Mutex::new(None),
            last_paired: Mutex::new(None),
        });
        let watch = {
            let shared = shared.clone();
            std::thread::Builder::new()
                .name("coincide-remote-watch".into())
                .spawn(move || watch_loop(shared))?
        };
        let accept = {
            let owner = shared.clone();
            match std::thread::Builder::new()
                .name("coincide-remote-accept".into())
                .spawn(move || accept_loop(listener, owner))
            {
                Ok(worker) => worker,
                Err(error) => {
                    shared.stop.store(true, Ordering::Relaxed);
                    let _ = watch.join();
                    return Err(error.into());
                }
            }
        };
        shared.refresh_addresses();
        if let Ok(mut workers) = shared.workers.lock() {
            workers.extend([accept, watch]);
        }
        // Phones still pair and reconnect through the code's addresses without it.
        let advertisement = self
            .options
            .advertise
            .then(|| bonjour::advertise(&shared.name, &shared.server_id, port).ok())
            .flatten();
        Ok((shared, advertisement))
    }

    /// Listens on every address, IPv4 and IPv6. The usual port may be taken
    /// (another copy of Coincide, say): then any port, which is remembered.
    fn listen(&self, port: u16) -> Result<TcpListener> {
        match bind(self.options.bind, port) {
            Err(error) if error.kind() == ErrorKind::AddrInUse && port != 0 => {
                Ok(bind(self.options.bind, 0)?)
            }
            other => Ok(other?),
        }
    }

    pub fn stop(&mut self) {
        if let Some((shared, advertisement)) = self.running.take() {
            drop(advertisement);
            shared.stop.store(true, Ordering::Relaxed);
            if let Ok(sockets) = shared.sockets.lock() {
                for (socket, _) in sockets.values() {
                    let _ = socket.shutdown(Shutdown::Both);
                }
            }
            let workers = shared
                .workers
                .lock()
                .map(|mut w| std::mem::take(&mut *w))
                .unwrap_or_default();
            for worker in workers {
                let _ = worker.join();
            }
            // Connection threads started while joining, if any.
            let late = shared
                .workers
                .lock()
                .map(|mut w| std::mem::take(&mut *w))
                .unwrap_or_default();
            for worker in late {
                let _ = worker.join();
            }
            if let Ok(mut pairing) = shared.pairing.lock() {
                pairing.cancel_secret();
            }
        }
        self.status = Status::Off;
    }

    pub fn snapshot(&self) -> Snapshot {
        let shared = self.running.as_ref().map(|(shared, _)| shared);
        let (devices, storage_error) = shared
            .and_then(|s| s.pairing.lock().ok())
            .map(|p| (p.paired_devices(), p.storage_error.clone()))
            .unwrap_or_default();
        Snapshot {
            enabled: self.settings.is_enabled,
            status: self.status.clone(),
            fingerprint: self.fingerprint.clone(),
            candidates: shared
                .and_then(|s| s.candidates.lock().ok().map(|c| c.clone()))
                .unwrap_or_default(),
            devices,
            connected: shared
                .and_then(|s| {
                    s.connected
                        .lock()
                        .ok()
                        .map(|c| c.values().cloned().collect())
                })
                .unwrap_or_default(),
            pairing: shared.and_then(|s| s.pairing_payload.lock().ok()?.clone()),
            last_paired: shared.and_then(|s| s.last_paired.lock().ok()?.clone()),
            storage_error: storage_error.or_else(|| self.storage_error.clone()),
        }
    }

    /// Shows a new pairing code, valid for a few minutes and for one phone.
    pub fn begin_pairing(&mut self) -> Option<PairingPayload> {
        let Status::Running { port } = self.status else {
            return None;
        };
        let (shared, _) = self.running.as_ref()?;
        let secret = shared.pairing.lock().ok()?.make_secret();
        let payload = PairingPayload {
            expires_at: secret.expires_at / 1000.,
            fingerprint: shared.fingerprint.clone(),
            hosts: shared.candidates.lock().ok()?.clone(),
            server_id: shared.server_id.clone(),
            name: shared.name.clone(),
            port,
            secret: secret.value,
            version: VERSION,
        };
        *shared.last_paired.lock().ok()? = None;
        *shared.pairing_payload.lock().ok()? = Some(payload.clone());
        Some(payload)
    }

    pub fn cancel_pairing(&mut self) {
        if let Some((shared, _)) = &self.running {
            if let Ok(mut pairing) = shared.pairing.lock() {
                pairing.cancel_secret();
            }
            if let Ok(mut payload) = shared.pairing_payload.lock() {
                *payload = None;
            }
        }
    }

    /// Forgets the device; a connected one is told and disconnected now.
    pub fn revoke(&mut self, device_id: &str) {
        let Some((shared, _)) = &self.running else {
            return;
        };
        if let Ok(mut pairing) = shared.pairing.lock() {
            pairing.revoke(device_id);
        }
        for session in shared.sessions() {
            if let Ok(mut session) = session.lock()
                && session.device_id() == Some(device_id)
            {
                session.revoke();
            }
        }
    }

    /// Makes a new certificate and forgets every paired device, which then
    /// pair again.
    pub fn reset_identity(&mut self) -> Result<()> {
        let was_running = self.running.is_some();
        self.stop();
        // Explicit reset also recovers malformed credentials without parsing or
        // silently overwriting them during ordinary startup.
        self.secrets.delete("devices")?;
        Identity::reset(self.secrets.as_ref())?;
        self.fingerprint = None;
        if was_running {
            self.start();
        }
        Ok(())
    }
}

impl Drop for RemoteServer {
    fn drop(&mut self) {
        self.stop();
    }
}

fn bind(address: IpAddr, port: u16) -> std::io::Result<TcpListener> {
    use socket2::{Domain, Protocol, Socket, Type};
    let domain = if address.is_ipv6() {
        Domain::IPV6
    } else {
        Domain::IPV4
    };
    let socket = Socket::new(domain, Type::STREAM, Some(Protocol::TCP))?;
    if address.is_ipv6() {
        // Both families on one socket; IPv4 peers arrive as mapped addresses.
        socket.set_only_v6(false)?;
    }
    // Rebinding the remembered port after a quick restart. Windows' meaning
    // of this option would let another program share the port, so not there.
    #[cfg(not(windows))]
    socket.set_reuse_address(true)?;
    socket.bind(&SocketAddr::new(address, port).into())?;
    socket.listen(16)?;
    let listener: TcpListener = socket.into();
    listener.set_nonblocking(true)?;
    Ok(listener)
}

fn accept_loop(listener: TcpListener, shared: Arc<Shared>) {
    while !shared.stop.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, address)) => {
                let peer = canonical(address.ip());
                // Local network and Tailscale only, and only so many at once.
                if !super::allowed_peer(peer)
                    || shared.connections.load(Ordering::SeqCst) >= MAX_CONNECTIONS
                {
                    drop(stream);
                    continue;
                }
                let id = shared.next_session.fetch_add(1, Ordering::Relaxed);
                let Ok(owned) = stream.try_clone() else {
                    continue;
                };
                let Ok(mut sockets) = shared.sockets.lock() else {
                    continue;
                };
                // stop may have started after accept; never publish another worker then.
                if shared.stop.load(Ordering::Relaxed) {
                    continue;
                }
                sockets.insert(id, (owned, Instant::now()));
                drop(sockets);
                shared.connections.fetch_add(1, Ordering::SeqCst);
                let worker_shared = shared.clone();
                let worker = std::thread::Builder::new()
                    .name("coincide-remote-connection".into())
                    .spawn(move || {
                        serve(stream, peer, id, &worker_shared);
                        if let Ok(mut sockets) = worker_shared.sockets.lock() {
                            sockets.remove(&id);
                        }
                        worker_shared.connections.fetch_sub(1, Ordering::SeqCst);
                    });
                match worker {
                    Ok(worker) => {
                        if let Ok(mut workers) = shared.workers.lock() {
                            workers.retain(|w| !w.is_finished());
                            workers.push(worker);
                        }
                    }
                    Err(_) => {
                        if let Ok(mut sockets) = shared.sockets.lock() {
                            sockets.remove(&id);
                        }
                        shared.connections.fetch_sub(1, Ordering::SeqCst);
                    }
                }
            }
            Err(_) => std::thread::sleep(Duration::from_millis(100)),
        }
    }
}

fn is_timeout(error: &tungstenite::Error) -> bool {
    matches!(error, tungstenite::Error::Io(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut))
}

/// One connection: TLS, the WebSocket handshake, then the session until either
/// side closes. Reads wait at most `POLL`, so changes found by the watcher go
/// out promptly between them.
fn serve(stream: TcpStream, peer: IpAddr, id: u64, shared: &Arc<Shared>) {
    let started = Instant::now();
    let setup = || -> std::io::Result<()> {
        stream.set_nonblocking(true)?;
        stream.set_nodelay(true)?;
        let keepalive = socket2::TcpKeepalive::new().with_time(Duration::from_secs(30));
        socket2::SockRef::from(&stream).set_tcp_keepalive(&keepalive)
    };
    if setup().is_err() {
        return;
    }
    let Ok(connection) = rustls::ServerConnection::new(shared.tls.clone()) else {
        return;
    };
    let tls = rustls::StreamOwned::new(connection, stream);
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_MESSAGE_BYTES))
        .max_frame_size(Some(MAX_MESSAGE_BYTES));
    // Resume the exact TLS/WebSocket handshake on WouldBlock. A shutdown on a
    // cloned Winsock handle need not interrupt an already blocked recv, so no
    // connection worker performs blocking socket I/O, including before auth.
    let mut handshake = tungstenite::accept_with_config(tls, Some(config));
    let mut socket = loop {
        if shared.stop.load(Ordering::Relaxed)
            || started.elapsed() >= super::session::AUTHENTICATION_TIMEOUT
        {
            return;
        }
        match handshake {
            Ok(socket) => break socket,
            Err(tungstenite::HandshakeError::Interrupted(pending)) => {
                std::thread::sleep(POLL);
                handshake = pending.handshake();
            }
            Err(_) => return,
        }
    };
    let mut session = Session::new(peer.to_string());
    // The handshake counts toward the time a phone has to authenticate.
    session.start_clock(started);
    let session = Arc::new(Mutex::new(session));
    if let Ok(mut sessions) = shared.sessions.lock() {
        sessions.insert(id, session.clone());
    }
    loop {
        let incoming = if shared.stop.load(Ordering::Relaxed) {
            None
        } else {
            match socket.read() {
                Ok(Message::Text(text)) => Some(Ok(text.as_bytes().to_vec())),
                Ok(Message::Binary(data)) => Some(Ok(data.to_vec())),
                Ok(Message::Close(_)) => Some(Err(())),
                Ok(_) => Some(Ok(Vec::new())),
                Err(error) if is_timeout(&error) => {
                    std::thread::sleep(POLL);
                    Some(Ok(Vec::new()))
                }
                Err(_) => Some(Err(())),
            }
        };
        let Ok(mut state) = session.lock() else { break };
        match incoming {
            None | Some(Err(())) => state.close(),
            Some(Ok(data)) if !data.is_empty() => {
                shared.with_context(|context| state.receive(&data, context))
            }
            Some(Ok(_)) => {}
        }
        state.check_timeout(Instant::now());
        if let Some(device) = state.paired.take() {
            if let Ok(mut payload) = shared.pairing_payload.lock() {
                *payload = None;
            }
            if let Ok(mut last) = shared.last_paired.lock() {
                *last = Some(device);
            }
        }
        let outgoing = state.take_outgoing();
        let closed = state.is_closed();
        let device = (!closed)
            .then(|| state.device_id().map(str::to_owned))
            .flatten();
        drop(state);
        if let Ok(mut connected) = shared.connected.lock() {
            match device {
                Some(device) => connected.insert(id, device),
                None => connected.remove(&id),
            };
        }
        let mut failed = false;
        for message in outgoing {
            if !send_bounded(
                &mut socket,
                Message::text(message.to_string()),
                &shared.stop,
            ) {
                failed = true;
                break;
            }
        }
        if failed {
            if let Ok(mut state) = session.lock() {
                state.close();
            }
            break;
        }
        if closed {
            // A close frame after what's queued, then hang up.
            let _ = socket.close(None);
            let _ = socket.flush();
            break;
        }
    }
    if let Ok(mut sessions) = shared.sessions.lock() {
        sessions.remove(&id);
    }
    if let Ok(mut connected) = shared.connected.lock() {
        connected.remove(&id);
    }
}

/// `send` queues the message once. On WouldBlock, flush that same queue rather
/// than sending it again; cancellation and one total write deadline remain live.
fn send_bounded(
    socket: &mut tungstenite::WebSocket<rustls::StreamOwned<rustls::ServerConnection, TcpStream>>,
    message: Message,
    stopping: &AtomicBool,
) -> bool {
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut outcome = socket.send(message);
    loop {
        if stopping.load(Ordering::Relaxed) || Instant::now() >= deadline {
            return false;
        }
        match outcome {
            Ok(()) => return true,
            Err(ref error) if is_timeout(error) => {
                std::thread::sleep(POLL);
                outcome = socket.flush();
            }
            Err(_) => return false,
        }
    }
}

/// Finds what changed in the engine and lets each session pass it on: items
/// every `ITEM_INTERVAL` while something changes, the sidebar at most every
/// `WORKSPACE_INTERVAL`, and the addresses every half minute.
fn watch_loop(shared: Arc<Shared>) {
    let mut revision = None;
    let mut workspace_dirty = false;
    let mut last_workspace = Instant::now();
    let mut last_addresses = Instant::now();
    while !shared.stop.load(Ordering::Relaxed) {
        std::thread::sleep(ITEM_INTERVAL);
        // A socket timeout resets on every read. Enforce one total deadline,
        // including TLS and WebSocket handshakes, even if a peer drips bytes.
        let authenticated = shared
            .connected
            .lock()
            .map(|c| c.keys().copied().collect::<HashSet<_>>())
            .unwrap_or_default();
        if let Ok(sockets) = shared.sockets.lock() {
            for (id, (socket, accepted)) in sockets.iter() {
                if !authenticated.contains(id)
                    && accepted.elapsed() >= super::session::AUTHENTICATION_TIMEOUT
                {
                    let _ = socket.shutdown(Shutdown::Both);
                }
            }
        }
        let sessions = shared.sessions();
        if last_addresses.elapsed() >= ADDRESS_INTERVAL {
            last_addresses = Instant::now();
            shared.refresh_addresses();
        }
        if sessions.is_empty() {
            continue;
        }
        let current = shared.adapter.revision();
        let changed = current != revision;
        revision = current;
        workspace_dirty |= changed;
        let workspace = workspace_dirty && last_workspace.elapsed() >= WORKSPACE_INTERVAL;
        if !changed && !workspace {
            continue;
        }
        if workspace {
            workspace_dirty = false;
            last_workspace = Instant::now();
        }
        for session in sessions {
            if shared.stop.load(Ordering::Relaxed) {
                return;
            }
            if let Ok(mut session) = session.lock() {
                shared.with_context(|context| session.refresh(context, workspace));
            }
        }
    }
}

#[cfg(test)]
#[path = "remote_server_tests.rs"]
mod tests;
