use coincide_core::browser_protocol::{BrowserRequest, DownloadRegistry, download_filename};
use serde_json::Value;
use std::{fs, path::Path};
use uuid::Uuid;

fn ids() -> (String, String) {
    (Uuid::new_v4().to_string(), Uuid::new_v4().to_string())
}
fn state(registry: &DownloadRegistry, thread: &str, index: usize) -> Value {
    registry.list(thread, None)["downloads"][index].clone()
}

#[test]
fn download_request_is_typed_and_filenames_cannot_escape() {
    let (thread, _) = ids();
    let request: BrowserRequest = serde_json::from_value(serde_json::json!({
        "id":"fixture","threadId":thread,"action":"downloads"
    }))
    .unwrap();
    request.validate().unwrap();
    assert_eq!(download_filename("../../report.csv"), "report.csv");
    assert_eq!(download_filename(r"C:\private\report.csv"), "report.csv");
    assert_eq!(download_filename(".."), "download");
    assert_eq!(download_filename("CON.txt"), "_CON.txt");
    assert_eq!(download_filename("lpt9"), "_lpt9");
    assert_eq!(download_filename("a\u{202e}\n:b?.txt. "), "ab.txt");
    let unicode = download_filename(&"界".repeat(100));
    assert_eq!(unicode.len(), 180);
}

