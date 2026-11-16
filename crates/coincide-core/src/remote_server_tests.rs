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
use uuid::Uuid;

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
fn live_alerts_reach_only_the_active_paired_phone_and_respect_preview_setting() {
    use crate::platform_host::notifications::{Alert, AlertKind, Delivery, EventKey};
    let mut fixture = fixture();
    fixture.server.set_enabled(true);
    let handle = fixture.server.alert_handle();
    let (mut phone, device, _) = pair(&mut fixture);
    handle.set_enabled(true);
    let server = event_of(&mut phone, "server");
    assert_eq!(server["body"]["notifies"], true);
    request(
        &mut phone,
        "presence",
        "presence",
        Some(json!({
            "state":"active", "idleSeconds":2
        })),
    );
    assert_eq!(reply(&mut phone, "presence")["type"], "ok");
    let now = (crate::remote::pairing::now_ms() / 1000.) as u64;
    let presence = handle.presences();
    assert!(
        presence
            .iter()
            .any(|row| row.device_id == device && row.foreground(now, 75))
    );
    let shared = fixture.server.running.as_ref().unwrap().0.clone();
    let session = shared
        .sessions
        .lock()
        .unwrap()
        .values()
        .next()
        .unwrap()
        .clone();
    let busy = session.lock().unwrap();
    assert!(handle.presences().iter().any(|row| row.device_id == device));
    drop(busy);
    let alert = Alert {
        key: EventKey {
            thread: Uuid::parse_str(&fixture.thread).unwrap(),
            item: Uuid::new_v4(),
            kind: AlertKind::Completed,
        },
        title: "Private title".into(),
        body: Some("Private reply".into()),
    };
    assert_eq!(
        handle.deliver("not-paired", &alert, true, now),
        Delivery::Unavailable
    );
    assert_eq!(
        handle.deliver(&device, &alert, false, now),
        Delivery::Accepted
    );
    let event = event_of(&mut phone, "notify");
    assert_eq!(event["body"]["threadID"], fixture.thread.to_lowercase());
    assert_eq!(event["body"]["title"], "Coincide");
    assert!(event["body"]["body"].is_null());
    assert!(!event.to_string().contains("Private"));

    assert_eq!(
        handle.deliver(&device, &alert, true, now),
        Delivery::Accepted
    );
    let preview = event_of(&mut phone, "notify");
    assert_eq!(preview["body"]["title"], "Private title");
    assert_eq!(preview["body"]["body"], "Private reply");
    handle.set_enabled(false);
    assert_eq!(
        handle.deliver(&device, &alert, true, now),
        Delivery::Unavailable
    );
    handle.set_enabled(true);
    request(
        &mut phone,
        "background",
        "presence",
        Some(json!({
            "state":"background", "idleSeconds":2
        })),
    );
    assert_eq!(reply(&mut phone, "background")["type"], "ok");
    assert_eq!(
        handle.deliver(&device, &alert, false, now),
        Delivery::Unavailable
    );
    request(
        &mut phone,
        "foreground",
        "presence",
        Some(json!({"state":"active","idleSeconds":0})),
    );
    assert_eq!(reply(&mut phone, "foreground")["type"], "ok");
    fixture.server.revoke(&device);
    assert!(
        !fixture
            .server
            .snapshot()
            .devices
            .iter()
            .any(|row| row.id == device)
    );
    assert_eq!(
        handle.deliver(&device, &alert, true, now),
        Delivery::Unavailable
    );
    fixture.server.set_enabled(false);
    assert!(handle.presences().is_empty());
    assert_eq!(
        handle.deliver(&device, &alert, false, now),
        Delivery::Unavailable
    );
}

