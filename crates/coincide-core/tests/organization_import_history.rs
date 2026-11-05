use coincide_core::{cli_session_import::*, organization::*, usage_history::*};
use serde_json::{json, Value};
use uuid::Uuid;
const ID: &str = "00000000-0000-4000-8000-000000000001";
fn rollout(records: Vec<Value>) -> Vec<u8> {
    records
        .into_iter()
        .map(|r| r.to_string())
        .collect::<Vec<_>>()
        .join("\n")
        .into_bytes()
}
fn meta() -> Value {
    json!({"type":"session_meta","payload":{"id":ID,"cwd":"/synthetic","future":true}})
}
fn msg(role: &str, text: &str) -> Value {
    json!({"type":"response_item","payload":{"type":"message","role":role,"content":[{"type":"output_text","text":text}]}})
}
#[test]
fn organization_rename_preserves_original_and_future_fields() {
    let bytes = format!(
        r#"[ {{"id":"{ID}","name":"Old","future":{{"nested":7}},"selection":{{"new":true}}}} ]"#
    )
    .into_bytes();
    let mut records = Records::parse(&bytes).unwrap();
    records
        .rename_bot(Uuid::parse_str(ID).unwrap(), " New ")
        .unwrap();
    assert_eq!(records.original(), bytes);
    let working: Value = serde_json::from_slice(&records.working_bytes().unwrap()).unwrap();
    assert_eq!(working[0]["name"], "New");
    assert_eq!(working[0]["future"]["nested"], 7);
    assert_eq!(working[0]["selection"]["new"], true);
    assert!(records.rename_bot(Uuid::nil(), "Missing").is_err());
}
#[test]
fn invalid_organization_and_instruction_sources_are_rejected() {
    assert!(Records::parse(b"{}").is_err());
    assert!(Records::parse(b"[{\"id\":\"bad\"}]").is_err());
    assert!(Records::parse(&serde_json::to_vec(&json!([{"id":ID},{"id":ID}])).unwrap()).is_err());
    assert!(InstructionSnapshot::parse(&[255]).is_err());
    let bytes = b"# Instructions\r\nUnknown content\n";
    assert_eq!(InstructionSnapshot::parse(bytes).unwrap().original(), bytes);
    assert!(InstructionSnapshot::parse(&vec![b'a'; 1_048_577]).is_err());
}
#[test]
fn codex_rollbacks_and_source_changes_are_visible() {
    let bytes = rollout(vec![
        meta(),
        msg("user", "first"),
        msg("assistant", "answer"),
        msg("user", "second"),
        json!({"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}),
        json!({"type":"unknown","secretFutureField":"synthetic"}),
    ]);
    let preview = preview_codex(&bytes).unwrap();
    assert_eq!(preview.messages.len(), 2);
    assert_eq!(preview.omitted_records, 1);
    assert!(preview.matches_source(&bytes));
    assert!(!preview.matches_source(b"changed"));
    assert_eq!(preview.original(), bytes);
}
#[test]
fn codex_rejects_mixed_identity_and_oversize_records() {
    let mut other = meta();
    other["payload"]["id"] = json!(Uuid::nil().to_string());
    assert!(preview_codex(&rollout(vec![meta(), other, msg("user", "hello")])).is_err());
    assert!(preview_codex(&vec![b'a'; MAX_RECORD_BYTES + 1]).is_err());
    assert!(preview_codex(&rollout(vec![
        meta(),
        json!({"sessionId": ID}),
        msg("user", "hello")
    ]))
    .is_err());
    assert!(preview_codex(&rollout(vec![meta()])).is_err());
}
#[test]
fn codex_prefers_response_messages_and_bounds_unicode_text() {
    let text = "🦀".repeat(MAX_TEXT + 1);
    let bytes = rollout(vec![
        meta(),
        json!({"type":"event_msg","payload":{"type":"user_message","message":text}}),
        msg("user", &text),
    ]);
    let preview = preview_codex(&bytes).unwrap();
    assert_eq!(preview.messages.len(), 1);
    assert!(preview.shortened_text);
    assert_eq!(preview.messages[0].text.chars().count(), MAX_TEXT + 2);
}
#[test]
fn history_sums_only_turn_totals_and_retains_snapshots() {
    let bytes = serde_json::to_vec(&json!([
        {"id":ID,"provider":"codex","finishedAt":"2026-11-05T10:00:00Z","usage":{"inputTokens":99999,"costUSD":99}},
        {"id":Uuid::nil().to_string(),"provider":"claude","finishedAt":"2026-11-05T10:00:00Z","usage":{"turnTotals":{"input":4,"cacheRead":3,"cacheWrite":2,"cacheWriteLong":2,"output":5,"reasoning":3},"future":true}}
    ])).unwrap();
    let history = UsageHistory::parse(&bytes).unwrap();
    assert_eq!(history.original(), bytes);
    assert_eq!(history.turn_totals(&HistoryFilter::default()).total(), 14);
    assert_eq!(
        history
            .turn_totals(&HistoryFilter {
                provider: Some("codex"),
                ..Default::default()
            })
            .total(),
        0
    );
    assert!(history
        .filtered(&HistoryFilter {
            since: Some("2027-01-01T00:00:00Z".parse().unwrap()),
            ..Default::default()
        })
        .is_empty());
}
#[test]
fn limits_update_keeps_unknown_fields_and_omitted_reset() {
    let old = vec![
        json!({"id":"weekly","usedPercent":10,"resetsAt":"later","future":7}),
        json!({"id":"session","usedPercent":3}),
    ];
    let result = merge_limit_windows(
        &old,
        &[json!({"id":"weekly","usedPercent":20,"resetsAt":null})],
    )
    .unwrap();
    assert_eq!(result.len(), 2);
    assert_eq!(result[0]["resetsAt"], "later");
    assert_eq!(result[0]["future"], 7);
    assert_eq!(result[0]["usedPercent"], 20);
    assert!(merge_limit_windows(&old, &[json!({"usedPercent":20})]).is_err());
}

fn event(role: &str, text: &str) -> Value {
    json!({"type":"event_msg","payload":{"type":if role == "user" {"user_message"} else {"agent_message"},"message":text}})
}
#[test]
fn codex_mixed_formats_keep_old_turns_pair_duplicates_and_rollback() {
    let bytes = rollout(vec![
        meta(),
        event("user", "old"),
        event("assistant", "old answer"),
        event("user", "new"),
        msg("user", "new"),
        msg("assistant", "answer"),
        event("assistant", "answer"),
        event("user", "rolled back"),
        msg("user", "rolled back"),
        json!({"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}),
        msg("user", "new"),
        event("user", "new"),
    ]);
    let preview = preview_codex(&bytes).unwrap();
    assert_eq!(
        preview
            .messages
            .iter()
            .map(|m| m.text.as_str())
            .collect::<Vec<_>>(),
        ["old", "old answer", "new", "answer", "new"]
    );
}
#[test]
fn codex_same_encoding_repeated_prompts_are_retained() {
    let preview = preview_codex(&rollout(vec![
        meta(),
        event("user", "again"),
        event("user", "again"),
        msg("assistant", "ok"),
    ]))
    .unwrap();
    assert_eq!(preview.messages.len(), 3);
}

fn claude(id: &str, parent: Option<&str>, role: &str, content: Value) -> Value {
    json!({"sessionId":ID,"cwd":"/synthetic","uuid":id,"parentUuid":parent,
        "type":role,"message":{"role":role,"content":content,"model":"synthetic-model"},"future":{"preserved":true}})
}
#[test]
fn claude_selects_latest_ancestry_and_counts_unsupported_content() {
    let mut sidechain = claude("side", None, "assistant", json!("sidechain"));
    sidechain["isSidechain"] = json!(true);
    let bytes = rollout(vec![
        claude("root", None, "user", json!("question")),
        claude("stale", Some("root"), "assistant", json!("stale branch")),
        sidechain,
        claude(
            "latest",
            Some("root"),
            "assistant",
            json!([
            {"type":"text","text":"answer"},{"type":"thinking","thinking":"private"},
            {"type":"tool_use","name":"fake","input":{}},{"type":"image","source":{}}]),
        ),
    ]);
    let preview = preview_claude(&bytes).unwrap();
    assert_eq!(preview.provider, ImportProvider::Claude);
    assert_eq!(
        preview
            .messages
            .iter()
            .map(|m| m.text.as_str())
            .collect::<Vec<_>>(),
        ["question", "answer"]
    );
    assert_eq!(preview.omitted_records, 5);
    assert_eq!(preview.model.as_deref(), Some("synthetic-model"));
    assert_eq!(preview.original(), bytes);
}
#[test]
fn claude_rejects_cycles_incomplete_chains_and_mixed_sessions() {
    assert!(preview_claude(&rollout(vec![
        claude("a", Some("b"), "user", json!("a")),
        claude("b", Some("a"), "assistant", json!("b"))
    ]))
    .is_err());
    assert!(preview_claude(&rollout(vec![claude(
        "a",
        Some("missing"),
        "user",
        json!("a")
    )]))
    .is_err());
    let mut other = claude("b", None, "assistant", json!("b"));
    other["sessionId"] = json!(Uuid::nil().to_string());
    assert!(preview_claude(&rollout(vec![claude("a", None, "user", json!("a")), other])).is_err());
    assert!(preview_claude(&rollout(vec![
        meta(),
        claude("a", None, "user", json!("a"))
    ]))
    .is_err());
}
#[test]
fn claude_last_revision_wins_and_unicode_is_bounded() {
    let bytes = rollout(vec![
        claude("a", None, "user", json!("old")),
        claude("a", None, "user", json!("🦀".repeat(MAX_TEXT + 1))),
    ]);
    let preview = preview_claude(&bytes).unwrap();
    assert_eq!(preview.messages.len(), 1);
    assert_eq!(preview.omitted_records, 1);
    assert!(preview.shortened_text);
    assert_eq!(preview.messages[0].text.chars().count(), MAX_TEXT + 2);
    assert!(preview_claude(&vec![b'a'; MAX_RECORD_BYTES + 1]).is_err());
}

#[test]
fn codex_unknown_blocks_with_text_are_omitted_not_rendered() {
    let mut record = msg("user", "visible");
    record["payload"]["content"]
        .as_array_mut()
        .unwrap()
        .push(json!({"type":"future_tool","text":"unsupported"}));
    let preview = preview_codex(&rollout(vec![meta(), record])).unwrap();
    assert_eq!(preview.messages[0].text, "visible");
    assert_eq!(preview.omitted_records, 1);
}
#[test]
fn codex_response_identity_can_reappear_after_rollback() {
    let mut record = msg("user", "replayed");
    record["payload"]["id"] = json!("message-one");
    let bytes = rollout(vec![
        meta(),
        msg("user", "kept"),
        record.clone(),
        json!({"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}),
        record,
    ]);
    let preview = preview_codex(&bytes).unwrap();
    assert_eq!(
        preview
            .messages
            .iter()
            .map(|m| m.text.as_str())
            .collect::<Vec<_>>(),
        ["kept", "replayed"]
    );
}
#[test]
fn previews_bound_record_count_and_preserve_malformed_original_bytes() {
    assert!(preview_codex(&vec![b'\n'; MAX_RECORDS + 1]).is_err());
    assert!(preview_claude(&vec![b'\n'; MAX_RECORDS + 1]).is_err());
    let mut bytes = rollout(vec![meta(), msg("user", "supported")]);
    bytes.extend_from_slice(b"\n{broken}\n[]\n");
    let preview = preview_codex(&bytes).unwrap();
    assert_eq!(preview.omitted_records, 2);
    assert_eq!(preview.original(), bytes);
    let mut bytes = rollout(vec![claude("root", None, "user", json!("supported"))]);
    bytes.extend_from_slice(b"\n{broken}\n[]\n");
    let preview = preview_claude(&bytes).unwrap();
    assert_eq!(preview.omitted_records, 2);
    assert_eq!(preview.original(), bytes);
}
