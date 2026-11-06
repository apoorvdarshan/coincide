use coincide_core::browser_protocol::{BrowserRequest, script_for_request};
use serde_json::{Value, json};
use std::fs;

fn request(files: Value) -> BrowserRequest {
    serde_json::from_value(json!({"id":"upload-test","threadId":uuid::Uuid::new_v4().to_string(),"action":"upload","selector":"#file","files":files})).unwrap()
}
#[cfg(not(windows))]
fn payload(source: &str) -> Value {
    serde_json::from_str(
        source
            .split_once("const request = ")
            .unwrap()
            .1
            .split_once("; const frameId")
            .unwrap()
            .0,
    )
    .unwrap()
}

#[cfg(not(windows))]
#[test]
fn upload_encodes_exact_bytes_and_filename_without_parent_path() {
    let dir = tempfile::tempdir().unwrap();
    let name = if cfg!(windows) {
        "quoted界.txt"
    } else {
        "quoted\"界.txt"
    };
    let file = dir.path().join(name);
    fs::write(&file, [0, 255, 10, 65]).unwrap();
    let mut req = request(json!([file]));
    req.frame = Some("frame-fixture".into());
    let source = script_for_request(&req).unwrap().unwrap();
    let data = payload(&source);
    assert_eq!(
        data["files"][0],
        json!({"name":name,"mime":"text/plain","data":"AP8KQQ=="})
    );
    assert!(!source.contains(dir.path().to_str().unwrap()));
    assert!(source.contains("const frameId = \"frame-fixture\""));
    assert_eq!(fs::read(file).unwrap(), [0, 255, 10, 65]);
}

#[test]
fn upload_validation_does_not_read_files_and_rejects_invalid_paths_or_counts() {
    let absent = std::env::temp_dir().join(uuid::Uuid::new_v4().to_string());
    let req = request(json!([absent]));
    req.validate().unwrap();
    assert!(script_for_request(&req).is_err());
    for files in [
        json!([]),
        json!(["relative.txt"]),
        json!(["/tmp/../secret"]),
        json!(["/tmp/x\u{0000}y"]),
        json!(vec!["/tmp/file"; 9]),
    ] {
        assert!(request(files).validate().is_err());
    }
}

#[cfg(not(windows))]
#[test]
fn upload_rejects_directories_and_total_size_overflow_but_accepts_empty_files() {
    let dir = tempfile::tempdir().unwrap();
    assert!(script_for_request(&request(json!([dir.path()]))).is_err());
    let first = dir.path().join("first.bin");
    let second = dir.path().join("second.bin");
    fs::write(&first, []).unwrap();
    let source = script_for_request(&request(json!([first])))
        .unwrap()
        .unwrap();
    assert_eq!(payload(&source)["files"][0]["data"], "");
    fs::File::create(&first)
        .unwrap()
        .set_len(4 * 1024 * 1024)
        .unwrap();
    fs::write(&second, [1]).unwrap();
    assert!(script_for_request(&request(json!([first, second]))).is_err());
    fs::File::create(&second)
        .unwrap()
        .set_len(4 * 1024 * 1024 + 1)
        .unwrap();
    assert!(script_for_request(&request(json!([second]))).is_err());
}

#[cfg(unix)]
#[test]
fn upload_refuses_symlinks_and_named_pipes_without_blocking() {
    use std::{
        ffi::CString,
        os::unix::{ffi::OsStrExt, fs::symlink},
    };
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("file.txt");
    let link = dir.path().join("link.txt");
    fs::write(&file, b"private").unwrap();
    symlink(&file, &link).unwrap();
    assert!(script_for_request(&request(json!([link]))).is_err());
    let fifo = dir.path().join("fifo");
    let path = CString::new(fifo.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    assert!(script_for_request(&request(json!([fifo]))).is_err());
}

#[test]
fn upload_cancelled_and_expired_work_never_reads_files() {
    use coincide_core::browser_protocol::{
        prepare_upload_script, upload::UploadWork, upload_probe_script,
    };
    use std::time::Duration;
    let file = std::env::temp_dir().join(uuid::Uuid::new_v4().to_string());
    let request = request(json!([file]));
    assert!(
        upload_probe_script(&request, "test-ticket")
            .unwrap()
            .contains("upload-probe")
    );
    let work = UploadWork::new(Duration::from_secs(10));
    work.cancel();
    assert!(work.check().unwrap_err().to_string().contains("cancelled"));
    assert!(prepare_upload_script(&request, "test-ticket", &work).is_err());
    let expired = UploadWork::new(Duration::ZERO);
    assert!(
        expired
            .check()
            .unwrap_err()
            .to_string()
            .contains("timed out")
    );
}

#[test]
fn cancelled_stalled_workers_keep_their_slots_until_they_exit() {
    use coincide_core::browser_protocol::upload::{UploadSlots, UploadWork};
    use std::{sync::mpsc, time::Duration};
    let slots = UploadSlots::default();
    let first = slots.reserve().unwrap();
    let second = slots.reserve().unwrap();
    let work = UploadWork::new(Duration::from_secs(10));
    let (release, blocked) = mpsc::channel();
    let worker = std::thread::spawn(move || {
        let _permit = first;
        blocked.recv().unwrap();
    });
    work.cancel();
    assert!(slots.reserve().is_err());
    release.send(()).unwrap();
    worker.join().unwrap();
    let replacement = slots.reserve().unwrap();
    assert!(slots.reserve().is_err());
    drop(second);
    drop(replacement);
    assert!(slots.reserve().is_ok());
}

#[cfg(windows)]
#[test]
fn windows_uploads_fail_closed_before_opening_paths() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("file.txt");
    fs::write(&file, b"fixture").unwrap();
    let error = script_for_request(&request(json!([file])))
        .unwrap_err()
        .to_string();
    assert!(error.contains("disabled on Windows"));
}