#[test]
fn paired_devices_sync_project_disclosure_without_changing_special_groups() {
    let mut fixture = fixture();
    let (project_id, chats_id, bots_id) = {
        let mut engine = fixture.engine.lock().unwrap();
        let mut projects = engine.store.projects().unwrap();
        let project = projects[0]["id"].as_str().unwrap().to_owned();
        let chats = Uuid::new_v4().to_string().to_uppercase();
        let bots = Uuid::new_v4().to_string().to_uppercase();
        projects.as_array_mut().unwrap().push(json!({
            "id":chats,"name":"Chats","isChats":true,"isExpanded":true
        }));
        projects.as_array_mut().unwrap().push(json!({
            "id":bots,"name":"Bots","isBots":true,"isExpanded":true
        }));
        engine
            .store
            .save_document("projects.json", &projects)
            .unwrap();
        (project, chats, bots)
    };
    fixture.server.set_enabled(true);
    let (mut phone, _, _) = pair(&mut fixture);
    let (mut tablet, _, _) = pair(&mut fixture);
    let mut stranger = connect(
        running_port(&fixture.server),
        &fixture.server.snapshot().fingerprint.unwrap(),
    )
    .unwrap();
    request(
        &mut stranger,
        "unauthorized",
        "setProjectExpanded",
        Some(json!({
            "projectID":project_id,"expanded":false
        })),
    );
    assert_eq!(
        reply(&mut stranger, "unauthorized")["error"]["code"],
        "unauthorized"
    );

    let shared = fixture.server.running.as_ref().unwrap().0.clone();
    let gate = shared.watch_gate.lock().unwrap();
    request(&mut tablet, "workspace", "workspace", None);
    let original = reply(&mut tablet, "workspace");
    assert_eq!(original["kind"], "response", "{original}");
    assert_eq!(original["body"]["projects"][0]["isExpanded"], true);
    let codex = original["body"]["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == "codex")
        .unwrap();
    assert_eq!(codex["state"], "unknown");
    assert_eq!(codex["models"][0]["id"], "default");

    request(
        &mut phone,
        "malformed",
        "setProjectExpanded",
        Some(json!({
            "projectID":project_id,"expanded":"false"
        })),
    );
    assert_eq!(
        reply(&mut phone, "malformed")["error"]["code"],
        "badRequest"
    );
    for id in [&chats_id, &bots_id] {
        request(
            &mut phone,
            "special",
            "setProjectExpanded",
            Some(json!({
                "projectID":id,"expanded":false
            })),
        );
        assert_eq!(reply(&mut phone, "special")["error"]["code"], "notFound");
    }
    request(
        &mut phone,
        "collapse",
        "setProjectExpanded",
        Some(json!({
            "projectID":project_id,"expanded":false
        })),
    );
    let response = reply(&mut phone, "collapse");
    assert_eq!(response["type"], "ok", "{response}");
    {
        let engine = fixture.engine.lock().unwrap();
        let saved = engine.store.projects().unwrap();
        assert_eq!(saved[0]["isExpanded"], false);
        assert_eq!(saved[0]["name"], "Fixture");
        assert_eq!(saved[1]["isExpanded"], true);
        assert_eq!(saved[2]["isExpanded"], true);
    }
    drop(gate);
    let update = event_of(&mut tablet, "workspace");
    assert_eq!(update["body"]["projects"][0]["isExpanded"], false);
}

#[test]
fn phone_composer_settings_validate_before_changing_the_exact_thread() {
    let mut fixture = fixture();
    {
        let mut engine = fixture.engine.lock().unwrap();
        let mut thread = engine.store.thread(&fixture.thread).unwrap();
        thread["draft"] = json!("Desktop draft stays here");
        thread["items"] =
            json!([{"id":Uuid::new_v4(),"kind":"user","text":"Earlier message","createdAt":1.0}]);
        engine.store.save(&thread).unwrap();
    }
    fixture.server.set_enabled(true);
    let (mut phone, _, _) = pair(&mut fixture);
    let shared = fixture.server.running.as_ref().unwrap().0.clone();
    let _gate = shared.watch_gate.lock().unwrap();
    request(
        &mut phone,
        "invalid",
        "updateSettings",
        Some(json!({
            "threadID":fixture.thread,"accessMode":"invalid"
        })),
    );
    let rejected = reply(&mut phone, "invalid");
    assert_eq!(rejected["kind"], "error", "{rejected}");
    {
        let engine = fixture.engine.lock().unwrap();
        let thread = engine.store.thread(&fixture.thread).unwrap();
        assert_ne!(thread["accessMode"], "invalid");
        assert_eq!(thread["draft"], "Desktop draft stays here");
    }
    request(
        &mut phone,
        "update",
        "updateSettings",
        Some(json!({
            "threadID":fixture.thread,"accessMode":"fullAccess"
        })),
    );
    let response = reply(&mut phone, "update");
    assert_eq!(response["type"], "ok", "{response}");
    let engine = fixture.engine.lock().unwrap();
    let thread = engine.store.thread(&fixture.thread).unwrap();
    assert_eq!(thread["accessMode"], "fullAccess");
    assert_eq!(thread["draft"], "Desktop draft stays here");
    assert_eq!(thread["items"][0]["text"], "Earlier message");
}

#[test]
fn seen_on_phone_clears_only_its_thread_and_reaches_other_devices() {
    let mut fixture = fixture();
    let other = Uuid::new_v4().to_string().to_uppercase();
    let thread = Uuid::parse_str(&fixture.thread).unwrap();
    {
        let mut engine = fixture.engine.lock().unwrap();
        engine
            .store
            .save_document(
                "ui-state.json",
                &json!({
                    "unseen": {(fixture.thread.to_lowercase()): "failed", (&other): "completed"},
                    "futurePreference": {"keep": true}
                }),
            )
            .unwrap();
    }
    fixture.server.set_enabled(true);
    let (mut phone, _, _) = pair(&mut fixture);
    let (mut tablet, _, _) = pair(&mut fixture);
    // The watcher deliberately polls Engine in parallel in production. Hold
    // its fixture gate here so this success case cannot race that short poll;
    // the separately locked Engine below still verifies the busy response.
    let shared = fixture.server.running.as_ref().unwrap().0.clone();
    let _watch_gate = shared.watch_gate.lock().unwrap();
    request(&mut phone, "workspace", "workspace", None);
    let before = reply(&mut phone, "workspace");
    let listed = before["body"]["threads"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["id"] == fixture.thread)
        .unwrap();
    assert_eq!(listed["unseen"], "failed");

    request(
        &mut phone,
        "seen",
        "markSeen",
        Some(json!({"threadID":fixture.thread})),
    );
    assert_eq!(reply(&mut phone, "seen")["type"], "ok");
    let event = event_of(&mut tablet, "clearNotifications");
    assert_eq!(event["body"]["value"], fixture.thread);
    let saved = fixture
        .engine
        .lock()
        .unwrap()
        .store
        .document("ui-state.json")
        .unwrap()
        .unwrap();
    assert!(saved["unseen"].get(fixture.thread.to_lowercase()).is_none());
    assert_eq!(saved["unseen"][&other], "completed");
    assert_eq!(saved["futurePreference"]["keep"], true);
    let pending = fixture.server.pending_seen();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].0, thread);

    // A later clear for the same thread cannot be lost to an older ack.
    fixture.server.seen.record(thread, true);
    fixture.server.acknowledge_seen(thread, pending[0].1);
    assert_eq!(fixture.server.pending_seen().len(), 1);
    let newer = fixture.server.pending_seen()[0];
    fixture.server.acknowledge_seen(newer.0, newer.1);
    assert!(fixture.server.pending_seen().is_empty());

    // A busy engine must return an error instead of claiming the seen action
    // was applied, and must not enqueue a clear.
    let guard = fixture.engine.lock().unwrap();
    request(
        &mut phone,
        "busy",
        "markSeen",
        Some(json!({"threadID":fixture.thread})),
    );
    assert_eq!(reply(&mut phone, "busy")["kind"], "error");
    assert!(fixture.server.pending_seen().is_empty());
    drop(guard);

    request(
        &mut phone,
        "missing",
        "markSeen",
        Some(json!({"threadID":Uuid::new_v4()})),
    );
    assert_eq!(reply(&mut phone, "missing")["kind"], "error");
    assert!(fixture.server.pending_seen().is_empty());
}

