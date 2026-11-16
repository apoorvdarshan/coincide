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
            json!({"provider":"unknown","modelID":"fixture-model","accountID":"default"}),
        ),
        (
            "selection",
            json!({"provider":"codex","modelID":"fixture-model","accountID":"other"}),
        ),
        ("accessMode", json!("unsupported")),
        ("interactionMode", json!("unsupported")),
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
fn existing_bot_authorization_preserves_thread_and_requires_unchanged_sources() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().canonicalize().unwrap();
    let engine = setup(&root, "codex", None);
    let created = create(&engine);
    let id = created["threadId"].as_str().unwrap();
    let mut old = engine.lock().unwrap().store.thread(id).unwrap();
    old.as_object_mut().unwrap().remove("rustBotContext");
    old.as_object_mut().unwrap().remove("worktreePath");
    old["draft"] = json!("Keep this draft");
    old["items"] = json!([{"id":Uuid::new_v4(),"kind":"user","text":"Existing history"}]);
    old["sessions"] = json!({"codex":"existing-provider-session"});
    old["selection"]["effort"] = json!("high");
    old["selection"]["speed"] = json!("fast");
    engine.lock().unwrap().store.save(&old).unwrap();
    let mut e = engine.lock().unwrap();
    let cwd = e.working_directory(&old).unwrap();
    assert_eq!(cwd, root);
    let (baseline, context) = crate::bot_runtime::existing_context(&e.store, &old, &cwd).unwrap();
    let mut changed = old.clone();
    changed["draft"] = json!("newer draft");
    e.store.save(&changed).unwrap();
    assert!(
        e.store
            .authorize_existing_bot_if_unchanged(baseline.as_ref(), &old, &context)
            .is_err()
    );
    assert_eq!(e.store.thread(id).unwrap(), changed);
    e.store.save(&old).unwrap();
    let mut changed_bots = baseline.clone().unwrap();
    changed_bots["bots"][0]["persona"] = json!("Changed while preparing");
    e.store.save_document("bots.json", &changed_bots).unwrap();
    assert!(
        e.store
            .authorize_existing_bot_if_unchanged(baseline.as_ref(), &old, &context)
            .is_err()
    );
    assert_eq!(e.store.thread(id).unwrap(), old);
    e.store
        .save_document("bots.json", baseline.as_ref().unwrap())
        .unwrap();
    let connection = rusqlite::Connection::open(root.join("data.sqlite")).unwrap();
    connection.execute_batch("CREATE TRIGGER reject_existing_bot_context BEFORE INSERT ON documents WHEN NEW.name LIKE 'rust-bot-context-%' BEGIN SELECT RAISE(ABORT,'fixture context unavailable'); END;").unwrap();
    assert!(
        e.store
            .authorize_existing_bot_if_unchanged(baseline.as_ref(), &old, &context)
            .is_err()
    );
    assert_eq!(e.store.thread(id).unwrap(), old);
    connection
        .execute_batch("DROP TRIGGER reject_existing_bot_context")
        .unwrap();
    let updated = e
        .store
        .authorize_existing_bot_if_unchanged(baseline.as_ref(), &old, &context)
        .unwrap();
    let mut expected = old.clone();
    expected["rustBotContext"] = context.clone();
    assert_eq!(updated, expected);
    assert_eq!(e.store.thread(id).unwrap(), expected);
    assert!(e.bot_instructions(&updated, &root).unwrap().is_some());
    assert!(e.bot_validation_view(&updated).unwrap()["botID"].is_null());
    let repaired = e
        .execute(
            "agent.select",
            &json!({"threadId":id,"effort":null,"speed":null}),
        )
        .unwrap();
    assert!(repaired["selection"]["effort"].is_null());
    assert!(repaired["selection"]["speed"].is_null());
    assert_eq!(repaired["id"], old["id"]);
    assert_eq!(repaired["sessions"], old["sessions"]);
    assert_eq!(repaired["items"], old["items"]);
    assert_eq!(repaired["draft"], old["draft"]);
}

