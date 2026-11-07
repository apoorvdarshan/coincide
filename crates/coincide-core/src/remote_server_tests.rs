//! In-process fixtures only: a real server on loopback with an in-memory secret
//! store and a fixture engine, and a client that connects the way the phone's
//! `RemoteSocket` does (TLS 1.3, trusting exactly the pinned SHA-256).
use super::*;
use crate::api::{Engine, call};
use crate::remote::{crypto, secrets::MemorySecrets};
use crate::store::Store;
use rustls::{
    DigitallySignedStruct, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    pki_types::{CertificateDer, ServerName, UnixTime},
};
use serde_json::{Value, json};
use std::net::Ipv4Addr;

#[derive(Debug)]
struct Pinned(String);
impl ServerCertVerifier for Pinned {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        if crypto::constant_time_equals(&crypto::sha256_hex(end_entity), &self.0) {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General("certificate mismatch".into()))
        }
    }
    fn verify_tls12_signature(
        &self,
        _: &[u8],
        _: &CertificateDer<'_>,
        _: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General("TLS 1.2 is not offered".into()))
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

type Client = tungstenite::WebSocket<rustls::StreamOwned<rustls::ClientConnection, TcpStream>>;

fn connect(port: u16, fingerprint: &str) -> Result<Client, String> {
    let stream = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).map_err(|e| e.to_string())?;
    connect_stream(port, fingerprint, stream)
}
fn connect_stream(port: u16, fingerprint: &str, stream: TcpStream) -> Result<Client, String> {
    let config = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_protocol_versions(&[&rustls::version::TLS13])
    .unwrap()
    .dangerous()
    .with_custom_certificate_verifier(Arc::new(Pinned(fingerprint.into())))
    .with_no_client_auth();
    let connection = rustls::ClientConnection::new(
        Arc::new(config),
        ServerName::IpAddress(Ipv4Addr::LOCALHOST.into()),
    )
    .unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let tls = rustls::StreamOwned::new(connection, stream);
    tungstenite::client::client_with_config(format!("wss://127.0.0.1:{port}/coincide"), tls, None)
        .map(|(socket, _)| socket)
        .map_err(|e| e.to_string())
}

fn request(client: &mut Client, id: &str, kind: &str, body: Option<Value>) {
    let mut message = json!({"v":1,"id":id,"type":kind});
    if let Some(body) = body {
        message["body"] = body;
    }
    client.send(Message::text(message.to_string())).unwrap();
}

/// The next message, or None once the server closed the connection.
fn next(client: &mut Client) -> Option<Value> {
    loop {
        match client.read() {
            Ok(Message::Text(text)) => return Some(serde_json::from_str(text.as_str()).unwrap()),
            Ok(Message::Close(_)) => return None,
            Ok(_) => continue,
            Err(_) => return None,
        }
    }
}

/// The reply to `id`, skipping events.
fn reply(client: &mut Client, id: &str) -> Value {
    loop {
        let message = next(client).expect("connection closed before the reply");
        if message["re"] == id {
            return message;
        }
    }
}

/// The next event of `kind`, skipping others.
fn event_of(client: &mut Client, kind: &str) -> Value {
    loop {
        let message = next(client).expect("connection closed before the event");
        if message["kind"] == "event" && message["type"] == kind {
            return message;
        }
    }
}

struct Fixture {
    _dir: tempfile::TempDir,
    engine: SharedEngine,
    server: RemoteServer,
    secrets: Arc<MemorySecrets>,
    thread: String,
}

fn fixture() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let engine = Arc::new(Mutex::new(Engine::fixture(
        Store::open(&dir.path().join("state.sqlite")).unwrap(),
    )));
    let folder = dir.path().join("project");
    std::fs::create_dir(&folder).unwrap();
    let project = call(
        &engine,
        "projects.create",
        json!({"path":folder,"name":"Fixture"}),
    )
    .unwrap();
    let thread = call(
        &engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    )
    .unwrap();
    call(
        &engine,
        "threads.patch",
        json!({"threadId":thread["id"],"patch":{"title":"Synthetic thread"}}),
    )
    .unwrap();
    // Any free port, so tests can run side by side.
    let data = dir.path().join("data");
    Settings {
        is_enabled: false,
        port: Some(0),
        server_id: "FIXTURE-SERVER".into(),
    }
    .save(&data)
    .unwrap();
    let secrets = Arc::new(MemorySecrets::default());
    let server = RemoteServer::with_options(
        data,
        engine.clone(),
        "9.9.9",
        secrets.clone(),
        Options {
            bind: IpAddr::V4(Ipv4Addr::LOCALHOST),
            advertise: false,
            name: "Fixture Computer".into(),
        },
    );
    Fixture {
        _dir: dir,
        engine,
        server,
        thread: thread["id"].as_str().unwrap().to_owned(),
        secrets,
    }
}