#[test]
fn active_phone_presence_marks_its_thread_seen() {
    let mut fixture = fixture();
    {
        let mut engine = fixture.engine.lock().unwrap();
        engine
            .store
            .save_document(
                "ui-state.json",
                &json!({"unseen": {(&fixture.thread): "completed"}}),
            )
            .unwrap();
    }
    fixture.server.set_enabled(true);
    let (mut phone, _, _) = pair(&mut fixture);
    let (mut tablet, _, _) = pair(&mut fixture);
    // Presence must be retried when the desktop is briefly saving.
    let guard = fixture.engine.lock().unwrap();
    request(
        &mut phone,
        "presence",
        "presence",
        Some(json!({"state":"active", "openThreadID":fixture.thread})),
    );
    assert_eq!(reply(&mut phone, "presence")["type"], "ok");
    assert!(fixture.server.pending_seen().is_empty());
    drop(guard);
    assert_eq!(
        event_of(&mut tablet, "clearNotifications")["body"]["value"],
        fixture.thread
    );
    let saved = fixture
        .engine
        .lock()
        .unwrap()
        .store
        .document("ui-state.json")
        .unwrap()
        .unwrap();
    assert!(saved["unseen"].get(&fixture.thread).is_none());
    assert_eq!(fixture.server.pending_seen().len(), 1);
}