#[test]
fn downloads_have_private_unique_destinations_and_publish_only_verified_paths() {
    let temp = tempfile::tempdir().unwrap();
    let mut registry = DownloadRegistry::new(temp.path().join("downloads")).unwrap();
    let (thread, tab) = ids();
    let url = "https://example.test/file";
    let path = registry
        .start(&thread, &tab, url, Path::new("../../file.txt"))
        .unwrap();
    assert_eq!(path.file_name().unwrap(), "file.txt");
    assert_eq!(
        path.parent().unwrap().parent().unwrap(),
        temp.path().join("downloads").canonicalize().unwrap()
    );
    assert!(
        Uuid::parse_str(
            path.parent()
                .unwrap()
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
        )
        .is_ok()
    );
    assert_eq!(state(&registry, &thread, 0)["state"], "downloading");
    assert!(state(&registry, &thread, 0).get("path").is_none());
    fs::write(&path, b"fixture").unwrap();
    registry.complete(&thread, &tab, url, None, true);
    assert_eq!(state(&registry, &thread, 0)["state"], "finished");
    assert_eq!(state(&registry, &thread, 0)["path"], path.to_str().unwrap());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(path.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
    }
    let next = registry
        .start(&thread, &tab, url, Path::new("file.txt"))
        .unwrap();
    assert_ne!(path, next);
    assert_eq!(fs::read(path).unwrap(), b"fixture");
    assert!(
        registry.list(&Uuid::new_v4().to_string(), None)["downloads"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(
        registry.list(&thread, Some(&Uuid::new_v4().to_string()))["downloads"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}

#[test]
fn duplicate_cancellation_before_or_after_success_never_fails_accepted_download() {
    for cancellation_first in [true, false] {
        let temp = tempfile::tempdir().unwrap();
        let mut registry = DownloadRegistry::new(temp.path().join("downloads")).unwrap();
        let (thread, tab) = ids();
        let url = "https://example.test/file";
        let path = registry
            .start(&thread, &tab, url, Path::new("file"))
            .unwrap();
        assert!(
            registry
                .start(&thread, &tab, url, Path::new("duplicate"))
                .is_err()
        );
        if cancellation_first {
            registry.complete(&thread, &tab, url, None, false);
            assert_eq!(state(&registry, &thread, 0)["state"], "downloading");
        }
        fs::write(&path, b"fixture").unwrap();
        registry.complete(&thread, &tab, url, None, true);
        assert_eq!(state(&registry, &thread, 0)["state"], "finished");
        if !cancellation_first {
            assert_eq!(
                registry.list(&thread, None)["pendingCancellationCallbacks"],
                1
            );
            registry.complete(&thread, &tab, url, None, false);
        }
        assert_eq!(state(&registry, &thread, 0)["state"], "finished");
        assert_eq!(
            registry.list(&thread, None)["pendingCancellationCallbacks"],
            0
        );
        assert!(
            registry
                .start(&thread, &tab, url, Path::new("retry"))
                .is_ok()
        );
    }
}

#[test]
fn failed_missing_or_mismatched_files_never_publish_paths() {
    let temp = tempfile::tempdir().unwrap();
    let mut registry = DownloadRegistry::new(temp.path().join("downloads")).unwrap();
    let (thread, tab) = ids();
    let url = "https://example.test/file";
    let path = registry
        .start(&thread, &tab, url, Path::new("file"))
        .unwrap();
    registry.complete(&thread, &tab, url, Some(&temp.path().join("unowned")), true);
    assert_eq!(state(&registry, &thread, 0)["state"], "downloading");
    registry.complete(&thread, &tab, url, Some(&path), true);
    assert_eq!(state(&registry, &thread, 0)["state"], "failed");
    assert!(state(&registry, &thread, 0).get("path").is_none());
    let path = registry
        .start(&thread, &tab, url, Path::new("file"))
        .unwrap();
    fs::write(&path, b"partial").unwrap();
    registry.complete(&thread, &tab, url, Some(&path), false);
    assert_eq!(state(&registry, &thread, 1)["state"], "failed");
    assert!(state(&registry, &thread, 1).get("path").is_none());
    assert_eq!(fs::read(path).unwrap(), b"partial");
}

#[test]
fn closure_is_unconfirmed_until_native_completion_and_does_not_guess_cancellation() {
    let temp = tempfile::tempdir().unwrap();
    let mut registry = DownloadRegistry::new(temp.path().join("downloads")).unwrap();
    let (thread, tab) = ids();
    let url = "https://example.test/file";
    let path = registry
        .start(&thread, &tab, url, Path::new("file"))
        .unwrap();
    registry.tab_closed(&thread, &tab);
    assert_eq!(state(&registry, &thread, 0)["state"], "unconfirmed");
    assert!(state(&registry, &thread, 0).get("path").is_none());
    fs::write(&path, b"fixture").unwrap();
    registry.complete(&thread, &tab, url, None, true);
    assert_eq!(state(&registry, &thread, 0)["state"], "finished");
}

#[test]
fn active_transfers_and_retained_history_are_bounded() {
    let temp = tempfile::tempdir().unwrap();
    let mut registry = DownloadRegistry::new(temp.path().join("downloads")).unwrap();
    let (thread, tab) = ids();
    for index in 0..8 {
        registry
            .start(
                &thread,
                &tab,
                &format!("https://example.test/{index}"),
                Path::new("file"),
            )
            .unwrap();
    }
    assert!(
        registry
            .start(
                &thread,
                &tab,
                "https://example.test/ninth",
                Path::new("file")
            )
            .is_err()
    );
    for index in 0..8 {
        registry.complete(
            &thread,
            &tab,
            &format!("https://example.test/{index}"),
            None,
            false,
        );
    }
    registry.complete(&thread, &tab, "https://example.test/ninth", None, false);
    for index in 8..60 {
        let url = format!("https://example.test/{index}");
        registry
            .start(&thread, &tab, &url, Path::new("file"))
            .unwrap();
        registry.complete(&thread, &tab, &url, None, false);
    }
    assert_eq!(
        registry.list(&thread, None)["downloads"]
            .as_array()
            .unwrap()
            .len(),
        50
    );
    assert_eq!(
        registry.list(&thread, None)["pendingCancellationCallbacks"],
        0
    );
}

#[test]
fn refusals_are_visible_without_request_url_or_other_thread_details() {
    let temp = tempfile::tempdir().unwrap();
    let mut registry = DownloadRegistry::new(temp.path().join("downloads")).unwrap();
    let (thread, tab) = ids();
    let url = "https://example.test/private-document?secret=fixture-only";
    registry
        .start(&thread, &tab, url, Path::new("file"))
        .unwrap();
    assert!(
        registry
            .start(&thread, &tab, url, Path::new("file"))
            .is_err()
    );
    let result = registry.list(&thread, None);
    assert!(
        result["lastError"]
            .as_str()
            .unwrap()
            .contains("active download")
    );
    assert!(!result.to_string().contains("private-document"));
    assert!(!result.to_string().contains("fixture-only"));
    assert!(registry.list(&Uuid::new_v4().to_string(), None)["lastError"].is_null());
    assert!(
        registry
            .start(
                &thread,
                &tab,
                "blob:https://example.test/private-document",
                Path::new("file")
            )
            .is_err()
    );
    assert!(
        registry.list(&thread, None)["lastError"]
            .as_str()
            .unwrap()
            .contains("HTTP")
    );
}

#[cfg(unix)]
#[test]
fn symlink_destinations_and_roots_are_rejected_without_touching_target() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let temp = tempfile::tempdir().unwrap();
    let external = temp.path().join("external");
    fs::write(&external, b"untouched").unwrap();
    fs::set_permissions(&external, fs::Permissions::from_mode(0o644)).unwrap();
    let mut registry = DownloadRegistry::new(temp.path().join("downloads")).unwrap();
    let (thread, tab) = ids();
    let url = "https://example.test/file";
    let path = registry
        .start(&thread, &tab, url, Path::new("file"))
        .unwrap();
    symlink(&external, &path).unwrap();
    registry.complete(&thread, &tab, url, None, true);
    assert_eq!(state(&registry, &thread, 0)["state"], "failed");
    assert!(state(&registry, &thread, 0).get("path").is_none());
    assert_eq!(
        fs::metadata(&external).unwrap().permissions().mode() & 0o777,
        0o644
    );
    assert_eq!(fs::read(&external).unwrap(), b"untouched");
    let link = temp.path().join("linked-root");
    symlink(temp.path().join("downloads"), &link).unwrap();
    assert!(DownloadRegistry::new(link).is_err());
}