#[test]
fn bot_instruction_refresh_preserves_thread_and_requires_both_current_sources() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().canonicalize().unwrap();
    let engine = setup(&root, "codex", None);
    let created = create(&engine);
    let id = created["threadId"].as_str().unwrap();
    let mut original = engine.lock().unwrap().store.thread(id).unwrap();
    original["draft"] = json!("Keep my draft");
    original["items"] = json!([{"kind":"user","text":"Keep my history"}]);
    original["sessions"] = json!({"codex":{"sessionID":"existing-session"}});
    engine.lock().unwrap().store.save(&original).unwrap();
    let baseline = call(&engine, "bots.read", json!({"botId":BOT})).unwrap()["baseline"].clone();
    call(
        &engine,
        "bots.patch",
        json!({"botId":BOT,"baseline":baseline,
        "patch":{"persona":"New instructions","personality":{"preset":"gentle"}}}),
    )
    .unwrap();
    let mut e = engine.lock().unwrap();
    let (source, replacement) =
        crate::bot_runtime::current_context(&e.store, &original, &root).unwrap();
    let mut changed = original.clone();
    changed["draft"] = json!("A newer draft");
    e.store.save(&changed).unwrap();
    assert!(
        e.store
            .authorize_existing_bot_if_unchanged(source.as_ref(), &original, &replacement)
            .is_err()
    );
    assert_eq!(e.store.thread(id).unwrap(), changed);
    e.store.save(&original).unwrap();
    let mut changed_bots = source.clone().unwrap();
    changed_bots["bots"][0]["persona"] = json!("Another edit");
    e.store.save_document("bots.json", &changed_bots).unwrap();
    assert!(
        e.store
            .authorize_existing_bot_if_unchanged(source.as_ref(), &original, &replacement)
            .is_err()
    );
    assert_eq!(e.store.thread(id).unwrap(), original);
    e.store
        .save_document("bots.json", source.as_ref().unwrap())
        .unwrap();
    let old_name = crate::bot_runtime::context_document_name(&original["rustBotContext"]).unwrap();
    let connection = rusqlite::Connection::open(root.join("data.sqlite")).unwrap();
    connection
        .execute("DELETE FROM documents WHERE name=?1", [&old_name])
        .unwrap();
    assert!(
        e.store
            .authorize_existing_bot_if_unchanged(source.as_ref(), &original, &replacement)
            .is_err()
    );
    assert_eq!(e.store.thread(id).unwrap(), original);
    e.store
        .save_document(&old_name, &original["rustBotContext"])
        .unwrap();
    let mut updated = original.clone();
    assert!(e.refresh_bot_instructions(&mut updated).unwrap());
    assert_eq!(updated["id"], original["id"]);
    assert_eq!(updated["items"], original["items"]);
    assert_eq!(updated["sessions"], original["sessions"]);
    assert_eq!(updated["draft"], original["draft"]);
    assert_eq!(updated["selection"], original["selection"]);
    assert_eq!(updated["worktreePath"], original["worktreePath"]);
    assert_eq!(updated["rustBotContext"], replacement);
    assert!(
        updated["rustBotContext"]["instructions"]
            .as_str()
            .unwrap()
            .contains("New instructions")
    );
    assert!(!e.refresh_bot_instructions(&mut updated).unwrap());
}