#[test]
fn selecting_on_mac_notifies_all_connected_phones() {
    let mut fixture = fixture();
    fixture.server.set_enabled(true);
    let (mut phone, _, _) = pair(&mut fixture);
    let (mut tablet, _, _) = pair(&mut fixture);
    fixture
        .server
        .desktop_seen(Uuid::parse_str(&fixture.thread).unwrap());
    assert_eq!(
        event_of(&mut phone, "clearNotifications")["body"]["value"],
        fixture.thread
    );
    assert_eq!(
        event_of(&mut tablet, "clearNotifications")["body"]["value"],
        fixture.thread
    );
    assert!(fixture.server.pending_seen().is_empty());
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
    let fingerprint = fixture.server.snapshot().fingerprint.unwrap();
    let saved = Settings::load(&fixture.server.directory);
    assert!(saved.is_enabled);
    assert_eq!(saved.port, Some(port));
    assert_eq!(saved.server_id, "FIXTURE-SERVER");
    fixture.server.set_enabled(false);
    assert_eq!(fixture.server.status(), &Status::Off);
    // Another parallel fixture may reuse the just-released ephemeral port.
    // What matters is that this server can no longer accept its pinned TLS
    // connection, not whether an unrelated listener owns that port now.
    assert!(connect(port, &fingerprint).is_err());
}

#[test]
fn authenticated_phone_receives_only_enabled_reported_provider_windows() {
    use super::super::protocol::{RemoteUsage, RemoteUsageWindow};
    let mut fixture = fixture();
    call(
        &fixture.engine,
        "settings.patch",
        json!({"patch":{"providers":{
            "claude":{"isEnabled":true}, "codex":{"isEnabled":true},
            "cursor":{"isEnabled":true}, "grok":{"isEnabled":true},
            "opencode":{"isEnabled":true}, "antigravity":{"isEnabled":true}
        }}}),
    )
    .unwrap();
    fixture.server.set_usage(
        [
            "claude",
            "codex",
            "cursor",
            "grok",
            "opencode",
            "antigravity",
            "unknown",
        ]
        .iter()
        .map(|provider| RemoteUsage {
            provider: (*provider).into(),
            provider_name: (*provider).into(),
            account_id: "default".into(),
            account_name: None,
            windows: vec![RemoteUsageWindow {
                id: "weekly".into(),
                label: "Weekly".into(),
                used_percent: 37.5,
                resets_at: Some(1_750_100_000_000),
            }],
            checked_at: Some(1_750_000_000_000),
        })
        .collect(),
    );
    fixture.server.set_enabled(true);
    let (mut phone, _, _) = pair(&mut fixture);
    // This success case must not race the watcher's independent Engine poll.
    // Other fixtures explicitly exercise the busy response.
    let shared = fixture.server.running.as_ref().unwrap().0.clone();
    let _watch_gate = shared.watch_gate.lock().unwrap();
    request(&mut phone, "usage-all", "usageLimits", None);
    let first = reply(&mut phone, "usage-all");
    assert_eq!(first["type"], "usage");
    let rows = first["body"]["value"].as_array().unwrap();
    assert_eq!(rows.len(), 6);
    assert_eq!(rows[0]["accountID"], "default");
    assert_eq!(rows[0]["windows"][0]["usedPercent"], 37.5);
    assert_eq!(rows[0]["windows"][0]["resetsAt"], 1_750_100_000_000_i64);
    call(
        &fixture.engine,
        "settings.patch",
        json!({"patch":{"providers":{"grok":{"isEnabled":false}}}}),
    )
    .unwrap();
    request(&mut phone, "usage-updated", "usageLimits", None);
    let next = reply(&mut phone, "usage-updated");
    let rows = next["body"]["value"].as_array().unwrap();
    assert_eq!(rows.len(), 5);
    assert!(rows.iter().all(|row| row["provider"] != "grok"));
}

