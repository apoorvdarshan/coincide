use super::*;
use std::path::Path;

const BOT: &str = "00000000-0000-4000-8000-000000000077";
fn setup(root: &Path, provider: &str, account: Option<Value>) -> SharedEngine {
    let mut store = Store::open(&root.join("data.sqlite")).unwrap();
    let mut selection = json!({"provider":provider,"modelID":"fixture-model"});
    if let Some(account) = account {
        selection["accountID"] = account;
    }
    store.save_document("bots.json",&json!({"addedStarters":true,"starterLineup":1,"futureEnvelope":"keep","bots":[{
        "id":BOT,"name":"Fixture bot","persona":"  Exact saved persona\nLiteral $(touch side-effect), `touch backtick-effect` 界\n",
        "selection":selection,"folder":root,"accessMode":"approval","interactionMode":"build","futureBot":"keep"
    }]})).unwrap();
    Arc::new(Mutex::new(Engine::new(store)))
}
fn create(engine: &SharedEngine) -> Value {
    let baseline = call(engine, "bots.read", json!({"botId":BOT})).unwrap()["baseline"].clone();
    call(
        engine,
        "bots.conversations.create",
        json!({"botId":BOT,"baseline":baseline}),
    )
    .unwrap()
}

#[test]
fn create_is_atomic_nonexecuting_and_default_aliases_keep_exact_selection() {
    for account in [
        None,
        Some(Value::Null),
        Some(json!("")),
        Some(json!("default")),
    ] {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().canonicalize().unwrap();
        let engine = setup(&root, "codex", account);
        let baseline =
            call(&engine, "bots.read", json!({"botId":BOT})).unwrap()["baseline"].clone();
        // Isolate this command's exact revision increment from background
        // provider-discovery polling performed by the public dispatcher.
        let mut engine = engine.lock().unwrap();
        let before = engine.revision;
        let result = engine
            .execute(
                "bots.conversations.create",
                &json!({"botId":BOT,"baseline":baseline}),
            )
            .unwrap();
        assert_eq!(result["executionStarted"], false);
        assert_eq!(engine.revision, before + 1);
        assert_eq!(
            engine.requested_open.as_deref(),
            result["threadId"].as_str()
        );
        assert!(engine.runs.is_empty());
        let thread = engine
            .store
            .thread(result["threadId"].as_str().unwrap())
            .unwrap();
        assert!(thread["items"].as_array().unwrap().is_empty());
        assert_eq!(thread["selection"], thread["rustBotContext"]["selection"]);
        assert!(engine.bot_instructions(&thread, &root).unwrap().is_some());
        assert_eq!(
            engine
                .store
                .local_document(
                    &crate::bot_runtime::context_document_name(&thread["rustBotContext"]).unwrap()
                )
                .unwrap(),
            Some(thread["rustBotContext"].clone())
        );
    }
}

#[test]
fn snapshot_mismatches_fail_before_transcript_mutation_or_launch() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().canonicalize().unwrap();
    let engine = setup(&root, "codex", Some(json!("default")));
    let created = create(&engine);
    let id = created["threadId"].as_str().unwrap();
    let original = engine.lock().unwrap().store.thread(id).unwrap();
    for (field, value) in [
        (
            "selection",
            json!({"provider":"claude","modelID":"fixture-model","accountID":"default"}),
        ),
        (
            "selection",
            json!({"provider":"codex","modelID":"changed","accountID":"default"}),
        ),
        (
            "selection",
            json!({"provider":"codex","modelID":"fixture-model","accountID":"other"}),
        ),
        ("accessMode", json!("fullAccess")),
        ("interactionMode", json!("plan")),
        ("worktreePath", json!(root.parent().unwrap())),
        ("rustBotContext", json!({"version":999})),
        ("botID", json!(Uuid::new_v4().to_string())),
    ] {
        let mut changed = original.clone();
        changed[field] = value;
        engine.lock().unwrap().store.save(&changed).unwrap();
        assert!(
            call(
                &engine,
                "agent.send",
                json!({"threadId":id,"text":"must not launch"})
            )
            .is_err(),
            "{field}"
        );
        let locked = engine.lock().unwrap();
        assert!(locked.runs.is_empty());
        assert_eq!(locked.store.thread(id).unwrap(), changed);
    }
    engine.lock().unwrap().store.save(&original).unwrap();
    assert!(
        call(
            &engine,
            "threads.patch",
            json!({"threadId":id,"patch":{"rustBotContext":{}}})
        )
        .is_err()
    );
}