#[test]
fn authorized_bot_selection_changes_like_a_thread_without_changing_its_identity() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().canonicalize().unwrap();
    let engine = setup(&root, "codex", None);
    let created = create(&engine);
    let id = created["threadId"].as_str().unwrap();
    let original = engine.lock().unwrap().store.thread(id).unwrap();
    let updated = call(&engine, "agent.select", json!({"threadId":id,"provider":"codex", "model":"other-model", "accessMode":"fullAccess", "interactionMode":"plan"})).unwrap();
    assert_eq!(updated["id"], original["id"]);
    assert_eq!(updated["botID"], original["botID"]);
    assert_eq!(updated["rustBotContext"], original["rustBotContext"]);
    assert_eq!(updated["selection"]["modelID"], "other-model");
    assert_eq!(updated["accessMode"], "fullAccess");
    assert_eq!(updated["interactionMode"], "plan");
    assert!(
        engine
            .lock()
            .unwrap()
            .bot_instructions(&updated, &root)
            .unwrap()
            .is_some()
    );
    assert!(
        call(
            &engine,
            "agent.select",
            json!({"threadId":id,"provider":"opencode","model":"default","accountId":"other"})
        )
        .is_err()
    );
    assert_eq!(engine.lock().unwrap().store.thread(id).unwrap(), updated);
    let build = call(&engine, "agent.select", json!({"threadId":id,"provider":"codex","model":"other-model","accessMode":"fullAccess","interactionMode":"build"})).unwrap();
    engine
        .lock()
        .unwrap()
        .set_active_thread(Some(id.into()))
        .unwrap();
    let expected = [
        "id",
        "draft",
        "selection",
        "accessMode",
        "interactionMode",
        "rustDraftImages",
        "draftContext",
    ]
    .into_iter()
    .map(|key| (key.to_owned(), build[key].clone()))
    .collect::<serde_json::Map<_, _>>();
    let switched = call(
        &engine,
        "agent.provider.select",
        json!({"threadId":id,"provider":"claude","expected":expected}),
    )
    .unwrap()["thread"]
        .clone();
    assert_eq!(switched["id"], original["id"]);
    assert_eq!(switched["botID"], original["botID"]);
    assert_eq!(switched["rustBotContext"], original["rustBotContext"]);
    assert_eq!(switched["selection"]["provider"], "claude");
    assert!(
        engine
            .lock()
            .unwrap()
            .bot_instructions(&switched, &root)
            .unwrap()
            .is_some()
    );
    let opencode = call(&engine, "agent.select", json!({"threadId":id,"provider":"opencode","model":"default","accessMode":"approval","interactionMode":"build"})).unwrap();
    assert_eq!(opencode["id"], original["id"]);
    assert_eq!(opencode["botID"], original["botID"]);
    assert_eq!(opencode["rustBotContext"], original["rustBotContext"]);
    let capabilities = call(
        &engine,
        "agent.selection.capabilities",
        json!({"threadId":id}),
    )
    .unwrap();
    assert!(
        capabilities["providers"]
            .as_array()
            .unwrap()
            .iter()
            .any(|provider| provider["provider"] == "opencode")
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
wire=json.load(open('expected-wire.json'))
assert p['model']==wire['model'] and p['approvalPolicy']==wire['approval'] and p['sandbox']==wire['sandbox']
with open('launches','a') as log:log.write(r['method']+'\n')
write({'id':r['id'],'result':{'thread':{'id':'fixture-bot-session'}}})
r=read()
if r['method']=='thread/compact/start':
    write({'id':r['id'],'result':{}})
    write({'method':'turn/started','params':{'threadId':'fixture-bot-session','turn':{'id':'compact-turn'}}})
    write({'method':'item/completed','params':{'threadId':'fixture-bot-session','turnId':'compact-turn','item':{'type':'contextCompaction','id':'item'}}})
    write({'method':'turn/completed','params':{'threadId':'fixture-bot-session','turn':{'id':'compact-turn','status':'completed'}}})
else:
    assert r['method']=='turn/start';assert 'Current user request' not in r['params']['input'][0]['text'] or 'fork turn' in r['params']['input'][0]['text'] or 'continue old conversation' in r['params']['input'][0]['text']
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
    wait_for_bot(engine, id);
}