#[test]
fn authenticated_phone_can_preview_only_the_image_referenced_by_its_item() {
    use base64::Engine as _;
    let mut fixture = fixture();
    let item = Uuid::new_v4();
    let mut png = std::io::Cursor::new(Vec::new());
    image::DynamicImage::new_rgba8(800, 400)
        .write_to(&mut png, image::ImageFormat::Png)
        .unwrap();
    {
        let mut engine = fixture.engine.lock().unwrap();
        let root = engine.store.data_directory().unwrap();
        let image =
            crate::attachments::ingest_image_bytes(&root, &png.into_inner(), "photo.png").unwrap();
        let mut thread = engine.store.thread(&fixture.thread).unwrap();
        thread["items"] = json!([{"id":item,"kind":"user","text":"photo","rustImages":[image]}]);
        engine.store.save(&thread).unwrap();
    }
    fixture.server.set_enabled(true);
    let (mut phone, _, _) = pair(&mut fixture);
    let shared = fixture.server.running.as_ref().unwrap().0.clone();
    let _watch_gate = shared.watch_gate.lock().unwrap();
    request(
        &mut phone,
        "open-photo",
        "openThread",
        Some(json!({"threadID":fixture.thread})),
    );
    let opened = reply(&mut phone, "open-photo");
    assert_eq!(opened["body"]["items"][0]["media"][0]["label"], "photo.png");
    request(
        &mut phone,
        "thumbnail",
        "media",
        Some(json!({"threadID":fixture.thread,"itemID":item,"index":0})),
    );
    let thumbnail = reply(&mut phone, "thumbnail");
    assert_eq!(thumbnail["type"], "media");
    assert_eq!(thumbnail["body"]["width"], 480);
    assert_eq!(thumbnail["body"]["height"], 240);
    assert_eq!(thumbnail["body"]["isFull"], false);
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(thumbnail["body"]["data"].as_str().unwrap())
        .unwrap();
    assert!(image::load_from_memory(&bytes).is_ok());
    request(
        &mut phone,
        "wrong-item",
        "media",
        Some(json!({"threadID":fixture.thread,"itemID":Uuid::new_v4(),"index":0})),
    );
    assert_eq!(reply(&mut phone, "wrong-item")["kind"], "error");
}

