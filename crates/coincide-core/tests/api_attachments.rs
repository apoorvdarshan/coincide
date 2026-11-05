//! API image flow runs in a child test process: provider overrides never mutate
//! the environment shared with concurrently running integration tests.
#![cfg(unix)]
use coincide_core::{api::Engine, store::Store};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

struct ChildGuard(Child);
impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
#[test]
fn attachments_api_persists_preflights_and_sends_real_image_blocks() {
    let dir = tempfile::tempdir().unwrap();
    let executable = dir.path().join("fixture-claude");
    fs::write(&executable,r#"#!/usr/bin/env python3
import base64,json,sys,os
def read(): return json.loads(sys.stdin.readline())
def write(value): print(json.dumps(value),flush=True)
run=int(open('provider-runs').read())+1 if os.path.exists('provider-runs') else 1
open('provider-runs','w').write(str(run))
if run==1:
 assert '--resume' not in sys.argv
 session=sys.argv[sys.argv.index('--session-id')+1]
 open('native-session','w').write(session)
else:
 session=sys.argv[sys.argv.index('--resume')+1]
 assert session==open('native-session').read()
r=read();write({'type':'control_response','response':{'subtype':'success','request_id':r['request_id']}})
r=read();assert r['type']=='user'
content=r['message']['content']
open('captured-'+str(run)+'.json','w').write(json.dumps(content))
if run==1:
 assert isinstance(content,list) and len(content)==1, content
 assert content[0]['type']=='image'
 image=content[0]['source'];assert image['type']=='base64' and image['media_type']=='image/png'
 assert base64.b64decode(image['data'])==open('expected-image.bin','rb').read()
else:
 assert run==2 and content=='scheduled fixture prompt', content
write({'type':'system','subtype':'init','session_id':session})
write({'type':'result','subtype':'success','is_error':False,'session_id':session,'result':'Fixture accepted turn '+str(run)})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let out = dir.path().join("child.stdout");
    let err = dir.path().join("child.stderr");
    let mut child = ChildGuard(
        Command::new(std::env::current_exe().unwrap())
            .args([
                "--ignored",
                "--exact",
                "attachments_api_fixture_child",
                "--nocapture",
            ])
            .env("COINCIDE_CLAUDE_EXECUTABLE", &executable)
            .env("ATTACHMENTS_API_FIXTURE_DIRECTORY", dir.path())
            .stdin(Stdio::null())
            .stdout(fs::File::create(&out).unwrap())
            .stderr(fs::File::create(&err).unwrap())
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(45);
    loop {
        if let Some(status) = child.0.try_wait().unwrap() {
            assert!(
                status.success(),
                "Attachment API child failed:\n{}\n{}",
                fs::read_to_string(&out).unwrap(),
                fs::read_to_string(&err).unwrap()
            );
            break;
        }
        assert!(
            Instant::now() < deadline,
            "Attachment API child timed out:\n{}\n{}",
            fs::read_to_string(&out).unwrap(),
            fs::read_to_string(&err).unwrap()
        );
        std::thread::sleep(Duration::from_millis(25));
    }
}
fn call(engine: &mut Engine, method: &str, params: Value) -> Value {
    let reply = engine.dispatch(json!({"id":"attachment-fixture","method":method,"params":params}));
    assert!(reply.get("error").is_none(), "{method}: {reply}");
    reply["result"].clone()
}
fn finish_operation(engine: &mut Engine, thread_id: &str, operation: &str) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let reply = call(
            engine,
            "workspace.result",
            json!({"threadId":thread_id,"operationId":operation}),
        );
        if reply["ready"] == true {
            return reply["result"].clone();
        }
        assert!(Instant::now() < deadline, "Attachment import timed out");
        std::thread::sleep(Duration::from_millis(15));
    }
}
fn add(engine: &mut Engine, thread_id: &str, source: &Path) -> Value {
    let accepted = call(
        engine,
        "attachments.add",
        json!({"threadId":thread_id,"path":source}),
    );
    let result = finish_operation(engine, thread_id, accepted["operationId"].as_str().unwrap());
    assert!(result.get("error").is_none(), "{result}");
    result["attachment"].clone()
}
fn wait_finished(engine: &mut Engine, thread_id: &str) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let status = call(engine, "app.status", json!({}));
        if status["running"].as_array().unwrap().is_empty() {
            break;
        }
        assert!(Instant::now() < deadline, "Provider did not finish");
        std::thread::sleep(Duration::from_millis(15));
    }
    let thread = engine.store.thread(thread_id).unwrap();
    assert!(
        !thread["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["kind"] == "error"),
        "Provider errors: {thread}"
    );
}
fn image_path(image: &Value, key: &str) -> PathBuf {
    PathBuf::from(image[key].as_str().unwrap())
}