fn running_port(server: &RemoteServer) -> u16 {
    match server.status() {
        Status::Running { port } => *port,
        other => panic!("not running: {other:?}"),
    }
}

/// Pairs a client through the server's code and returns it with its device id and token.
fn pair(fixture: &mut Fixture) -> (Client, String, String) {
    let payload = fixture.server.begin_pairing().unwrap();
    let mut client = connect(payload.port, &payload.fingerprint).unwrap();
    request(
        &mut client,
        "p",
        "pair",
        Some(json!({"secret":payload.secret,"deviceName":"Fixture iPhone"})),
    );
    let paired = reply(&mut client, "p");
    assert_eq!(paired["kind"], "response", "{paired}");
    assert_eq!(paired["type"], "paired");
    let body = &paired["body"];
    (
        client,
        body["deviceID"].as_str().unwrap().to_owned(),
        body["token"].as_str().unwrap().to_owned(),
    )
}

#[test]
fn off_by_default_and_nothing_is_read_until_enabled() {
    let mut fixture = fixture();
    assert!(!fixture.server.is_enabled());
    fixture.server.start_if_enabled();
    let snapshot = fixture.server.snapshot();
    assert_eq!(snapshot.status, Status::Off);
    assert!(snapshot.fingerprint.is_none() && snapshot.devices.is_empty());
    assert!(fixture.secrets.0.lock().unwrap().is_empty());
    assert!(fixture.server.begin_pairing().is_none());
    fixture.server.set_enabled(true);
    let port = running_port(&fixture.server);
    assert_ne!(port, 0);
    let saved = Settings::load(&fixture.server.directory);
    assert!(saved.is_enabled);
    assert_eq!(saved.port, Some(port));
    assert_eq!(saved.server_id, "FIXTURE-SERVER");
    fixture.server.set_enabled(false);
    assert_eq!(fixture.server.status(), &Status::Off);
    assert!(TcpStream::connect((Ipv4Addr::LOCALHOST, port)).is_err());
}

#[test]
fn pairing_then_hello_drives_the_workspace_and_open_threads() {
    let mut fixture = fixture();
    fixture.server.set_enabled(true);
    let (mut client, device, token) = pair(&mut fixture);
    let snapshot = fixture.server.snapshot();
    assert_eq!(snapshot.devices.len(), 1);
    assert_eq!(snapshot.devices[0].name, "Fixture iPhone");
    assert_eq!(
        snapshot.last_paired.as_ref().map(|d| d.id.as_str()),
        Some(device.as_str())
    );
    assert!(snapshot.pairing.is_none(), "a used code leaves the screen");
    assert!(snapshot.connected.contains(&device));
    // Only the token's hash is kept.
    let stored = fixture.secrets.0.lock().unwrap()["devices"].clone();
    assert!(!String::from_utf8(stored).unwrap().contains(&token));
    drop(client);

    let port = running_port(&fixture.server);
    let fingerprint = fixture.server.snapshot().fingerprint.unwrap();
    client = connect(port, &fingerprint).unwrap();
    request(
        &mut client,
        "h",
        "hello",
        Some(json!({"deviceID":device,"token":token,"appVersion":"1.0"})),
    );
    let hello = reply(&mut client, "h");
    assert_eq!(hello["type"], "server", "{hello}");
    assert_eq!(hello["body"]["serverID"], "FIXTURE-SERVER");
    assert_eq!(hello["body"]["name"], "Fixture Computer");
    assert_eq!(hello["body"]["appVersion"], "9.9.9");
    assert_eq!(hello["body"]["protocolVersion"], 1);

    request(
        &mut client,
        "w",
        "workspace",
        Some(json!({"includeArchived":false})),
    );
    let workspace = reply(&mut client, "w");
    let body = &workspace["body"];
    assert_eq!(body["projects"][0]["name"], "Fixture");
    assert_eq!(
        body["projects"].as_array().unwrap().last().unwrap()["isChats"],
        true
    );
    let thread = body["threads"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["title"] == "Synthetic thread")
        .expect("the fixture thread")
        .clone();
    assert_eq!(thread["projectID"], body["projects"][0]["id"]);
    assert_eq!(thread["isRunning"], false);
    assert_eq!(thread["selection"]["provider"], "codex");

    request(
        &mut client,
        "o",
        "openThread",
        Some(json!({"threadID":thread["id"],"limit":50})),
    );
    let opened = reply(&mut client, "o");
    assert_eq!(opened["type"], "transcript", "{opened}");
    assert_eq!(opened["body"]["items"], json!([]));
    assert_eq!(opened["body"]["turn"]["isRunning"], false);

    // A rename reaches the sidebar; an appended item reaches the open thread.
    request(
        &mut client,
        "r",
        "threadAction",
        Some(json!({"threadID":thread["id"],"action":{"action":"rename","title":"Renamed"}})),
    );
    assert_eq!(reply(&mut client, "r")["type"], "ok");
    let changed = event_of(&mut client, "workspace");
    assert!(
        changed["body"]["threads"]
            .as_array()
            .unwrap()
            .iter()
            .any(|t| t["title"] == "Renamed")
    );
    {
        let mut engine = fixture.engine.lock().unwrap();
        let mut document = engine.store.thread(&fixture.thread).unwrap();
        document["items"] = json!([{"id":"7D3F5A3E-0000-4000-8000-000000000001","kind":"assistant","text":"Synthetic reply","createdAt":1.0}]);
        engine.store.save(&document).unwrap();
        engine.revision += 1;
    }
    let items = event_of(&mut client, "items");
    assert_eq!(items["body"]["count"], 1);
    assert_eq!(items["body"]["items"][0]["text"], "Synthetic reply");
    assert_eq!(items["body"]["items"][0]["index"], 0);

    request(&mut client, "u", "settings", None);
    let unsupported = reply(&mut client, "u");
    assert_eq!(unsupported["kind"], "error");
    assert_eq!(unsupported["error"]["code"], "unsupported");
    request(
        &mut client,
        "x",
        "hello",
        Some(json!({"deviceID":device,"token":token,"appVersion":"1"})),
    );
    assert_eq!(
        reply(&mut client, "x")["error"]["message"],
        "Already authenticated."
    );

    // Revoking tells the phone and hangs up.
    fixture.server.revoke(&device);
    let revoked = event_of(&mut client, "revoked");
    assert!(revoked.get("body").is_none());
    assert!(next(&mut client).is_none());
    assert!(fixture.server.snapshot().devices.is_empty());
}

