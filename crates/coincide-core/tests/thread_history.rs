use coincide_core::thread_history::{HistoryOptions, edit_from_user, fork_through_turn};
use serde_json::{Value, json};
use uuid::Uuid;

const SOURCE: &str = "11111111-1111-4111-8111-111111111111";
const BRANCH: &str = "22222222-2222-4222-8222-222222222222";
const U1: &str = "33333333-3333-4333-8333-333333333333";
const A1: &str = "44444444-4444-4444-8444-444444444444";
const STEER: &str = "55555555-5555-4555-8555-555555555555";
const TOOL: &str = "66666666-6666-4666-8666-666666666666";
const U2: &str = "77777777-7777-4777-8777-777777777777";
const A2: &str = "88888888-8888-4888-8888-888888888888";

fn options(running: Option<&str>) -> HistoryOptions<'_> {
    HistoryOptions {
        new_thread_id: BRANCH,
        now: 1234.5,
        running_turn_id: running,
        turn_openers: &[],
    }
}

fn fixture() -> Value {
    json!({
        "id":SOURCE,"projectID":"same-project","title":"Original","createdAt":1,"updatedAt":2,
        "selection":{"provider":"claude","modelID":"retained","accountID":"account"},
        "modelPreferences":{"claude":{"effort":"high"}},"accessMode":"approval","interactionMode":"build",
        "sessions":["claude",{"sessionID":"live","seenItemCount":6}],
        "accountSessions":{"claude/account":{"sessionID":"other-live"}},
        "importedSession":{"sessionID":"imported-native","sourcePath":"/untouched/source"},
        "draft":"unsent source draft","draftContext":[{"kind":"source-only"}],
        "rustDraftImages":[{"id":"source-draft-image"}],"rustMessageQueue":[{"id":"queued","text":"do not replay"}],
        "rustQueueError":"source queue error","runningTurnID":U2,"pendingRequests":{"42":{"requestId":"provider-live"}},
        "isPinned":true,"isArchived":true,"snoozedUntil":9999,
        "worktreePath":"/existing/worktree","branch":"source-branch","futureThread":{"opaque":[1,2,3]},
        "items":[
            {"id":U1,"kind":"user","text":"First request","rustImages":[{"id":"stored-image","path":"/metadata-only/image.png","future":true}],"futureItem":{"keep":"yes"}},
            {"id":A1,"kind":"assistant","text":"First answer","externalID":"provider-item","userItemID":U1},
            {"id":STEER,"kind":"user","text":"Steered note","steered":true},
            {"id":TOOL,"kind":"tool","text":"Tool output","status":"completed","replyToItemID":A1},
            {"id":U2,"kind":"user","text":"Second request","context":[{"kind":"quote","unknown":{"keep":true}}],"rustImages":[{"id":"image-two","path":"/not-read/image.png"}],"attachments":["/legacy/not-read.png"]},
            {"id":A2,"kind":"assistant","text":"Second answer"}
        ]
    })
}

#[test]
fn branch_copies_whole_selected_turn_and_preserves_source_and_opaque_metadata() {
    let source = fixture();
    let before = source.clone();
    let plan = fork_through_turn(&source, Some(A1), options(None)).unwrap();
    assert_eq!(source, before);
    assert_eq!(plan.thread["items"].as_array().unwrap().len(), 4);
    assert_eq!(plan.thread["items"][2]["text"], "Steered note");
    assert_eq!(
        plan.thread["items"][0]["futureItem"],
        source["items"][0]["futureItem"]
    );
    assert_eq!(
        plan.thread["items"][0]["rustImages"],
        source["items"][0]["rustImages"]
    );
    assert_eq!(plan.thread["futureThread"], source["futureThread"]);
    for field in [
        "projectID",
        "selection",
        "modelPreferences",
        "accessMode",
        "interactionMode",
        "worktreePath",
        "branch",
    ] {
        assert_eq!(plan.thread[field], source[field]);
    }
    assert_eq!(plan.thread["id"], BRANCH);
    assert_eq!(plan.thread["createdAt"], 1234.5);
    assert_eq!(plan.thread["updatedAt"], 1234.5);
    assert_eq!(plan.lineage["parentThreadID"], SOURCE);
    assert_eq!(plan.lineage["parentItemID"], TOOL);
    assert_eq!(plan.lineage["forkItemID"], plan.thread["items"][3]["id"]);
    assert_eq!(plan.lineage["providerRewound"], false);
    assert_eq!(plan.lineage["filesRewound"], false);
    assert_eq!(plan.thread["rustHistory"], plan.lineage);
    for (old, new) in &plan.item_ids {
        assert_ne!(old, new);
        assert!(Uuid::parse_str(new).is_ok());
    }
    assert_eq!(plan.thread["items"][1]["userItemID"], plan.item_ids[U1]);
    assert_eq!(plan.thread["items"][3]["replyToItemID"], plan.item_ids[A1]);
}

#[test]
fn sessions_queues_pending_references_and_source_composer_do_not_leak_into_fork() {
    let plan = fork_through_turn(&fixture(), None, options(None)).unwrap();
    assert_eq!(plan.thread["sessions"], json!({}));
    assert_eq!(plan.thread["accountSessions"], json!({}));
    assert_eq!(plan.thread["rustMessageQueue"], json!([]));
    assert_eq!(plan.thread["draft"], "");
    assert_eq!(plan.thread["draftContext"], json!([]));
    assert_eq!(plan.thread["rustDraftImages"], json!([]));
    assert_eq!(plan.thread["isPinned"], false);
    assert_eq!(plan.thread["isArchived"], false);
    for key in [
        "pendingRequests",
        "runningTurnID",
        "importedSession",
        "snoozedUntil",
        "rustQueueError",
    ] {
        assert!(plan.thread.get(key).is_none(), "{key}");
    }
    assert!(plan.thread["items"][1].get("externalID").is_none());
}