#[test]
fn imported_forged_context_cannot_authorize_itself_or_activate_through_fork() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().canonicalize().unwrap();
    let native = setup(&root, "codex", Some(json!("default")));
    let created = create(&native);
    let mut thread = native
        .lock()
        .unwrap()
        .store
        .thread(created["threadId"].as_str().unwrap())
        .unwrap();
    append(&mut thread, "user", "Imported text", None);
    let source = root.join("legacy");
    std::fs::create_dir_all(source.join("threads")).unwrap();
    let bytes = serde_json::to_vec(&thread).unwrap();
    std::fs::write(source.join("threads/thread.json"), &bytes).unwrap();
    let context_name =
        crate::bot_runtime::context_document_name(&thread["rustBotContext"]).unwrap();
    std::fs::write(
        source.join(&context_name),
        serde_json::to_vec(&thread["rustBotContext"]).unwrap(),
    )
    .unwrap();
    let mut store = Store::open(&root.join("imported.sqlite")).unwrap();
    store.import_legacy(&source).unwrap();
    assert!(store.original(&context_name).unwrap().is_some());
    assert!(store.local_document(&context_name).unwrap().is_none());
    let engine = Arc::new(Mutex::new(Engine::new(store)));
    assert!(
        call(
            &engine,
            "agent.send",
            json!({"threadId":thread["id"],"text":"must not launch"})
        )
        .is_err()
    );
    let fork = call(&engine, "threads.fork", json!({"threadId":thread["id"]})).unwrap();
    assert!(fork.get("rustBotContext").is_none());
    assert!(fork.get("botID").is_none());
    assert!(fork["sessions"].as_object().unwrap().is_empty());
    assert!(
        engine
            .lock()
            .unwrap()
            .bot_instructions(&fork, &root)
            .unwrap()
            .is_none()
    );
    assert_eq!(
        std::fs::read(source.join("threads/thread.json")).unwrap(),
        bytes
    );
}