#[test]
fn unauthenticated_requests_and_wrong_certificates_are_refused() {
    let mut fixture = fixture();
    fixture.server.set_enabled(true);
    let port = running_port(&fixture.server);
    let fingerprint = fixture.server.snapshot().fingerprint.unwrap();
    // A machine in the middle presenting another certificate fails the pin.
    assert!(connect(port, &"0".repeat(64)).is_err());

    let mut client = connect(port, &fingerprint).unwrap();
    request(&mut client, "1", "workspace", None);
    let refused = reply(&mut client, "1");
    assert_eq!(refused["error"]["code"], "unauthorized");
    assert_eq!(refused["error"]["message"], "Pair this device first.");
    assert!(next(&mut client).is_none());

    let mut client = connect(port, &fingerprint).unwrap();
    request(
        &mut client,
        "2",
        "pair",
        Some(json!({"secret":"guess","deviceName":"x"})),
    );
    let expired = reply(&mut client, "2");
    assert_eq!(expired["error"]["code"], "pairingFailed");
    assert!(next(&mut client).is_none());

    let mut client = connect(port, &fingerprint).unwrap();
    client.send(Message::text("{")).unwrap();
    assert_eq!(next(&mut client).unwrap()["error"]["code"], "badRequest");
    assert!(next(&mut client).is_none());
}

#[test]
fn resetting_the_certificate_forgets_devices_and_changes_the_pin() {
    let mut fixture = fixture();
    fixture.server.set_enabled(true);
    let (client, _, _) = pair(&mut fixture);
    drop(client);
    let before = fixture.server.snapshot().fingerprint.unwrap();
    fixture.server.reset_identity().unwrap();
    let snapshot = fixture.server.snapshot();
    assert!(matches!(snapshot.status, Status::Running { .. }));
    assert_ne!(snapshot.fingerprint.as_deref(), Some(before.as_str()));
    assert!(snapshot.devices.is_empty());
    assert!(connect(running_port(&fixture.server), &before).is_err());
}

#[test]
fn sessions_time_out_without_authenticating() {
    let mut session = Session::new("10.0.0.2");
    session.start_clock(Instant::now() - super::super::session::AUTHENTICATION_TIMEOUT);
    session.check_timeout(Instant::now());
    assert!(session.is_closed());
    let sent = session.take_outgoing();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0]["error"]["message"], "Authentication timed out.");
    assert!(sent[0].get("re").is_none());
}

