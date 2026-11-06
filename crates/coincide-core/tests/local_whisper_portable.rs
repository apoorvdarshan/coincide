//! Actual private fake executables on every desktop host. No microphone,
//! model inference, shell, network, vault or personal configuration access.
use coincide_core::dictation::{
    local::{LocalError, LocalWhisper},
    transcription::encode_wav,
};
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

fn child(arguments: &[std::ffi::OsString]) -> ! {
    for key in [
        "BW_SESSION",
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "COINCIDE_CONTROL_TOKEN",
    ] {
        if std::env::var_os(key).is_some() {
            std::process::exit(61);
        }
    }
    assert_eq!(arguments.len(), 12);
    assert_eq!(arguments[0], "-m");
    assert_eq!(arguments[2], "-f");
    assert_eq!(arguments[4], "-oj");
    assert_eq!(arguments[5], "-of");
    assert_eq!(arguments[7], "-l");
    assert_eq!(arguments[8], "en");
    assert_eq!(arguments[9], "-t");
    assert_eq!(arguments[10], "2");
    assert_eq!(arguments[11], "-np");
    let model = PathBuf::from(&arguments[1]);
    let input = PathBuf::from(&arguments[3]);
    let output = PathBuf::from(&arguments[6]).with_extension("json");
    assert!(fs::read(&input).unwrap().starts_with(b"RIFF"));
    fs::write(
        model.parent().unwrap().join("job-path"),
        input.parent().unwrap().to_string_lossy().as_bytes(),
    )
    .unwrap();
    match fs::read_to_string(&model).unwrap().as_str() {
        "success" => fs::write(
            output,
            br#"{"transcription":[{"text":" synthetic "},{"text":"voice"}]}"#,
        )
        .unwrap(),
        "invalid" => fs::write(output, b"invalid json").unwrap(),
        "failed" => std::process::exit(7),
        "large" => fs::write(output, vec![b' '; 2_000_000]).unwrap(),
        "descendant" => {
            let mut child = Command::new(std::env::current_exe().unwrap())
                .arg("--owned-synthetic-descendant")
                .arg(model.parent().unwrap().join("descendant-pid"))
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap();
            let _ = child.wait();
        }
        _ => std::process::exit(62),
    }
    std::process::exit(0)
}
fn backend(root: &Path, mode: &str) -> LocalWhisper {
    let model = root.join("synthetic model.bin");
    fs::write(&model, mode).unwrap();
    LocalWhisper::new(
        std::env::current_exe().unwrap(),
        model,
        "en".into(),
        2,
        Duration::from_secs(10),
    )
    .unwrap()
}
fn removed(root: &Path) {
    let path = fs::read_to_string(root.join("job-path")).unwrap();
    assert!(
        !Path::new(&path).exists(),
        "owned synthetic audio directory must be removed after confirmed teardown"
    );
}
#[cfg(windows)]
fn active(pid: u32) -> bool {
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use windows_sys::Win32::{
        Foundation::{ERROR_INVALID_PARAMETER, GetLastError, WAIT_OBJECT_0, WAIT_TIMEOUT},
        System::Threading::{
            OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, SYNCHRONIZATION_SYNCHRONIZE,
            WaitForSingleObject,
        },
    };
    let raw = unsafe {
        OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZATION_SYNCHRONIZE,
            0,
            pid,
        )
    };
    if raw.is_null() {
        assert_eq!(
            unsafe { GetLastError() },
            ERROR_INVALID_PARAMETER,
            "cannot infer process exit from access failure"
        );
        return false;
    }
    let handle = unsafe { OwnedHandle::from_raw_handle(raw) };
    match unsafe { WaitForSingleObject(handle.as_raw_handle(), 0) } {
        WAIT_OBJECT_0 => false,
        WAIT_TIMEOUT => true,
        _ => panic!("owned descendant exit query failed"),
    }
}
#[cfg(unix)]
fn active(pid: u32) -> bool {
    #[cfg(target_os = "linux")]
    if fs::read_to_string(format!("/proc/{pid}/stat"))
        .is_ok_and(|value| value.split_whitespace().nth(2) == Some("Z"))
    {
        return false;
    }
    if unsafe { libc::kill(pid as i32, 0) } == 0 {
        return true;
    }
    assert_eq!(
        std::io::Error::last_os_error().raw_os_error(),
        Some(libc::ESRCH)
    );
    false
}
fn fixture() {
    let wav = encode_wav(&[0.0, 0.5, -0.5], 16_000).unwrap();
    for mode in ["success", "invalid", "failed", "large"] {
        let root = tempfile::tempdir().unwrap();
        let mut backend = backend(root.path(), mode);
        let result = backend.transcribe_local(&wav);
        match mode {
            "success" => assert_eq!(result, Ok("synthetic voice".into())),
            "invalid" => assert_eq!(result, Err(LocalError::InvalidOutput)),
            "failed" => assert_eq!(result, Err(LocalError::ProcessFailed)),
            // Unix RLIMIT_FSIZE may terminate the oversized writer first.
            "large" => assert!(matches!(
                result,
                Err(LocalError::TooLarge | LocalError::ProcessFailed)
            )),
            _ => unreachable!(),
        }
        removed(root.path());
    }
    let root = tempfile::tempdir().unwrap();
    let backend = backend(root.path(), "descendant");
    assert_eq!(
        backend.transcribe_local_cancellable(&wav, || true),
        Err(LocalError::Cancelled)
    );
    assert!(!root.path().join("job-path").exists());
    let pid_path = root.path().join("descendant-pid");
    assert_eq!(
        backend.transcribe_local_cancellable(&wav, || pid_path.is_file()),
        Err(LocalError::Cancelled)
    );
    let pid = fs::read_to_string(pid_path)
        .unwrap()
        .parse::<u32>()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while active(pid) {
        assert!(
            Instant::now() < deadline,
            "owned fake descendant survived cancellation"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    removed(root.path());
    println!(
        "6 portable local-transcription cases passed (success, invalid output, nonzero exit, oversized output, pre-spawn cancellation, descendant cancellation and cleanup)"
    );
}
fn main() {
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    if arguments.first().is_some_and(|value| value == "-m") {
        child(&arguments);
    }
    if arguments
        .first()
        .is_some_and(|value| value == "--owned-synthetic-descendant")
    {
        fs::write(&arguments[1], std::process::id().to_string()).unwrap();
        loop {
            std::thread::sleep(Duration::from_secs(1));
        }
    }
    fixture();
}
