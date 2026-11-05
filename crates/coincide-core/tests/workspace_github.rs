use coincide_core::workspace_github::parse_snapshot;
use serde_json::{Value, json};
fn fixture() -> Value {
    json!({"number":42,"title":"Fixture PR","url":"https://github.com/fixture/repo/pull/42","state":"OPEN","isDraft":false,"headRefOid":"a".repeat(40),"headRefName":"feature/test","baseRefName":"main","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","reviews":[{"id":"review1","state":"APPROVED","body":"Reviewed fixture","author":{"login":"fixture"},"commit":{"oid":"a".repeat(40)}}],"statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","state":"SUCCESS"}]})
}
#[test]
fn exact_head_preflight_and_reviews() {
    let pr = parse_snapshot(&serde_json::to_vec(&fixture()).unwrap()).unwrap();
    assert_eq!(pr.reviews[0].body, "Reviewed fixture");
    assert_eq!(pr.preflight(&"a".repeat(40)).unwrap()["eligible"], true);
    assert_eq!(pr.preflight(&"b".repeat(40)).unwrap()["eligible"], false);
    assert!(pr.preflight("main").is_err());
}
#[test]
fn incomplete_failed_and_stale_snapshots_fail_closed() {
    for (field, value) in [
        ("state", json!("MERGED")),
        ("isDraft", json!(true)),
        ("mergeable", json!("UNKNOWN")),
        ("mergeStateStatus", json!("BLOCKED")),
        ("reviewDecision", json!("CHANGES_REQUESTED")),
        ("statusCheckRollup", json!([])),
        (
            "statusCheckRollup",
            json!([{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":"SUCCESS"}]),
        ),
        (
            "statusCheckRollup",
            json!([{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]),
        ),
        (
            "statusCheckRollup",
            json!([{"__typename":"FutureCheck","state":"SUCCESS"}]),
        ),
    ] {
        let mut v = fixture();
        v[field] = value;
        let pr = parse_snapshot(&serde_json::to_vec(&v).unwrap()).unwrap();
        assert_eq!(
            pr.preflight(&"a".repeat(40)).unwrap()["eligible"],
            false,
            "{field}"
        );
    }
    for url in [
        "https://github.com/fixture/repo/pull/43",
        "https://evil.example/fixture/repo/pull/42",
        "https://token@github.com/fixture/repo/pull/42",
    ] {
        let mut v = fixture();
        v["url"] = json!(url);
        assert!(parse_snapshot(&serde_json::to_vec(&v).unwrap()).is_err());
    }
    let mut v = fixture();
    v.as_object_mut().unwrap().remove("statusCheckRollup");
    assert!(parse_snapshot(&serde_json::to_vec(&v).unwrap()).is_err());
}
