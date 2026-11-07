//! Real native fake gh processes, private ledger and restart on each desktop OS.
//! No network, provider, OS vault or user configuration is consulted.
use coincide_core::{github_write::GithubWriteService, native_file};
use serde_json::{Value, json};
use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};
fn snapshot() -> Value {
    json!({"number":7,"title":"Synthetic PR","url":"https://github.com/owner/project/pull/7","state":"OPEN","isDraft":false,"headRefOid":"a".repeat(40),"headRefName":"feature","baseRefName":"main","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","reviews":[],"statusCheckRollup":[{"__typename":"CheckRun","name":"fixture","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeCommit":null})
}
fn fake_gh(args: &[String]) {
    let mut body = Value::Null;
    if args.iter().any(|arg| arg == "--input") {
        let mut bytes = Vec::new();
        std::io::stdin()
            .take(256 * 1024 + 1)
            .read_to_end(&mut bytes)
            .unwrap();
        assert!(bytes.len() <= 256 * 1024);
        body = serde_json::from_slice(&bytes).unwrap();
    }
    assert!(
        !args
            .iter()
            .any(|arg| ["--admin", "--auto", "--queue"].contains(&arg.as_str()))
    );
    fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open("calls.jsonl")
        .unwrap()
        .write_all(format!("{}\n", json!({"args":args,"body":body})).as_bytes())
        .unwrap();
    let result = if args.first().map(String::as_str) == Some("pr") {
        assert_eq!(&args[..3], &["pr", "view", "7"]);
        serde_json::from_slice::<Value>(&fs::read("snapshot.json").unwrap()).unwrap()
    } else {
        assert_eq!(args.first().map(String::as_str), Some("api"));
        assert!(
            args.windows(2)
                .any(|pair| pair == ["--hostname", "github.com"])
        );
        let method = &args[args.iter().position(|arg| arg == "--method").unwrap() + 1];
        let endpoint = args.iter().find(|arg| arg.starts_with("repos/")).unwrap();
        match method.as_str() {
            "POST" => {
                assert_eq!(endpoint, "repos/owner/project/pulls/7/reviews");
                assert_eq!(body["commit_id"], "a".repeat(40));
                assert_eq!(body.as_object().unwrap().len(), 3);
                let state = match body["event"].as_str().unwrap() {
                    "COMMENT" => "COMMENTED",
                    "APPROVE" => "APPROVED",
                    "REQUEST_CHANGES" => "CHANGES_REQUESTED",
                    _ => panic!("unexpected event"),
                };
                let value = json!({"id":19,"state":state,"body":body["body"],"commit_id":body["commit_id"],"html_url":"https://github.com/owner/project/pull/7#pullrequestreview-19"});
                fs::write("review.json", serde_json::to_vec(&value).unwrap()).unwrap();
                if Path::new("lost-response").exists() {
                    std::process::exit(7);
                }
                value
            }
            "GET" => {
                assert_eq!(endpoint, "repos/owner/project/pulls/7/reviews/19");
                serde_json::from_slice(&fs::read("review.json").unwrap()).unwrap()
            }
            "PUT" => {
                assert_eq!(endpoint, "repos/owner/project/pulls/7/merge");
                assert_eq!(body["sha"], "a".repeat(40));
                assert_eq!(body["merge_method"], "squash");
                let mut value = snapshot();
                value["state"] = json!("MERGED");
                value["mergeCommit"] = json!({"oid":"b".repeat(40)});
                fs::write("snapshot.json", serde_json::to_vec(&value).unwrap()).unwrap();
                json!({"merged":true,"sha":"b".repeat(40)})
            }
            _ => panic!("unexpected method"),
        }
    };
    println!("{result}");
}
fn writes(root: &Path) -> usize {
    fs::read_to_string(root.join("calls.jsonl"))
        .unwrap_or_default()
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .filter(|v| {
            v["args"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a == "POST" || a == "PUT")
        })
        .count()
}
fn call(service: &GithubWriteService, method: &str, root: &Path, params: &Value) -> Value {
    let id = params["threadId"].as_str().unwrap();
    match method {
        "prepare" => service.prepare(id, root, params),
        "submit" => service.submit(id, root, params),
        "result" => service.result(id, root, params),
        _ => panic!("unknown fixture operation"),
    }
    .unwrap()
}
fn wait(service: &GithubWriteService, root: &Path, request: &Value) -> Value {
    let started = Instant::now();
    loop {
        let result = call(service, "result", root, request);
        if result["status"] != "pending" {
            return result;
        }
        assert!(
            started.elapsed() < Duration::from_secs(15),
            "owned fake mutation did not finish"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}
fn close(service: GithubWriteService) {
    service.request_shutdown();
    let started = Instant::now();
    while !service.shutdown_status().ready() {
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "owned write worker did not join"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    drop(service);
}
fn run(root: &Path) {
    let exe = std::env::current_exe().unwrap();
    for mode in [
        "COMMENT",
        "APPROVE",
        "REQUEST_CHANGES",
        "MERGE",
        "LOST",
        "MOVED",
    ] {
        let project = root.join(mode);
        native_file::private_directory(&project).unwrap();
        fs::write(
            project.join("snapshot.json"),
            serde_json::to_vec(&snapshot()).unwrap(),
        )
        .unwrap();
        let ledger = project.join("ledger");
        let service = GithubWriteService::create(exe.clone(), ledger.clone()).unwrap();
        assert!(
            GithubWriteService::open(exe.clone(), ledger.clone()).is_err(),
            "another writer cannot acquire this ledger"
        );
        #[cfg(windows)]
        {
            assert!(fs::rename(&ledger, project.join("ledger-moved")).is_err());
            assert!(
                fs::rename(
                    ledger.join("mutations.sqlite3"),
                    project.join("database-moved")
                )
                .is_err()
            );
        }
        let mut request = json!({"threadId":uuid::Uuid::new_v4().to_string(),"expectedRoot":project,"repository":"owner/project","number":7,"expectedHead":"a".repeat(40)});
        let prepared = call(&service, "prepare", &project, &request);
        request["baselineId"] = prepared["baselineId"].clone();
        request["mutationId"] = json!(uuid::Uuid::new_v4().to_string());
        request["action"] = if mode == "MERGE" {
            json!({"kind":"merge","method":"squash"})
        } else {
            json!({"kind":"review","event":if ["LOST","MOVED"].contains(&mode){"COMMENT"}else{mode},"body":if mode=="APPROVE"{""}else{"Literal synthetic $(data) `only` 👩🏽‍💻"}})
        };
        if mode == "LOST" {
            fs::write(project.join("lost-response"), []).unwrap();
        }
        if mode == "MOVED" {
            let mut changed = snapshot();
            changed["headRefOid"] = json!("c".repeat(40));
            fs::write(
                project.join("snapshot.json"),
                serde_json::to_vec(&changed).unwrap(),
            )
            .unwrap();
        }
        call(&service, "submit", &project, &request);
        let result = wait(&service, &project, &request);
        assert_eq!(
            result["status"],
            if mode == "LOST" {
                "uncertain"
            } else if mode == "MOVED" {
                "rejected"
            } else {
                "succeeded"
            },
            "{mode}: {result}"
        );
        assert_eq!(writes(&project), if mode == "MOVED" { 0 } else { 1 });
        assert_eq!(call(&service, "submit", &project, &request), result);
        if ["COMMENT", "APPROVE", "REQUEST_CHANGES"].contains(&mode) {
            assert_eq!(
                result["result"]["state"],
                match mode {
                    "COMMENT" => "COMMENTED",
                    "APPROVE" => "APPROVED",
                    _ => "CHANGES_REQUESTED",
                }
            );
        }
        close(service);
        let reopened = GithubWriteService::open(exe.clone(), ledger.clone()).unwrap();
        assert_eq!(call(&reopened, "result", &project, &request), result);
        assert_eq!(call(&reopened, "submit", &project, &request), result);
        assert_eq!(writes(&project), if mode == "MOVED" { 0 } else { 1 });
        close(reopened);
        #[cfg(windows)]
        {
            fs::rename(&ledger, project.join("ledger-moved")).unwrap();
        }
        println!("portable GitHub {mode} passed");
    }
}
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args
        .first()
        .map(String::as_str)
        .is_some_and(|arg| arg == "pr" || arg == "api")
    {
        fake_gh(&args);
        return;
    }
    if args.first().map(String::as_str) == Some("--private-parent") {
        run(&PathBuf::from(&args[1]));
        return;
    }
    let root =
        std::env::temp_dir().join(format!("coincide-github-portable-{}", uuid::Uuid::new_v4()));
    native_file::private_directory(&root).unwrap();
    for name in ["home", "tmp"] {
        native_file::private_directory(&root.join(name)).unwrap();
    }
    let mut command = Command::new(std::env::current_exe().unwrap());
    command.env_clear();
    for key in ["PATH", "SystemRoot", "WINDIR", "COMSPEC", "PATHEXT"] {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    let result = command
        .arg("--private-parent")
        .arg(&root)
        .env("HOME", root.join("home"))
        .env("USERPROFILE", root.join("home"))
        .env("TMPDIR", root.join("tmp"))
        .env("TMP", root.join("tmp"))
        .env("TEMP", root.join("tmp"))
        .current_dir(&root)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "Portable fixture retained at {}\n{}\n{}",
        root.display(),
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
    let output = String::from_utf8(result.stdout).unwrap();
    assert_eq!(
        output
            .lines()
            .filter(|line| line.starts_with("portable GitHub "))
            .count(),
        6
    );
    print!("{output}");
    fs::remove_dir_all(root).unwrap();
}
