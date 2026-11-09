//! Descriptive provider tool metadata, never approval or turn-lifecycle authority.
use serde_json::{Value, json};

pub(super) fn apply(row: &mut Value, captured_provider: &str, item: &Value) {
    match captured_provider {
        "codex" => apply_codex(row, item),
        "opencode" => apply_opencode(row, item),
        _ => {}
    }
}

/// OpenCode reports tool parts as `toolCall` with a lowercase tool name and a
/// free-form input object. Persist the same kind of display metadata Swift's
/// transcript derives (title, category, status) instead of making every row a
/// generic "Tool activity" JSON payload.
fn apply_opencode(row: &mut Value, item: &Value) {
    if item["type"] != "toolCall" {
        return;
    }
    let Some(fields) = row.as_object_mut() else {
        return;
    };
    let name = item["name"].as_str().unwrap_or_default();
    let category = match name {
        "shell" | "bash" => "command",
        "read" | "list" => "read",
        "grep" | "glob" | "search" => "search",
        "webfetch" | "websearch" => "web",
        "edit" | "write" | "patch" | "multiedit" => "fileChange",
        "task" => "task",
        "todowrite" | "todoread" => "todo",
        "question" => "other",
        value if value.starts_with("mcp") => "mcp",
        _ => "other",
    };
    fields.insert("category".into(), json!(category));
    let input = &item["input"];
    // Swift names the action in the work log and keeps the raw command/path in
    // the expandable detail. A single OpenCode shell row reads "Run command",
    // never the full command line.
    let (title, detail) = match name {
        "shell" | "bash" => (
            Some("Run command".to_owned()),
            input["command"].as_str().and_then(bounded_tool_title),
        ),
        "read" => (
            Some("Read file".to_owned()),
            input["filePath"]
                .as_str()
                .or_else(|| input["path"].as_str())
                .and_then(bounded_tool_title),
        ),
        "write" => (
            Some("Write file".to_owned()),
            input["filePath"]
                .as_str()
                .or_else(|| input["path"].as_str())
                .and_then(bounded_tool_title),
        ),
        "edit" | "patch" | "multiedit" => (
            Some("Edit file".to_owned()),
            input["filePath"]
                .as_str()
                .or_else(|| input["path"].as_str())
                .and_then(bounded_tool_title),
        ),
        "grep" | "glob" | "search" => (
            Some("Search".to_owned()),
            input["pattern"].as_str().and_then(bounded_tool_title),
        ),
        "webfetch" | "websearch" => (
            Some("Web search".to_owned()),
            input["url"].as_str().and_then(bounded_tool_title),
        ),
        "task" => (
            Some("Subagent".to_owned()),
            input["description"].as_str().and_then(bounded_tool_title),
        ),
        "todowrite" | "todoread" => (Some("Update plan".to_owned()), None),
        "question" => (
            Some("Question".to_owned()),
            input["questions"]
                .as_array()
                .and_then(|questions| questions.first())
                .and_then(|question| question["question"].as_str())
                .and_then(bounded_tool_title),
        ),
        value => (bounded_tool_title(value), None),
    };
    if let Some(title) = title {
        fields.insert("title".into(), json!(title));
    }
    if let Some(detail) = detail {
        fields.insert("detail".into(), json!(detail));
    }
    let output = item["content"]
        .as_array()
        .map(|content| {
            content
                .iter()
                .filter_map(|part| part["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n")
        })
        .filter(|output| !output.trim().is_empty());
    if let Some(output) = output {
        fields.insert("output".into(), json!(output));
    }
    if let Some(status) = match item["status"].as_str() {
        Some("running") => Some("running"),
        Some("completed") => Some("completed"),
        Some("failed") => Some("failed"),
        Some("cancelled" | "canceled" | "declined") => Some("declined"),
        _ => None,
    } {
        fields.insert("status".into(), json!(status));
    }
}

fn bounded_tool_title(source: &str) -> Option<String> {
    let mut chars = source.chars();
    let head: String = chars.by_ref().take(160).collect();
    let mut title = head.split_whitespace().collect::<Vec<_>>().join(" ");
    if title.is_empty() {
        return None;
    }
    if chars.next().is_some() {
        title.push('…');
    }
    Some(title)
}

fn apply_codex(row: &mut Value, item: &Value) {
    if item["type"] != "commandExecution" {
        return;
    }
    let Some(fields) = row.as_object_mut() else {
        return;
    };
    fields.insert("category".into(), json!("command"));
    if let Some(command) = item["command"].as_str() {
        let mut chars = command.chars();
        let head: String = chars.by_ref().take(160).collect();
        let mut title = head.split_whitespace().collect::<Vec<_>>().join(" ");
        if !title.is_empty() {
            if chars.next().is_some() {
                title.push('…');
            }
            fields.insert("title".into(), json!(title));
        }
    }
    // These are the exact CommandExecutionStatus values, not event-method,
    // output/exit-code, saved selection, or local cancellation inferences.
    let status = match item["status"].as_str() {
        Some("inProgress") => Some("running"),
        Some("completed") => Some("completed"),
        Some("failed") => Some("failed"),
        Some("declined") => Some("declined"),
        _ => None,
    };
    if let Some(status) = status {
        fields.insert("status".into(), json!(status));
    } else {
        // Only this field can become stale on a matched command's next frame.
        fields.remove("status");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_command_metadata_preserves_body_identity_and_opaque_fields() {
        for (wire, saved) in [
            ("inProgress", "running"),
            ("completed", "completed"),
            ("failed", "failed"),
            ("declined", "declined"),
        ] {
            let item = json!({"type":"commandExecution","id":"command","command":"  printf\n '設定 🦀'  ","status":wire,"exitCode":123,"future":{"keep":true}});
            let original = item.clone();
            let mut row = json!({"id":"same-row","kind":"tool","externalID":"tool:command","text":item.to_string(),"futureRow":[1,2]});
            let mut expected = row.clone();
            expected["category"] = json!("command");
            expected["title"] = json!("printf '設定 🦀'");
            expected["status"] = json!(saved);
            apply(&mut row, "codex", &item);
            assert_eq!(row, expected);
            assert_eq!(item, original);
        }
    }

    #[test]
    fn opencode_tool_call_gets_swift_style_title_category_and_status() {
        let mut shell = json!({"kind":"tool","text":"raw"});
        apply(
            &mut shell,
            "opencode",
            &json!({"type":"toolCall","name":"shell","status":"running","input":{"command":"  cargo   test\n-p coincide-core "}}),
        );
        assert_eq!(shell["category"], "command");
        assert_eq!(shell["title"], "Run command");
        assert_eq!(shell["detail"], "cargo test -p coincide-core");
        assert_eq!(shell["status"], "running");
        assert_eq!(shell["text"], "raw");

        let mut read = json!({"kind":"tool","text":"raw"});
        apply(
            &mut read,
            "opencode",
            &json!({"type":"toolCall","name":"read","status":"completed","input":{"filePath":"/tmp/crates/core/src/api.rs"}}),
        );
        assert_eq!(read["category"], "read");
        assert_eq!(read["title"], "Read file");
        assert_eq!(read["detail"], "/tmp/crates/core/src/api.rs");
        assert_eq!(read["status"], "completed");

        let mut question = json!({"kind":"tool","text":"raw"});
        apply(
            &mut question,
            "opencode",
            &json!({"type":"toolCall","name":"question","status":"completed","input":{"questions":[{"question":"Which path?"}]}}),
        );
        assert_eq!(question["title"], "Question");
        assert_eq!(question["detail"], "Which path?");
        assert_eq!(question["status"], "completed");
    }

    #[test]
    fn opencode_non_tool_parts_are_untouched() {
        let original = json!({"kind":"tool","text":"raw","title":"keep","status":"waiting"});
        for item in [
            json!({"type":"reasoning","text":"thought"}),
            json!({"type":"agentMessage","text":"answer"}),
        ] {
            let mut row = original.clone();
            apply(&mut row, "opencode", &item);
            assert_eq!(row, original);
        }
    }

    #[test]
    fn unknown_status_clears_only_status_and_other_providers_and_types_are_untouched() {
        for status in [
            None,
            Some(Value::Null),
            Some(json!("future")),
            Some(json!("running")),
            Some(json!(true)),
        ] {
            let mut row = json!({"status":"running","category":"command","title":"previous explicit command","id":"same","text":"exact body","future":42});
            let mut expected = row.clone();
            expected.as_object_mut().unwrap().remove("status");
            let mut item = json!({"type":"commandExecution","exitCode":0});
            if let Some(status) = status {
                item["status"] = status;
            }
            apply(&mut row, "codex", &item);
            assert_eq!(row, expected);
        }
        let original = json!({"id":"same","text":"exact body","title":"other provider title","status":"waiting","future":true});
        for (provider, item) in [
            (
                "claude",
                json!({"type":"commandExecution","command":"example","status":"completed"}),
            ),
            (
                "codex",
                json!({"type":"toolCall","command":"example","status":"completed"}),
            ),
            (
                "codex",
                json!({"type":"agentMessage","text":"{\"type\":\"commandExecution\",\"status\":\"completed\"}"}),
            ),
        ] {
            let mut row = original.clone();
            apply(&mut row, provider, &item);
            assert_eq!(row, original);
        }
    }

    #[test]
    fn literal_command_title_is_unicode_bounded_without_parsing_command_or_output() {
        let mut row = json!({"id":"same","text":"exact body"});
        apply(
            &mut row,
            "codex",
            &json!({"type":"commandExecution","command":"界🦀".repeat(100),"aggregatedOutput":"{\"status\":\"completed\"}"}),
        );
        assert_eq!(row["title"], format!("{}…", "界🦀".repeat(80)));
        assert!(row.get("status").is_none());
        for command in [Value::Null, json!(" \t\n"), json!(["echo", "fixture"])] {
            let mut row = json!({"text":"exact body"});
            apply(
                &mut row,
                "codex",
                &json!({"type":"commandExecution","command":command}),
            );
            assert!(row.get("title").is_none());
            assert_eq!(row["text"], "exact body");
        }
    }

    #[test]
    fn existing_branch_sanitization_changes_the_copy_without_mutating_source_metadata() {
        let mut tool = json!({"id":"33333333-3333-4333-8333-333333333333","kind":"tool","text":"exact body","externalID":"tool:command","future":42});
        apply(
            &mut tool,
            "codex",
            &json!({"type":"commandExecution","command":"fixture command","status":"inProgress"}),
        );
        let source = json!({"id":"11111111-1111-4111-8111-111111111111","title":"Source","draft":"unsent","items":[{"id":"22222222-2222-4222-8222-222222222222","kind":"user","text":"request"},tool]});
        let before = source.clone();
        let copy = crate::thread_history::fork_through_turn(
            &source,
            None,
            crate::thread_history::HistoryOptions {
                new_thread_id: "44444444-4444-4444-8444-444444444444",
                now: 123.,
                running_turn_id: None,
                turn_openers: &[],
            },
        )
        .unwrap();
        assert_eq!(source, before);
        assert_eq!(copy.thread["items"][1]["status"], "failed");
        for key in ["text", "title", "category", "future"] {
            assert_eq!(copy.thread["items"][1][key], source["items"][1][key]);
        }
        assert_eq!(source["items"][1]["status"], "running");
    }

    #[cfg(unix)]
    #[test]
    fn engine_codex_command_metadata_preserves_protocol_barriers_and_upsert_identity() {
        use std::{os::unix::fs::PermissionsExt, process::Command};
        let root = tempfile::tempdir().unwrap();
        let executable = root.path().join("codex-command-fixture");
        let items = json!([
            {"id":"exec","type":"commandExecution","command":"printf '設定 🦀'","status":"inProgress","future":{"opaque":[1,2]},"aggregatedOutput":null},
            {"id":"exec","type":"commandExecution","command":"printf '設定 🦀'","status":"completed","exitCode":7,"future":{"opaque":[1,2]},"aggregatedOutput":"exact output\n"},
            {"id":"exec","type":"commandExecution","command":"printf '設定 🦀'","status":"future-status","exitCode":0,"future":{"opaque":[1,2]},"aggregatedOutput":"{\"status\":\"completed\"}"},
            {"id":"other","type":"fileChange","status":"completed","changes":[{"future":"not normalized"}]}
        ]);
        std::fs::write(root.path().join("items.json"), items.to_string()).unwrap();
        std::fs::write(&executable, r#"#!/usr/bin/env python3
import json,sys
from pathlib import Path
root=Path(__file__).parent
items=json.loads((root/'items.json').read_text())
def read():
 value=json.loads(sys.stdin.readline())
 with (root/'requests.jsonl').open('a') as f:f.write(json.dumps(value)+'\n')
 return value
def write(value):print(json.dumps(value),flush=True)
def item(method,index):write({'method':method,'params':{'threadId':'metadata-thread','turnId':'metadata-turn','item':items[index]}})
def barrier(number,decision):
 write({'id':number,'method':'item/commandExecution/requestApproval','params':{'command':'fixture barrier','availableDecisions':[decision]}})
 assert read()=={'id':number,'result':{'decision':decision}}
r=read();assert r['method']=='initialize';write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read();assert r['method']=='thread/start';write({'id':r['id'],'result':{'thread':{'id':'metadata-thread'},'model':'fixture-model'}})
r=read();assert r['method']=='turn/start';write({'id':r['id'],'result':{'turn':{'id':'metadata-turn'}}})
item('item/started',0);barrier(100,'accept')
item('item/completed',1);barrier(101,'decline')
item('item/completed',2);item('item/completed',3);barrier(102,'cancel')
write({'method':'turn/completed','params':{'threadId':'metadata-thread','turn':{'id':'metadata-turn','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        let result = Command::new(std::env::current_exe().unwrap())
            .args([
                "--ignored",
                "--exact",
                "api::provider_tool_metadata::tests::command_metadata_fixture_child",
                "--nocapture",
            ])
            .env("COINCIDE_COMMAND_METADATA_FIXTURE", root.path())
            .env("COINCIDE_CODEX_EXECUTABLE", &executable)
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{} {}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        );
        let requests = std::fs::read_to_string(root.path().join("requests.jsonl"))
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .collect::<Vec<_>>();
        let replies = requests
            .iter()
            .filter(|value| value.get("result").is_some())
            .cloned()
            .collect::<Vec<_>>();
        assert_eq!(
            replies,
            [
                json!({"id":100,"result":{"decision":"accept"}}),
                json!({"id":101,"result":{"decision":"decline"}}),
                json!({"id":102,"result":{"decision":"cancel"}})
            ]
        );
    }

    #[cfg(unix)]
    #[test]
    #[ignore = "Parent provides isolated synthetic Codex executable and data"]
    fn command_metadata_fixture_child() {
        use crate::{
            api::Engine,
            store::{Store, text},
        };
        use std::{
            path::PathBuf,
            time::{Duration, Instant},
        };
        let root = PathBuf::from(std::env::var_os("COINCIDE_COMMAND_METADATA_FIXTURE").unwrap());
        let expected: Value =
            serde_json::from_slice(&std::fs::read(root.join("items.json")).unwrap()).unwrap();
        let mut engine = Engine::fixture(Store::open(&root.join("state.sqlite")).unwrap());
        let mut thread = engine
            .execute("threads.create", &json!({"cwd":root}))
            .unwrap();
        let id = text(&thread, "id");
        let historic = json!({"id":"55555555-5555-4555-8555-555555555555","kind":"tool","externalID":"tool:exec","text":"exact historical body","status":"declined","future":"history retained"});
        thread["items"] = json!([historic.clone()]);
        thread["future"] = json!({"keep":true});
        engine.store.save(&thread).unwrap();
        engine
            .execute(
                "agent.send",
                &json!({"threadId":id,"text":"synthetic command metadata"}),
            )
            .unwrap();
        assert_eq!(engine.runs[&id].provider, "codex");
        assert_eq!(
            engine.execute("app.status", &json!({})).unwrap()["starting"],
            json!([id]),
            "no provider event has arrived yet"
        );
        // Test concurrent saved-selection changes without changing the provider
        // captured for this already admitted, actually running fake session.
        let mut changed = engine.store.thread(&id).unwrap();
        changed["selection"]["provider"] = json!("claude");
        engine.store.save(&changed).unwrap();

        fn barrier(engine: &mut Engine, id: &str, request: &str) {
            let deadline = Instant::now() + Duration::from_secs(10);
            loop {
                engine.poll();
                if engine
                    .runs
                    .get(id)
                    .is_some_and(|run| run.pending.contains_key(request))
                {
                    return;
                }
                assert!(
                    Instant::now() < deadline,
                    "fake command barrier was not observed"
                );
                std::thread::yield_now();
            }
        }
        fn current(engine: &Engine, id: &str) -> Value {
            engine.store.thread(id).unwrap()["items"]
                .as_array()
                .unwrap()
                .iter()
                .rev()
                .find(|item| item["kind"] == "tool" && item["externalID"] == "tool:exec")
                .unwrap()
                .clone()
        }
        barrier(&mut engine, &id, "100");
        assert_eq!(
            engine.execute("app.status", &json!({})).unwrap()["starting"],
            json!([])
        );
        let pending = engine
            .execute("agent.pending", &json!({"threadId":id}))
            .unwrap();
        assert_eq!(
            pending[0]["provider"], "codex",
            "the run's provider, not the selection"
        );
        let first = current(&engine, &id);
        assert!(
            first.get("completedAt").is_none(),
            "started calls are unfinished"
        );
        assert_ne!(first["id"], historic["id"]);
        assert_eq!(first["text"], expected[0].to_string());
        assert_eq!(first["title"], "printf '設定 🦀'");
        assert_eq!(first["category"], "command");
        assert_eq!(first["status"], "running");
        assert_eq!(
            engine.store.thread(&id).unwrap()["selection"]["provider"],
            "claude"
        );
        assert_eq!(engine.runs[&id].provider, "codex");
        engine
            .execute(
                "agent.respond",
                &json!({"threadId":id,"requestId":"100","decision":"accept"}),
            )
            .unwrap();

        barrier(&mut engine, &id, "101");
        let completed = current(&engine, &id);
        assert_eq!(completed["id"], first["id"]);
        assert!(completed["completedAt"].as_f64().is_some());
        assert_eq!(completed["text"], expected[1].to_string());
        assert_eq!(
            completed["status"], "completed",
            "exitCode cannot replace explicit display status"
        );
        assert!(
            engine.runs.contains_key(&id),
            "display status cannot retire a run"
        );
        assert!(
            engine.runs[&id].pending.contains_key("101"),
            "display status cannot answer an approval"
        );
        assert!(
            engine
                .execute(
                    "agent.respond",
                    &json!({"threadId":id,"requestId":"101","decision":"accept"})
                )
                .is_err()
        );
        assert!(engine.runs[&id].pending.contains_key("101"));
        assert!(
            engine
                .execute(
                    "agent.respond",
                    &json!({"threadId":id,"requestId":"101","decision":"decline","text":"note"})
                )
                .is_err(),
            "only Claude reads a note with an approval"
        );
        assert!(engine.runs[&id].pending.contains_key("101"));
        // A blank note is no note; the reply below carries only the decision.
        engine
            .execute(
                "agent.respond",
                &json!({"threadId":id,"requestId":"101","decision":"decline","text":" "}),
            )
            .unwrap();

        barrier(&mut engine, &id, "102");
        let unknown = current(&engine, &id);
        assert_eq!(unknown["id"], first["id"]);
        assert_eq!(unknown["text"], expected[2].to_string());
        assert!(unknown.get("status").is_none());
        assert_eq!(unknown["title"], first["title"]);
        let saved = engine.store.thread(&id).unwrap();
        let tools = saved["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|item| item["kind"] == "tool")
            .collect::<Vec<_>>();
        assert_eq!(tools.len(), 3);
        assert_eq!(tools[0], &historic);
        assert_eq!(tools[1]["id"], first["id"]);
        assert_eq!(tools[2]["externalID"], "tool:other");
        assert_eq!(tools[2]["text"], expected[3].to_string());
        assert!(
            tools[2].get("category").is_none()
                && tools[2].get("status").is_none()
                && tools[2].get("title").is_none()
        );
        assert_eq!(saved["future"], json!({"keep":true}));
        engine
            .execute(
                "agent.respond",
                &json!({"threadId":id,"requestId":"102","decision":"cancel"}),
            )
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while engine.runs.contains_key(&id) || engine.provider_workers_status().running != 0 {
            engine.poll();
            assert!(
                Instant::now() < deadline,
                "fake command turn did not retire"
            );
            std::thread::yield_now();
        }
        assert_eq!(current(&engine, &id), unknown);
    }
}