#[test]
fn phone_unread_and_settle_update_sidebar_without_overwriting_other_markers() {
    let mut fixture = fixture();
    let other = Uuid::new_v4().to_string().to_uppercase();
    {
        let mut engine = fixture.engine.lock().unwrap();
        engine
            .store
            .save_document(
                "ui-state.json",
                &json!({
                    "unseen": {(fixture.thread.to_lowercase()): "failed", (&other): "failed"},
                    "settledThreads": {(&other): 42.0}, "future": {"keep": true}
                }),
            )
            .unwrap();
    }
    fixture.server.set_enabled(true);
    let (mut phone, _, _) = pair(&mut fixture);
    let shared = fixture.server.running.as_ref().unwrap().0.clone();
    let _watch_gate = shared.watch_gate.lock().unwrap();
    request(
        &mut phone,
        "unread",
        "threadAction",
        Some(json!({"threadID":fixture.thread,"action":{"action":"markUnread"}})),
    );
    assert_eq!(reply(&mut phone, "unread")["type"], "ok");
    assert_eq!(fixture.server.sidebar_revision(), 1);
    request(
        &mut phone,
        "settle",
        "threadAction",
        Some(json!({"threadID":fixture.thread,"action":{"action":"settle","value":true}})),
    );
    assert_eq!(reply(&mut phone, "settle")["type"], "ok");
    assert_eq!(fixture.server.sidebar_revision(), 2);
    request(&mut phone, "workspace-marked", "workspace", None);
    let workspace = reply(&mut phone, "workspace-marked");
    let row = workspace["body"]["threads"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == fixture.thread)
        .unwrap();
    assert_eq!(row["unseen"], "completed");
    assert_eq!(row["isSettled"], true);
    assert_eq!(row["isHidden"], true);
    let saved = fixture
        .engine
        .lock()
        .unwrap()
        .store
        .document("ui-state.json")
        .unwrap()
        .unwrap();
    assert_eq!(saved["future"]["keep"], true);
    assert_eq!(saved["unseen"][&other], "failed");
    assert_eq!(saved["settledThreads"][&other], 42.0);
    assert!(saved["unseen"].get(fixture.thread.to_lowercase()).is_none());
    // New activity after settling makes the thread visible again.
    {
        let mut engine = fixture.engine.lock().unwrap();
        let mut thread = engine.store.thread(&fixture.thread).unwrap();
        thread["updatedAt"] =
            json!(saved["settledThreads"][&fixture.thread].as_f64().unwrap() + 60.0);
        engine.store.save(&thread).unwrap();
    }
    request(&mut phone, "workspace-new-activity", "workspace", None);
    let active = reply(&mut phone, "workspace-new-activity");
    let row = active["body"]["threads"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == fixture.thread)
        .unwrap();
    assert_eq!(row["isSettled"], false);
    assert_eq!(row["isHidden"], false);
    request(
        &mut phone,
        "unsettle",
        "threadAction",
        Some(json!({"threadID":fixture.thread,"action":{"action":"settle","value":false}})),
    );
    assert_eq!(reply(&mut phone, "unsettle")["type"], "ok");
    request(&mut phone, "workspace-unsettled", "workspace", None);
    let workspace = reply(&mut phone, "workspace-unsettled");
    let row = workspace["body"]["threads"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == fixture.thread)
        .unwrap();
    assert_eq!(row["isSettled"], false);
    assert_eq!(row["isHidden"], false);
    assert_eq!(fixture.server.sidebar_revision(), 3);
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

    // Serialize these success-case requests against the background watcher.
    // The following event checks run only after the watcher is released.
    let shared = fixture.server.running.as_ref().unwrap().0.clone();
    let watch_gate = shared.watch_gate.lock().unwrap();

    // The adapter answers a read while the desktop holds Engine with the
    // documented busy failure instead of waiting; a client retries the read.
    let workspace = {
        let mut message = Value::Null;
        for _ in 0..100 {
            request(
                &mut client,
                "w",
                "workspace",
                Some(json!({"includeArchived":false})),
            );
            message = reply(&mut client, "w");
            if message["kind"] == "response" {
                break;
            }
            assert_eq!(message["kind"], "error", "{message}");
            assert_eq!(message["error"]["code"], "failed", "{message}");
            assert!(
                message["error"]["message"]
                    .as_str()
                    .is_some_and(|text| text.contains("busy")),
                "{message}"
            );
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert_eq!(
            message["kind"], "response",
            "workspace stayed busy: {message}"
        );
        message
    };
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
    drop(watch_gate);
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
