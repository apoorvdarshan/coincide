//! Public registration smoke test; lifecycle and Git cases use the real Engine
//! in api::workspace_runtime_tests so no duplicate dispatcher can hide drift.
use coincide_core::{api::Engine, store::Store};
use serde_json::json;

#[test]
fn workspace_methods_are_publicly_advertised_and_dispatched() {
    let root = tempfile::tempdir().unwrap();
    let mut engine = Engine::new(Store::open(&root.path().join("store.sqlite")).unwrap());
    let response = engine.dispatch(json!({"method":"app.capabilities","params":{}}));
    let capabilities = response["result"].as_array().unwrap();
    for method in [
        "git.checkpoints.create",
        "git.checkpoints.list",
        "git.checkpoints.diff",
        "git.worktrees.reserve",
        "git.worktrees.list",
        "git.workspace.result",
    ] {
        assert_eq!(
            capabilities
                .iter()
                .filter(|value| **value == method)
                .count(),
            1
        );
        let response = engine.dispatch(json!({"method":method,"params":{}}));
        let error = response["error"]["message"].as_str().unwrap();
        assert!(error.contains("threadId"), "{method}: {error}");
    }
}
