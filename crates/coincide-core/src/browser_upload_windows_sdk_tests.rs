//! Explicit ignored fresh-GHA filesystem tests. Never run on the author's Windows session.
use super::*;
use std::{
    fs,
    io::{Read, Seek, Write},
    sync::{Arc, Barrier},
    time::Duration,
};
use windows_sys::Win32::{
    Foundation::GENERIC_WRITE,
    System::{
        IO::DeviceIoControl, Ioctl::FSCTL_SET_REPARSE_POINT,
        SystemServices::IO_REPARSE_TAG_MOUNT_POINT,
    },
};
fn root() -> tempfile::TempDir {
    assert_eq!(std::env::var("GITHUB_ACTIONS").as_deref(), Ok("true"));
    assert_eq!(
        std::env::var("RUNNER_ENVIRONMENT").as_deref(),
        Ok("github-hosted")
    );
    assert_eq!(
        std::env::var("COINCIDE_SYNTHETIC_UPLOAD_SDK").as_deref(),
        Ok("1")
    );
    let runner =
        std::fs::canonicalize(std::env::var_os("RUNNER_TEMP").expect("owned runner temp required"))
            .unwrap();
    let temp = tempfile::Builder::new()
        .prefix("owned-upload-sdk-")
        .tempdir_in(&runner)
        .unwrap();
    assert_eq!(
        temp.path().canonicalize().unwrap().parent(),
        Some(runner.as_path())
    );
    crate::private_fs::windows::create_directory(&temp.path().join("private")).unwrap();
    temp
}
fn private_file(path: &Path, bytes: &[u8]) {
    let mut file = crate::private_fs::windows::open_file(path, true).unwrap();
    file.write_all(bytes).unwrap();
}
fn work() -> UploadWork {
    UploadWork::new(Duration::from_secs(10))
}
/// SDK-generated junction, only between two exact owned fixture paths. No shell,
/// privilege adjustments, default ACL changes or user-selected IOCTL payloads.
fn junction(link: &Path, target: &Path) -> Result<()> {
    fs::create_dir(link)?;
    let target = target.canonicalize()?;
    let printable = target
        .to_str()
        .context("owned Unicode target")?
        .strip_prefix(r"\\?\")
        .context("owned local canonical target")?;
    let substitute = format!(r"\??\{printable}")
        .encode_utf16()
        .collect::<Vec<_>>();
    let printable = printable.encode_utf16().collect::<Vec<_>>();
    let data_len = 8 + 2 * (substitute.len() + 1 + printable.len() + 1);
    let mut buffer = Vec::with_capacity(8 + data_len);
    buffer.extend_from_slice(&IO_REPARSE_TAG_MOUNT_POINT.to_le_bytes());
    buffer.extend_from_slice(&u16::try_from(data_len)?.to_le_bytes());
    buffer.extend_from_slice(&0u16.to_le_bytes());
    for value in [
        0,
        substitute.len() * 2,
        (substitute.len() + 1) * 2,
        printable.len() * 2,
    ] {
        buffer.extend_from_slice(&u16::try_from(value)?.to_le_bytes());
    }
    for value in substitute
        .into_iter()
        .chain(Some(0))
        .chain(printable)
        .chain(Some(0))
    {
        buffer.extend_from_slice(&value.to_le_bytes());
    }
    let directory = OpenOptions::new()
        .access_mode(GENERIC_WRITE)
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        .open(link)?;
    let mut returned = 0;
    ensure!(
        unsafe {
            DeviceIoControl(
                directory.as_raw_handle(),
                FSCTL_SET_REPARSE_POINT,
                buffer.as_ptr().cast(),
                buffer.len().try_into()?,
                null_mut(),
                0,
                &mut returned,
                null_mut(),
            )
        } != 0,
        "owned junction SDK operation failed"
    );
    Ok(())
}
#[test]
#[ignore = "fresh GitHub-hosted Windows only; explicit synthetic SDK opt-in"]
fn owned_local_reader_returns_exact_bytes_and_releases_all_handles() {
    let temp = root();
    let path = temp.path().join("private").join("界.txt");
    private_file(&path, &[0, 255, 10, 65]);
    let payload =
        super::super::prepare_admitted(&[path.to_str().unwrap().to_owned()], &work()).unwrap();
    let payload = serde_json::to_value(payload).unwrap();
    assert_eq!(payload[0]["name"], "界.txt");
    assert_eq!(payload[0]["data"], "AP8KQQ==");
    assert!(!payload.to_string().contains(temp.path().to_str().unwrap()));
    let before = fs::metadata(&path).unwrap().permissions().readonly();
    let mut retained = RetainedFile::open(&path, &work()).unwrap();
    let mut bytes = Vec::new();
    retained.file.read_to_end(&mut bytes).unwrap();
    assert_eq!(bytes, [0, 255, 10, 65]);
    drop(retained);
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().readonly(),
        before
    );
    fs::rename(&path, path.with_extension("moved")).unwrap();
}
#[test]
#[ignore = "fresh GitHub-hosted Windows only; explicit synthetic SDK opt-in"]
fn parent_junction_and_final_file_reparse_are_refused() {
    let temp = root();
    let private = temp.path().join("private");
    let target = private.join("target");
    crate::private_fs::windows::create_directory(&target).unwrap();
    private_file(&target.join("owned.txt"), b"owned synthetic source");
    let link = private.join("junction");
    junction(&link, &target).unwrap();
    assert!(RetainedFile::open(&link.join("owned.txt"), &work()).is_err());
    // This final-component directory reparse is rejected independently too.
    assert!(RetainedFile::open(&link, &work()).is_err());
    let file_link = private.join("file-link.txt");
    std::os::windows::fs::symlink_file(target.join("owned.txt"), &file_link)
        .expect("actual owned final file symlink fixture required");
    assert!(RetainedFile::open(&file_link, &work()).is_err());
    fs::remove_file(file_link).unwrap();
    fs::remove_dir(link).unwrap();
    assert_eq!(
        fs::read(target.join("owned.txt")).unwrap(),
        b"owned synthetic source"
    );
}
#[test]
#[ignore = "fresh GitHub-hosted Windows only; explicit synthetic SDK opt-in"]
fn concurrent_parent_and_file_replacement_cannot_retarget_pinned_reader() {
    let temp = root();
    let parent = temp.path().join("private").join("parent");
    crate::private_fs::windows::create_directory(&parent).unwrap();
    let path = parent.join("owned.txt");
    private_file(&path, b"owned original bytes");
    let mut retained = RetainedFile::open(&path, &work()).unwrap();
    let barrier = Arc::new(Barrier::new(2));
    let other = barrier.clone();
    let moving = parent.clone();
    let racer = std::thread::spawn(move || {
        other.wait();
        let parent_denied = fs::rename(&moving, moving.with_extension("replacement")).is_err();
        let file_denied = fs::rename(moving.join("owned.txt"), moving.join("changed.txt")).is_err();
        (parent_denied, file_denied)
    });
    barrier.wait();
    let mut bytes = Vec::new();
    retained.file.read_to_end(&mut bytes).unwrap();
    assert_eq!(racer.join().unwrap(), (true, true));
    assert_eq!(bytes, b"owned original bytes");
    drop(retained);
    fs::rename(&parent, parent.with_extension("released")).unwrap();
}
#[test]
#[ignore = "fresh GitHub-hosted Windows only; explicit synthetic SDK opt-in"]
fn file_held_open_by_an_editor_style_writer_still_attaches() {
    let temp = root();
    let path = temp.path().join("private").join("held.txt");
    private_file(&path, b"owned held document");
    // An editor-style owner: read/write access that shares only reads.
    let writer = OpenOptions::new()
        .read(true)
        .write(true)
        .share_mode(FILE_SHARE_READ)
        .open(&path)
        .unwrap();
    let mut retained = RetainedFile::open(&path, &work()).unwrap();
    let mut bytes = Vec::new();
    retained.file.read_to_end(&mut bytes).unwrap();
    assert_eq!(bytes, b"owned held document");
    drop(retained);
    drop(writer);
    fs::rename(&path, path.with_extension("released")).unwrap();
}
#[test]
#[ignore = "fresh GitHub-hosted Windows only; explicit synthetic SDK opt-in"]
fn cancelled_and_expired_work_cannot_open_or_read_the_owned_file() {
    let temp = root();
    let path = temp.path().join("private").join("owned.txt");
    private_file(&path, b"owned cancellation fixture");
    let cancelled = work();
    cancelled.cancel();
    assert!(RetainedFile::open(&path, &cancelled).is_err());
    assert!(RetainedFile::open(&path, &UploadWork::new(Duration::ZERO)).is_err());
    let mut retained = RetainedFile::open(&path, &work()).unwrap();
    let cancellation = work();
    cancellation.cancel();
    assert!(
        super::super::read_bounded(&mut retained.file, 4 * 1024 * 1024, &cancellation).is_err()
    );
    assert_eq!(retained.file.stream_position().unwrap(), 0);
}

#[test]
#[ignore = "fresh GitHub-hosted Windows only; explicit synthetic SDK opt-in"]
fn full_attachment_pipeline_keeps_file_and_combined_byte_limits() {
    let temp = root();
    let private = temp.path().join("private");
    let first = private.join("first.bin");
    let second = private.join("second.bin");
    private_file(&first, &[]);
    private_file(&second, &[1]);
    let first = first.to_str().unwrap().to_owned();
    let second = second.to_str().unwrap().to_owned();
    let empty = super::super::prepare_admitted(std::slice::from_ref(&first), &work()).unwrap();
    assert_eq!(serde_json::to_value(empty).unwrap()[0]["data"], "");
    fs::OpenOptions::new()
        .write(true)
        .open(&first)
        .unwrap()
        .set_len(4 * 1024 * 1024)
        .unwrap();
    assert!(super::super::prepare_admitted(&[first.clone(), second], &work()).is_err());
    assert!(super::super::prepare_admitted(&vec![first; 9], &work()).is_err());
}
