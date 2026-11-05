//! Synthetic workflow coverage over the public local control transport on all
//! supported hosts. Never launches a provider, terminal, browser, or native UI.
use coincide_core::{api::Engine, control, message_queue, store::Store};
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
};
use uuid::Uuid;

const PROJECT: &str = "00000000-0000-0000-0000-000000000000";

struct Fixture {
    // Server must stop before its engine/store and temporary files are dropped.
    server: Option<control::Server>,
    engine: Option<Arc<Mutex<Engine>>>,
    socket: PathBuf,
    database: PathBuf,
    _directory: tempfile::TempDir,
}
impl Fixture {
    fn new(seed: impl FnOnce(&mut Store)) -> Self {
        // Keep Unix socket names below Darwin's sockaddr_un limit.
        let base = if cfg!(unix) {
            PathBuf::from("/tmp")
        } else {
            std::env::temp_dir()
        };
        let directory = tempfile::Builder::new()
            .prefix("cw-")
            .tempdir_in(base)
            .unwrap();
        let data = directory.path().join("data");
        let database = data.join("state.sqlite");
        let mut store = Store::open(&database).unwrap();
        seed(&mut store);
        drop(store);
        let mut fixture = Self {
            server: None,
            engine: None,
            socket: data.join("control.sock"),
            database,
            _directory: directory,
        };
        fixture.start();
        fixture
    }
    fn start(&mut self) {
        let engine = Arc::new(Mutex::new(Engine::new(
            Store::open(&self.database).unwrap(),
        )));
        self.server = Some(control::serve(self.socket.clone(), engine.clone()).unwrap());
        self.engine = Some(engine);
    }
    fn restart(&mut self) {
        self.server.take();
        self.engine.take();
        self.start();
    }
    fn request(&self, method: &str, params: Value) -> Value {
        let id = Uuid::new_v4().to_string();
        let reply = control::request(
            &self.socket,
            &json!({"id":id,"method":method,"params":params}),
        )
        .unwrap();
        assert_eq!(reply["id"], id, "response/request correlation lost");
        reply
    }
    fn call(&self, method: &str, params: Value) -> Value {
        let reply = self.request(method, params);
        assert!(reply.get("error").is_none(), "{method}: {reply}");
        reply["result"].clone()
    }
    fn reject(&self, method: &str, params: Value) {
        let reply = self.request(method, params);
        assert!(reply["error"]["message"].is_string(), "{method}: {reply}");
    }
    fn read(&self, id: &str) -> Value {
        self.call("threads.read", json!({"threadId":id}))
    }
}