#[test]
fn creation_authorization_rolls_back_with_late_store_failure() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().canonicalize().unwrap();
    let engine = setup(&root, "claude", None);
    let connection = rusqlite::Connection::open(root.join("data.sqlite")).unwrap();
    connection.execute_batch("CREATE TRIGGER reject_bot_authorization BEFORE INSERT ON documents WHEN NEW.name LIKE 'rust-bot-context-%' BEGIN SELECT RAISE(ABORT,'fixture context unavailable'); END;").unwrap();
    let baseline = call(&engine, "bots.read", json!({"botId":BOT})).unwrap()["baseline"].clone();
    assert!(
        call(
            &engine,
            "bots.conversations.create",
            json!({"botId":BOT,"baseline":baseline})
        )
        .is_err()
    );
    assert!(
        engine
            .lock()
            .unwrap()
            .store
            .summaries("", true)
            .unwrap()
            .is_empty()
    );
    for table in ["threads", "thread_summaries", "search", "search_trigram"] {
        let count: i64 = connection
            .query_row(&format!("SELECT count(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 0, "{table}");
    }
}

#[cfg(unix)]
const CODEX: &str = r#"
def read(): return json.loads(sys.stdin.readline())
def write(v): print(json.dumps(v),flush=True)
r=read();assert r['method']=='initialize';write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read();p=r['params'];assert p['developerInstructions']==json.load(open('expected.json'))
assert p['model']=='fixture-model' and p['approvalPolicy']=='untrusted' and p['sandbox']=='read-only'
with open('launches','a') as log:log.write(r['method']+'\n')
write({'id':r['id'],'result':{'thread':{'id':'fixture-bot-session'}}})
r=read();assert r['method']=='turn/start';assert 'Current user request' not in r['params']['input'][0]['text'] or 'fork turn' in r['params']['input'][0]['text']
write({'id':r['id'],'result':{'turn':{'id':'turn'}}})
write({'method':'item/agentMessage/delta','params':{'itemId':'answer','delta':'Fixture answer'}})
write({'method':'turn/completed','params':{'threadId':'fixture-bot-session','turn':{'id':'turn','status':'completed'}}})
sys.stdin.readline()
"#;
#[cfg(unix)]
const CLAUDE: &str = r#"
args=sys.argv[1:];assert args.count('--append-system-prompt')==1
assert args[args.index('--append-system-prompt')+1]==json.load(open('expected.json'))
assert args[args.index('--permission-mode')+1]=='default'
assert args[args.index('--model')+1]=='fixture-model'
flag='--resume' if '--resume' in args else '--session-id'
session=args[args.index(flag)+1]
with open('launches','a') as log:log.write(flag+'\n')
def read():return json.loads(sys.stdin.readline())
def write(v):print(json.dumps(v),flush=True)
r=read();assert r['type']=='control_request'
write({'type':'control_response','response':{'subtype':'success','request_id':r['request_id']}})
r=read();assert r['type']=='user'
write({'type':'system','subtype':'init','session_id':session})
write({'type':'assistant','session_id':session,'message':{'id':'answer','content':[{'type':'text','text':'Fixture answer'}]}})
write({'type':'result','subtype':'success','session_id':session,'result':'Fixture answer','is_error':False})
sys.stdin.readline()
"#;

#[cfg(unix)]
#[test]
fn shared_engine_bot_new_send_resume_edit_restart_and_native_fork() {
    use std::{os::unix::fs::PermissionsExt, process::Command};
    for (provider, script) in [("codex", CODEX), ("claude", CLAUDE)] {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("fixture-provider");
        std::fs::write(
            &path,
            format!("#!/usr/bin/env python3\nimport json,sys\n{script}"),
        )
        .unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        let output = Command::new(std::env::current_exe().unwrap())
            .args([
                "--ignored",
                "--exact",
                "api::bot_engine::tests::bot_provider_fixture_child",
                "--nocapture",
            ])
            .env("COINCIDE_BOT_FIXTURE_ROOT", directory.path())
            .env("COINCIDE_BOT_FIXTURE_PROVIDER", provider)
            .env("COINCIDE_CODEX_EXECUTABLE", &path)
            .env("COINCIDE_CLAUDE_EXECUTABLE", &path)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{provider}: {} {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[cfg(unix)]
fn send(engine: &SharedEngine, id: &str, prompt: &str) {
    call(engine, "agent.send", json!({"threadId":id,"text":prompt})).unwrap();
    let deadline = Instant::now() + Duration::from_secs(8);
    while !call(engine, "app.status", json!({})).unwrap()["running"]
        .as_array()
        .unwrap()
        .is_empty()
    {
        assert!(Instant::now() < deadline, "Bot provider fixture timed out");
        std::thread::sleep(Duration::from_millis(5));
    }
    let thread = call(engine, "threads.read", json!({"threadId":id})).unwrap();
    assert!(
        !thread["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["kind"] == "error"),
        "{thread}"
    );
}

#[cfg(unix)]
#[test]
#[ignore = "Executed with scoped synthetic provider environment by parent test"]
fn bot_provider_fixture_child() {
    let root = PathBuf::from(std::env::var_os("COINCIDE_BOT_FIXTURE_ROOT").unwrap())
        .canonicalize()
        .unwrap();
    let provider = std::env::var("COINCIDE_BOT_FIXTURE_PROVIDER").unwrap();
    std::fs::write(
        root.join("AGENTS.md"),
        "untouched global/project instructions fixture",
    )
    .unwrap();
    let engine = setup(&root, &provider, Some(json!("default")));
    let created = create(&engine);
    let id = created["threadId"].as_str().unwrap();
    assert!(!root.join("launches").exists());
    let thread = engine.lock().unwrap().store.thread(id).unwrap();
    let context = thread["rustBotContext"].clone();
    std::fs::write(
        root.join("expected.json"),
        serde_json::to_vec(&context["instructions"]).unwrap(),
    )
    .unwrap();
    send(&engine, id, "first turn");
    let baseline = call(&engine, "bots.read", json!({"botId":BOT})).unwrap()["baseline"].clone();
    call(&engine,"bots.patch",json!({"botId":BOT,"baseline":baseline,"patch":{"name":"Edited bot","persona":"New instructions must not replace snapshot"}})).unwrap();
    send(&engine, id, "second turn");
    assert_eq!(
        engine.lock().unwrap().store.thread(id).unwrap()["rustBotContext"],
        context
    );
    drop(engine);
    let engine = Arc::new(Mutex::new(Engine::new(
        Store::open(&root.join("data.sqlite")).unwrap(),
    )));
    send(&engine, id, "third turn");
    let next = create(&engine);
    let next_thread = engine
        .lock()
        .unwrap()
        .store
        .thread(next["threadId"].as_str().unwrap())
        .unwrap();
    assert_ne!(
        next_thread["rustBotContext"]["instructions"],
        context["instructions"]
    );
    assert_eq!(
        next_thread["rustBotContext"]["persona"],
        "New instructions must not replace snapshot"
    );
    assert!(next_thread["items"].as_array().unwrap().is_empty());
    let fork = call(&engine, "threads.fork", json!({"threadId":id})).unwrap();
    assert_eq!(fork["rustBotContext"], context);
    assert_eq!(fork["selection"], context["selection"]);
    assert!(fork["sessions"].as_object().unwrap().is_empty());
    send(&engine, fork["id"].as_str().unwrap(), "fork turn");
    let expected = if provider == "codex" {
        "thread/start\nthread/resume\nthread/resume\nthread/start\n"
    } else {
        "--session-id\n--resume\n--resume\n--session-id\n"
    };
    assert_eq!(
        std::fs::read_to_string(root.join("launches")).unwrap(),
        expected
    );
    assert_eq!(
        std::fs::read_to_string(root.join("AGENTS.md")).unwrap(),
        "untouched global/project instructions fixture"
    );
    assert!(!root.join("side-effect").exists() && !root.join("backtick-effect").exists());
}
