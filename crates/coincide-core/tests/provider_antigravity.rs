#![cfg(unix)]

use coincide_core::agent::{Event, Launch, Provider, Session};
use std::{fs, os::unix::fs::PermissionsExt, time::Duration};

#[test]
fn legacy_login_is_rejected_before_starting_a_process_or_touching_its_data() {
    let root = tempfile::tempdir().unwrap();
    let original = root.path().join("original/antigravity-acp");
    fs::create_dir_all(&original).unwrap();
    let token = original.join("acp_token.json");
    fs::write(&token, b"private legacy account data").unwrap();
    let executable = root.path().join("runtime");
    fs::write(&executable, b"#!/bin/sh\ntouch spawned\n").unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let target = root.path().join("private-profile");
    let session = Session::start_with(
        Provider::Antigravity {
            profile: Some(target.clone()),
            source_profile: Some(root.path().join("original")),
            risk_acknowledged: true,
        },
        Launch {
            executable,
            cwd: root.path().into(),
            session: None,
            prompt: "should never be sent".into(),
            model: None,
            variant: None,
            full_access: false,
        },
    );
    let result = session.events.recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(matches!(result, Event::Failed(error) if error.contains("API-key")));
    assert!(!root.path().join("spawned").exists());
    assert!(!target.exists());
    assert_eq!(fs::read(token).unwrap(), b"private legacy account data");
}