#[test]
#[ignore = "invoked by isolated parent fixture test"]
fn attachments_api_fixture_child() {
    let Some(directory) = std::env::var_os("ATTACHMENTS_API_FIXTURE_DIRECTORY") else {
        return;
    };
    let directory = PathBuf::from(directory);
    let project_path = directory.join("project");
    fs::create_dir(&project_path).unwrap();
    let source = directory.join("source image.png");
    image::RgbaImage::from_pixel(8, 6, image::Rgba([25, 75, 125, 200]))
        .save(&source)
        .unwrap();
    let source_bytes = fs::read(&source).unwrap();
    let database = directory.join("candidate/coincide.sqlite");
    let mut engine = Engine::new(Store::open(&database).unwrap());
    let project = call(
        &mut engine,
        "projects.create",
        json!({"path":project_path,"name":"Attachment fixture"}),
    );
    let thread = call(
        &mut engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    );
    let id = thread["id"].as_str().unwrap().to_owned();
    call(
        &mut engine,
        "agent.select",
        json!({"threadId":id,"provider":"claude"}),
    );
    let other = call(
        &mut engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    );
    let operation = call(
        &mut engine,
        "attachments.add",
        json!({"threadId":id,"path":source}),
    );
    let wrong_owner=engine.dispatch(json!({"method":"workspace.result","params":{"threadId":other["id"],"operationId":operation["operationId"]}}));
    assert!(wrong_owner.get("error").is_some());
    let imported = finish_operation(&mut engine, &id, operation["operationId"].as_str().unwrap());
    assert!(imported.get("error").is_none(), "{imported}");
    let attachment = imported["attachment"].clone();
    assert_eq!(fs::read(&source).unwrap(), source_bytes);
    assert_eq!(
        fs::read(image_path(&attachment, "originalPath")).unwrap(),
        source_bytes
    );
    for key in ["path", "originalPath"] {
        assert!(
            image_path(&attachment, key)
                .starts_with(database.parent().unwrap().canonicalize().unwrap())
        );
        assert_eq!(
            fs::metadata(image_path(&attachment, key))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    assert_eq!(attachment["width"], 8);
    assert_eq!(attachment["height"], 6);
    call(
        &mut engine,
        "threads.patch",
        json!({"threadId":id,"patch":{"draft":"Draft note retained across restart"}}),
    );
    let mut saved = engine.store.thread(&id).unwrap();
    saved["futureAttachmentContext"] = json!({"keep":42});
    engine.store.save(&saved).unwrap();
    assert_eq!(saved["rustDraftImages"], json!([attachment]));
    drop(engine);
    let mut engine = Engine::new(Store::open(&database).unwrap());
    let persisted = engine.store.thread(&id).unwrap();
    assert_eq!(persisted["rustDraftImages"], saved["rustDraftImages"]);
    assert_eq!(persisted["draft"], "Draft note retained across restart");
    let removed = add(&mut engine, &id, &source);
    call(
        &mut engine,
        "attachments.remove",
        json!({"threadId":id,"attachmentId":removed["id"]}),
    );
    assert!(image_path(&removed, "path").exists());
    assert!(image_path(&removed, "originalPath").exists());
    assert_eq!(
        engine.store.thread(&id).unwrap()["rustDraftImages"],
        json!([attachment])
    );
    let bad_source = directory.join("invalid.png");
    fs::write(&bad_source, b"not an image").unwrap();
    let operation = call(
        &mut engine,
        "attachments.add",
        json!({"threadId":id,"path":bad_source}),
    );
    assert!(
        finish_operation(&mut engine, &id, operation["operationId"].as_str().unwrap())
            .get("error")
            .is_some()
    );
    assert_eq!(fs::read(&bad_source).unwrap(), b"not an image");
    let mut forged = engine.store.thread(&id).unwrap();
    forged["rustDraftImages"][0]["path"] = json!(source);
    engine.store.save(&forged).unwrap();
    let refused =
        engine.dispatch(json!({"method":"agent.send","params":{"threadId":id,"text":""}}));
    assert!(refused.get("error").is_some(), "{refused}");
    assert!(
        refused["error"]["message"]
            .as_str()
            .unwrap()
            .contains("outside its UUID directory")
    );
    assert_eq!(engine.store.thread(&id).unwrap(), forged);
    assert!(!project_path.join("provider-runs").exists());
    forged["rustDraftImages"] = json!([attachment]);
    forged["draft"] = json!("");
    engine.store.save(&forged).unwrap();
    fs::write(
        project_path.join("expected-image.bin"),
        fs::read(image_path(&attachment, "path")).unwrap(),
    )
    .unwrap();
    call(&mut engine, "agent.send", json!({"threadId":id,"text":""}));
    let accepted = engine.store.thread(&id).unwrap();
    assert_eq!(accepted["rustDraftImages"], json!([]));
    assert_eq!(accepted["draft"], "");
    let users = accepted["items"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|item| item["kind"] == "user")
        .collect::<Vec<_>>();
    assert_eq!(users.len(), 1);
    assert_eq!(users[0]["text"], "");
    assert_eq!(users[0]["rustImages"], json!([attachment]));
    wait_finished(&mut engine, &id);
    let finished = engine.store.thread(&id).unwrap();
    assert_eq!(finished["futureAttachmentContext"]["keep"], 42);
    assert!(
        finished["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["kind"] == "assistant" && item["text"] == "Fixture accepted turn 1")
    );
    assert_eq!(fs::read(&source).unwrap(), source_bytes);
    assert_eq!(
        fs::read(image_path(&attachment, "originalPath")).unwrap(),
        source_bytes
    );
    drop(engine);
    let mut engine = Engine::new(Store::open(&database).unwrap());
    assert_eq!(engine.store.thread(&id).unwrap(), finished);

    // A scheduled prompt must never consume the user's unrelated unsent image
    // or composer text. This exercises the actual runner and fake provider.
    let unsent = add(&mut engine, &id, &source);
    call(
        &mut engine,
        "threads.patch",
        json!({"threadId":id,"patch":{"draft":"Keep this unsent composer draft"}}),
    );
    let future = chrono::Utc::now() + chrono::Duration::hours(1);
    let scheduled = call(
        &mut engine,
        "schedules.create",
        json!({"task":{"name":"Image isolation","prompt":"scheduled fixture prompt","projectID":project["id"],"threadID":id,"recurrence":{"kind":"once","timeZoneID":"UTC","date":future,"hour":0,"minute":0,"weekday":1}}}),
    );
    let schedule_id = scheduled["task"]["id"].as_str().unwrap();
    engine.approve_schedule(schedule_id).unwrap();
    call(
        &mut engine,
        "schedules.run-now",
        json!({"scheduleId":schedule_id}),
    );
    wait_finished(&mut engine, &id);
    let scheduled_thread = engine.store.thread(&id).unwrap();
    assert_eq!(scheduled_thread["draft"], "Keep this unsent composer draft");
    assert_eq!(scheduled_thread["rustDraftImages"], json!([unsent]));
    let last_user = scheduled_thread["items"]
        .as_array()
        .unwrap()
        .iter()
        .rev()
        .find(|item| item["kind"] == "user")
        .unwrap();
    assert_eq!(last_user["text"], "scheduled fixture prompt");
    assert!(last_user["rustImages"].is_null());
    assert_eq!(
        fs::read_to_string(project_path.join("provider-runs")).unwrap(),
        "2"
    );
    assert_eq!(fs::read(&source).unwrap(), source_bytes);
}