#[test]
fn mapped_ipv4_peers_are_judged_as_ipv4() {
    let mapped: IpAddr = "::ffff:192.168.1.4".parse().unwrap();
    assert_eq!(canonical(mapped), "192.168.1.4".parse::<IpAddr>().unwrap());
    assert!(super::super::allowed_peer(canonical(mapped)));
    assert!(!super::super::allowed_peer(canonical(
        "::ffff:8.8.8.8".parse().unwrap()
    )));
    assert!(!Settings::default().is_enabled);
    let settings: Settings =
        serde_json::from_str(r#"{"isEnabled":true,"port":47391,"serverID":"S"}"#).unwrap();
    assert_eq!(settings.port, Some(47391));
    assert_eq!(serde_json::to_value(&settings).unwrap()["serverID"], "S");
}

#[test]
fn stop_interrupts_a_peer_stalled_before_tls_authentication() {
    let mut fixture = fixture();
    fixture.server.set_enabled(true);
    let _peer = TcpStream::connect((Ipv4Addr::LOCALHOST, running_port(&fixture.server))).unwrap();
    let shared = fixture.server.running.as_ref().unwrap().0.clone();
    let deadline = Instant::now() + Duration::from_secs(2);
    while shared.connections.load(Ordering::SeqCst) == 0 {
        assert!(Instant::now() < deadline, "connection was not accepted");
        std::thread::sleep(Duration::from_millis(10));
    }
    let started = Instant::now();
    fixture.server.stop();
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "stop waited for an unauthenticated peer"
    );
    assert_eq!(shared.connections.load(Ordering::SeqCst), 0);
    assert!(shared.sockets.lock().unwrap().is_empty());
}

#[test]
fn authentication_deadline_covers_a_stalled_tls_handshake() {
    let mut fixture = fixture();
    fixture.server.set_enabled(true);
    let mut peer =
        TcpStream::connect((Ipv4Addr::LOCALHOST, running_port(&fixture.server))).unwrap();
    peer.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
    let shared = fixture.server.running.as_ref().unwrap().0.clone();
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let mut sockets = shared.sockets.lock().unwrap();
        if let Some((_, accepted)) = sockets.values_mut().next() {
            *accepted = Instant::now() - super::super::session::AUTHENTICATION_TIMEOUT;
            break;
        }
        drop(sockets);
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    let mut byte = [0];
    use std::io::Read;
    match peer.read(&mut byte) {
        Ok(0) => {}
        Err(error)
            if matches!(
                error.kind(),
                ErrorKind::ConnectionReset | ErrorKind::ConnectionAborted
            ) => {}
        other => panic!("handshake was not closed at its total deadline: {other:?}"),
    }
    fixture.server.stop();
    assert_eq!(shared.connections.load(Ordering::SeqCst), 0);
}

#[test]
fn explicit_reset_recovers_malformed_devices_without_startup_overwrite() {
    use crate::remote::secrets::SecretBackend;
    let mut fixture = fixture();
    fixture
        .secrets
        .write("devices", b"damaged-fixture")
        .unwrap();
    fixture.server.set_enabled(true);
    assert!(matches!(fixture.server.status(), Status::Failed(_)));
    assert_eq!(
        &*fixture.secrets.read("devices").unwrap().unwrap(),
        b"damaged-fixture"
    );
    fixture.server.reset_identity().unwrap();
    assert!(fixture.secrets.read("devices").unwrap().is_none());
    fixture.server.set_enabled(false);
    fixture.server.set_enabled(true);
    assert!(matches!(fixture.server.status(), Status::Running { .. }));
    fixture.server.stop();
}

#[test]
fn interrupted_handshake_resumes_the_same_connection_before_authentication_deadline() {
    let mut fixture = fixture();
    fixture.server.set_enabled(true);
    let payload = fixture.server.begin_pairing().unwrap();
    let stream = TcpStream::connect((Ipv4Addr::LOCALHOST, payload.port)).unwrap();
    // The server has to observe WouldBlock more than once before TLS begins.
    std::thread::sleep(POLL * 3);
    let mut client = connect_stream(payload.port, &payload.fingerprint, stream).unwrap();
    request(
        &mut client,
        "delayed",
        "pair",
        Some(json!({"secret":payload.secret,"deviceName":"Delayed fixture"})),
    );
    let response = reply(&mut client, "delayed");
    assert_eq!(response["kind"], "response");
    assert_eq!(response["type"], "paired");
    assert_eq!(fixture.server.snapshot().devices.len(), 1);
    fixture.server.stop();
}