#[test]
fn running_boundaries_exclude_the_live_turn_and_fail_closed_when_unknown() {
    let source = fixture();
    let plan = fork_through_turn(&source, None, options(Some(U2))).unwrap();
    assert_eq!(plan.thread["items"].as_array().unwrap().len(), 4);
    assert!(fork_through_turn(&source, Some(U2), options(Some(U2))).is_err());
    assert!(fork_through_turn(&source, Some(A2), options(Some(U2))).is_err());
    assert!(fork_through_turn(&source, None, options(Some(U1))).is_err());
    assert!(fork_through_turn(&source, None, options(Some(BRANCH))).is_err());
    assert!(fork_through_turn(&source, Some(BRANCH), options(None)).is_err());
    assert!(edit_from_user(&source, U1, options(Some(U2))).is_err());
}

#[test]
fn autonomous_notice_can_open_a_turn_without_treating_steering_as_a_new_turn() {
    let mut source = fixture();
    source["items"][4]["kind"] = json!("notice");
    let openers = vec![U2.to_owned()];
    let plan = fork_through_turn(
        &source,
        Some(STEER),
        HistoryOptions {
            turn_openers: &openers,
            ..options(None)
        },
    )
    .unwrap();
    assert_eq!(plan.thread["items"].as_array().unwrap().len(), 4);
    let without_opener = fork_through_turn(&source, Some(STEER), options(None)).unwrap();
    assert_eq!(without_opener.thread["items"].as_array().unwrap().len(), 6);
}

#[test]
fn pending_copies_become_terminal_and_keep_non_executable_history() {
    let mut source = fixture();
    source["items"][1]["status"] = json!("running");
    source["items"][3]["kind"] = json!("approval");
    source["items"][3]["status"] = json!("waiting");
    source["items"][3]["requestID"] = json!("live-request");
    source["items"][3]["approval"] =
        json!({"requestID":"native-rpc","command":"historical command","future":true});
    source["items"][5]["kind"] = json!("question");
    source["items"][5]["status"] = json!("pending");
    source["items"][5]["questions"] = json!({"requestId":"native-question","questions":[{"id":"question-one","text":"historical question"}]});
    let plan = fork_through_turn(&source, None, options(None)).unwrap();
    assert_eq!(plan.thread["items"][1]["status"], "failed");
    assert_eq!(plan.thread["items"][3]["status"], "declined");
    assert_eq!(plan.thread["items"][5]["status"], "declined");
    assert_eq!(plan.thread["items"][3]["completedAt"], 1234.5);
    assert!(plan.thread["items"][3].get("requestID").is_none());
    assert!(
        plan.thread["items"][3]["approval"]
            .get("requestID")
            .is_none()
    );
    assert_eq!(
        plan.thread["items"][3]["approval"]["command"],
        "historical command"
    );
    assert!(
        plan.thread["items"][5]["questions"]
            .get("requestId")
            .is_none()
    );
    assert_eq!(
        plan.thread["items"][5]["questions"]["questions"][0]["id"],
        "question-one"
    );
}

#[test]
fn edit_branch_restores_selected_user_draft_images_context_and_inert_legacy_paths() {
    let source = fixture();
    let before = source.clone();
    let plan = edit_from_user(&source, U2, options(None)).unwrap();
    assert_eq!(source, before);
    assert_eq!(plan.thread["items"].as_array().unwrap().len(), 4);
    assert_eq!(plan.thread["draft"], "Second request");
    assert_eq!(plan.thread["draftContext"], source["items"][4]["context"]);
    assert_eq!(
        plan.thread["rustDraftImages"],
        source["items"][4]["rustImages"]
    );
    assert_eq!(
        plan.thread["rustLegacyDraftAttachments"],
        source["items"][4]["attachments"]
    );
    assert_eq!(plan.lineage["editedItemID"], U2);
    assert_eq!(plan.lineage["mode"], "edit-draft-branch");
    assert!(!plan.item_ids.contains_key(U2));
    assert_eq!(
        edit_from_user(&source, U1, options(None)).unwrap().thread["items"],
        json!([])
    );
    assert!(edit_from_user(&source, A1, options(None)).is_err());
}

#[test]
fn malformed_ids_ambiguous_items_nonfinite_time_and_bad_draft_metadata_are_rejected() {
    let source = fixture();
    assert!(
        fork_through_turn(
            &source,
            None,
            HistoryOptions {
                new_thread_id: SOURCE,
                ..options(None)
            }
        )
        .is_err()
    );
    assert!(
        fork_through_turn(
            &source,
            None,
            HistoryOptions {
                now: f64::NAN,
                ..options(None)
            }
        )
        .is_err()
    );
    let mut malformed = source.clone();
    malformed["items"][1]["id"] = json!(U1);
    assert!(fork_through_turn(&malformed, None, options(None)).is_err());
    malformed = source.clone();
    malformed["items"][0]["id"] = json!("invalid");
    assert!(fork_through_turn(&malformed, None, options(None)).is_err());
    malformed = source.clone();
    malformed["items"][4]["rustImages"] = json!("invalid");
    assert!(edit_from_user(&malformed, U2, options(None)).is_err());
    malformed = source;
    malformed["items"] = json!([]);
    assert!(fork_through_turn(&malformed, None, options(None)).is_err());
}