#[cfg(unix)]
fn wait_for_bot(engine: &SharedEngine, id: &str) {
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
    let mut context = thread["rustBotContext"].clone();
    std::fs::write(
        root.join("expected.json"),
        serde_json::to_vec(&context["instructions"]).unwrap(),
    )
    .unwrap();
    std::fs::write(
        root.join("expected-wire.json"),
        serde_json::to_vec(
            &json!({"model":"fixture-model","approval":"untrusted","sandbox":"read-only"}),
        )
        .unwrap(),
    )
    .unwrap();
    send(&engine, id, "first turn");
    // Older local bots can resume on the same thread, with the current bot's
    // instructions, after the first explicit send authorizes their context.
    let legacy = create(&engine);
    let legacy_id = legacy["threadId"].as_str().unwrap();
    let mut saved = engine.lock().unwrap().store.thread(legacy_id).unwrap();
    saved.as_object_mut().unwrap().remove("rustBotContext");
    saved.as_object_mut().unwrap().remove("worktreePath");
    saved["sessions"] = engine.lock().unwrap().store.thread(id).unwrap()["sessions"].clone();
    append(&mut saved, "user", "old history", None);
    engine.lock().unwrap().store.save(&saved).unwrap();
    let mut stale = saved.clone();
    stale["draft"] = json!("different captured draft");
    {
        let mut e = engine.lock().unwrap();
        let request = json!({"threadId":legacy_id,"text":"continue old conversation"});
        assert!(
            e.send_turn_if_unchanged(&request, &SendOrigin::Ordinary, Some(&stale), false)
                .is_err()
        );
        assert_eq!(e.store.thread(legacy_id).unwrap(), saved);
        e.send_turn_if_unchanged(&request, &SendOrigin::Ordinary, Some(&saved), false)
            .unwrap();
    }
    wait_for_bot(&engine, legacy_id);
    let continued = engine.lock().unwrap().store.thread(legacy_id).unwrap();
    assert_eq!(continued["id"], saved["id"]);
    assert_eq!(continued["botID"], saved["botID"]);
    assert_eq!(continued["items"][0], saved["items"][0]);
    assert_eq!(
        continued["sessions"][&provider]["sessionID"],
        saved["sessions"][&provider]["sessionID"]
    );
    assert!(continued["rustBotContext"].is_object());
    let baseline = call(&engine, "bots.read", json!({"botId":BOT})).unwrap()["baseline"].clone();
    call(&engine,"bots.patch",json!({"botId":BOT,"baseline":baseline,"patch":{"name":"Edited bot","persona":"Updated bot instructions"}})).unwrap();
    let expected_context = {
        let e = engine.lock().unwrap();
        crate::bot_runtime::current_context(&e.store, &e.store.thread(id).unwrap(), &root)
            .unwrap()
            .1
    };
    std::fs::write(
        root.join("expected.json"),
        serde_json::to_vec(&expected_context["instructions"]).unwrap(),
    )
    .unwrap();
    let original_context = context.clone();
    send(&engine, id, "second turn");
    context = engine.lock().unwrap().store.thread(id).unwrap()["rustBotContext"].clone();
    assert_eq!(context, expected_context);
    assert_ne!(context["instructions"], original_context["instructions"]);
    call(
        &engine,
        "agent.queue.add",
        json!({"threadId":legacy_id,"text":"queued after the bot edit"}),
    )
    .unwrap();
    wait_for_bot(&engine, legacy_id);
    let queued = engine.lock().unwrap().store.thread(legacy_id).unwrap();
    assert_eq!(
        queued["rustBotContext"]["instructions"],
        context["instructions"]
    );
    assert!(
        queued["rustMessageQueue"]
            .as_array()
            .unwrap()
            .iter()
            .any(|row| {
                row["text"] == "queued after the bot edit" && row["state"] == "completed"
            })
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
        original_context["instructions"]
    );
    assert_eq!(
        next_thread["rustBotContext"]["persona"],
        "Updated bot instructions"
    );
    assert!(next_thread["items"].as_array().unwrap().is_empty());
    let fork = call(&engine, "threads.fork", json!({"threadId":id})).unwrap();
    assert_eq!(fork["rustBotContext"], context);
    assert_eq!(fork["selection"], context["selection"]);
    assert!(fork["sessions"].as_object().unwrap().is_empty());
    send(&engine, fork["id"].as_str().unwrap(), "fork turn");
    if provider == "codex" {
        let changed = call(&engine, "agent.select", json!({"threadId":id,"provider":"codex","model":"changed-model","accessMode":"fullAccess","interactionMode":"build"})).unwrap();
        assert_eq!(changed["rustBotContext"], context);
        std::fs::write(
            root.join("expected-wire.json"),
            serde_json::to_vec(
                &json!({"model":"changed-model","approval":"never","sandbox":"danger-full-access"}),
            )
            .unwrap(),
        )
        .unwrap();
        send(&engine, id, "use new thread settings");
        send(&engine, id, "/compact");
    }
    let expected = if provider == "codex" {
        "thread/start\nthread/resume\nthread/resume\nthread/resume\nthread/resume\nthread/start\nthread/resume\nthread/resume\n"
    } else {
        "--session-id\n--resume\n--resume\n--resume\n--resume\n--session-id\n"
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