#[test]
fn control_history_pagination_fork_and_edit_preserve_source_across_restart() {
    let mut source = Value::Null;
    let user = Uuid::new_v4().to_string();
    let answer = Uuid::new_v4().to_string();
    let second = Uuid::new_v4().to_string();
    let mut fixture = Fixture::new(|store| {
        source = store.new_thread(PROJECT).unwrap();
        source["title"] = json!("Synthetic 界 history");
        source["draft"] = json!("Unsent source draft");
        source["sessions"] = json!({"claude":{"sessionID":"synthetic-never-resume"}});
        source["items"] = json!([
            {"id":user,"kind":"user","text":"First 🦀 request"},
            {"id":answer,"kind":"assistant","text":"First answer","userItemID":user},
            {"id":second,"kind":"user","text":"Edit this\nsecond request","context":[{"kind":"quote","text":"retained"}]}
        ]);
        store.save(&source).unwrap();
    });
    let id = source["id"].as_str().unwrap();
    let capabilities = fixture.call("app.capabilities", json!({}));
    for method in ["threads.read", "threads.fork", "threads.edit-branch"] {
        assert!(capabilities.as_array().unwrap().contains(&json!(method)));
    }
    let page = fixture.call(
        "threads.read",
        json!({"threadId":id,"itemLimit":1,"itemOffset":1}),
    );
    assert_eq!(page["page"], json!({"offset":1,"total":3}));
    assert_eq!(page["items"], json!([source["items"][1]]));
    fixture.reject("threads.read", json!({"threadId":id,"itemLimit":1001}));
    fixture.reject(
        "threads.edit-branch",
        json!({"threadId":id,"itemId":answer}),
    );
    fixture.reject(
        "threads.fork",
        json!({"threadId":id,"itemId":Uuid::new_v4()}),
    );
    assert_eq!(
        fixture
            .call("threads.list", json!({}))
            .as_array()
            .unwrap()
            .len(),
        1
    );

    let fork = fixture.call("threads.fork", json!({"threadId":id,"itemId":answer}));
    let edit = fixture.call(
        "threads.edit-branch",
        json!({"threadId":id,"itemId":second}),
    );
    assert_ne!(fork["id"], edit["id"]);
    for branch in [&fork, &edit] {
        assert_ne!(branch["id"], source["id"]);
        assert_eq!(branch["items"].as_array().unwrap().len(), 2);
        assert_eq!(branch["items"][0]["text"], source["items"][0]["text"]);
        assert_ne!(branch["items"][0]["id"], source["items"][0]["id"]);
        assert_eq!(branch["items"][1]["userItemID"], branch["items"][0]["id"]);
        assert_eq!(branch["sessions"], json!({}));
        assert_eq!(branch["rustMessageQueue"], json!([]));
        assert_eq!(branch["rustHistory"]["parentThreadID"], source["id"]);
        assert_eq!(branch["accessMode"], "approval");
    }
    assert_eq!(fork["draft"], "");
    assert_eq!(edit["draft"], source["items"][2]["text"]);
    assert_eq!(edit["draftContext"], source["items"][2]["context"]);
    assert_eq!(fixture.read(id), source);
    fixture.restart();
    assert_eq!(fixture.read(id), source);
    assert_eq!(fixture.read(fork["id"].as_str().unwrap()), fork);
    assert_eq!(fixture.read(edit["id"].as_str().unwrap()), edit);
    assert_eq!(fixture.call("app.status", json!({}))["running"], json!([]));
}

#[test]
fn control_dormant_queue_removal_and_validation_never_replay_saved_work() {
    let mut source = Value::Null;
    let mut pending = String::new();
    let mut claimed = String::new();
    let mut fixture = Fixture::new(|store| {
        source = store.new_thread(PROJECT).unwrap();
        pending = message_queue::add(&mut source, "Synthetic pending; never execute")
            .unwrap()
            .id;
        claimed = message_queue::add(&mut source, "Synthetic uncertain claim; never replay")
            .unwrap()
            .id;
        let mut messages = message_queue::read(&source).unwrap();
        messages[1].state = message_queue::State::Dispatching;
        message_queue::write(&mut source, &messages).unwrap();
        store.save(&source).unwrap();
    });
    let id = source["id"].as_str().unwrap();
    // Seed directly before the server starts: queue.add/resume would authorize
    // dispatch. This workflow only inspects, pauses, rejects and removes work.
    for _ in 0..2 {
        let queue = fixture.call("agent.queue.list", json!({"threadId":id}));
        assert_eq!(queue["enabled"], false);
        assert_eq!(queue["messages"][0]["state"], "pending");
        assert_eq!(queue["messages"][1]["state"], "dispatching");
        fixture.reject(
            "agent.queue.remove",
            json!({"threadId":id,"messageId":claimed}),
        );
        fixture.reject(
            "agent.queue.remove",
            json!({"threadId":id,"messageId":Uuid::new_v4()}),
        );
        assert_eq!(fixture.read(id), source);
        assert_eq!(fixture.call("app.status", json!({}))["running"], json!([]));
        fixture.restart();
    }
    fixture.call("agent.queue.pause", json!({"threadId":id}));
    let queue = fixture.call(
        "agent.queue.remove",
        json!({"threadId":id,"messageId":pending}),
    );
    assert_eq!(queue["enabled"], false);
    assert_eq!(queue["messages"].as_array().unwrap().len(), 1);
    assert_eq!(queue["messages"][0]["id"], claimed);
    fixture.restart();
    let queue = fixture.call("agent.queue.list", json!({"threadId":id}));
    assert_eq!(queue["enabled"], false);
    assert_eq!(queue["messages"].as_array().unwrap().len(), 1);
    assert_eq!(queue["messages"][0]["state"], "dispatching");
    assert_eq!(fixture.read(id)["items"], json!([]));
    assert_eq!(fixture.call("app.status", json!({}))["running"], json!([]));
}
