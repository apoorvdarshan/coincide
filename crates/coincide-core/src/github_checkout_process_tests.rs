use super::*;
const MARKER: &str = "COINCIDE_CHECKOUT_PROCESS_FIXTURE";
const CHILD: &str = "github_checkout::process::tests::owned_fake_child";
#[test]
#[ignore = "only the private fake-process wrapper invokes this synthetic child"]
fn owned_fake_child() {
    assert_eq!(std::env::var(MARKER).as_deref(), Ok("owned-fake-v1"));
    let root = PathBuf::from(std::env::var_os("COINCIDE_CHECKOUT_PROCESS_ROOT").unwrap());
    assert_eq!(
        std::env::current_dir().unwrap().canonicalize().unwrap(),
        root.canonicalize().unwrap()
    );
    assert!(
        root.file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with("coincide-checkout-fake-")
    );
    match std::env::var("COINCIDE_CHECKOUT_PROCESS_MODE")
        .unwrap()
        .as_str()
    {
        "echo" => {
            std::io::stdout()
                .write_all("synthetic café 中文 🦀".as_bytes())
                .unwrap();
        }
        "flood" => {
            std::io::stdout().write_all(&vec![b'x'; 65536]).unwrap();
        }
        "large-file" => {
            let mut file = File::create(root.join("large-pack-fixture")).unwrap();
            file.write_all(&vec![b'p'; 32768]).unwrap();
        }
        "disk" => {
            fs::write(root.join("pack-fixture"), vec![b'p'; 4096]).unwrap();
            std::thread::sleep(Duration::from_secs(30));
        }
        "wait" => {
            std::thread::sleep(Duration::from_secs(30));
        }
        "descendant" => {
            let mut child = fake_command(&root, "wait")
                .stdout(Stdio::null())
                .spawn()
                .unwrap();
            fs::write(root.join("descendant.pid"), child.id().to_string()).unwrap();
            // The leader returns semantic success without waiting. The actual
            // group/Job owner must stop and verify its still-running descendant.
            std::io::stdout()
                .write_all(b"semantic parent success")
                .unwrap();
            // Child::drop does not terminate it; outer native group/Job owns it.
            let _ = &mut child;
        }
        _ => panic!("unsupported private fake mode"),
    }
}
fn root() -> tempfile::TempDir {
    tempfile::Builder::new()
        .prefix("coincide-checkout-fake-")
        .tempdir()
        .unwrap()
}
fn fake_command(root: &Path, mode: &str) -> Command {
    let mut command = Command::new(std::env::current_exe().unwrap());
    command.env_clear();
    for key in ["SystemRoot", "WINDIR", "PATH", "TMPDIR", "TMP", "TEMP"] {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    command
        .env(MARKER, "owned-fake-v1")
        .env("COINCIDE_CHECKOUT_PROCESS_ROOT", root)
        .env("COINCIDE_CHECKOUT_PROCESS_MODE", mode)
        .env("HOME", root)
        .env("USERPROFILE", root)
        .arg("--ignored")
        .arg("--exact")
        .arg(CHILD)
        .arg("--nocapture")
        .arg("--test-threads=1")
        .current_dir(root)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    command
}
fn returned(run: &mut Run, directory: &filesystem::Directory, cancelled: &AtomicBool) {
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        if run.poll(directory, cancelled) == ProcessStatus::Returned {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "Actual native child/group return was not observed"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}
#[test]
fn checkout_process_actual_private_child_and_group_return_before_receipt() {
    let root = root();
    let directory = filesystem::Directory::pin(root.path()).unwrap();
    let mut run = Run::start(fake_command(root.path(), "echo"), &directory).unwrap();
    assert!(run.take().is_err());
    returned(&mut run, &directory, &AtomicBool::new(false));
    let result = run.take().unwrap();
    assert_eq!(result.exit_code(), 0);
    assert!(
        String::from_utf8(result.output().to_vec())
            .unwrap()
            .contains("synthetic café 中文 🦀")
    );
    let mut run = Run::start(fake_command(root.path(), "descendant"), &directory).unwrap();
    returned(&mut run, &directory, &AtomicBool::new(false));
    assert_eq!(run.take().unwrap().exit_code(), 0);
    assert!(
        root.path().join("descendant.pid").exists(),
        "Real synthetic descendant must have started"
    );
    assert!(
        run.owner.joined,
        "Leader success cannot substitute for actual owned group/Job drain"
    );
}
#[test]
fn checkout_process_cancel_timeout_output_and_disk_limits_return_actual_owner() {
    for (mode, expected) in [
        ("wait", StopReason::Cancelled),
        ("wait", StopReason::TimedOut),
        ("flood", StopReason::OutputLimit),
        ("disk", StopReason::DiskLimit),
    ] {
        let root = root();
        let directory = filesystem::Directory::pin(root.path()).unwrap();
        let limits = Limits {
            output: 1024,
            file: 16384,
            total: 1024,
            entries: 32,
            time: if expected == StopReason::TimedOut {
                Duration::from_millis(50)
            } else {
                Duration::from_secs(5)
            },
        };
        let mut run =
            Run::start_with_limits(fake_command(root.path(), mode), &directory, limits).unwrap();
        let cancelled = AtomicBool::new(expected == StopReason::Cancelled);
        returned(&mut run, &directory, &cancelled);
        assert!(run.owner.joined);
        assert_eq!(run.reason, Some(expected));
        assert!(run.take().is_err());
    }
}
#[test]
fn checkout_process_directory_monitor_refuses_links_and_counts_actual_files() {
    let root = root();
    let directory = filesystem::Directory::pin(root.path()).unwrap();
    let mut file = directory.create_file("pack").unwrap();
    file.write_all(&[1u8; 2048]).unwrap();
    file.sync_all().unwrap();
    assert_eq!(directory.inventory(32).unwrap(), (2048, 2048));
    assert!(directory.inventory(0).is_err());
    #[cfg(unix)]
    {
        let outside = root.path().join("outside");
        fs::write(&outside, b"keep").unwrap();
        std::os::unix::fs::symlink(&outside, root.path().join("link")).unwrap();
        assert!(directory.inventory(32).is_err());
        assert_eq!(fs::read(outside).unwrap(), b"keep");
    }
}
#[test]
fn checkout_local_runner_refuses_network_without_starting_git_or_gh() {
    let (directory, mut engine, path, id) = super::super::tests::fixture();
    let plan = Plan::prepare(super::super::tests::source(&mut engine, &path, &id)).unwrap();
    // Current test executable is only pinned as trusted metadata. FetchPull is
    // denied before any process invocation, regardless of configured tool.
    let executable = std::env::current_exe().unwrap();
    let tools =
        Tools::capture(&executable, &executable, directory.path(), directory.path()).unwrap();
    let mut local = plan.start_local(tools).unwrap();
    assert!(local.start(Operation::FetchPull).is_err());
    assert!(local.active.is_none());
    assert_eq!(fs::read_dir(local.directory()).unwrap().count(), 2);
}

#[cfg(unix)]
#[test]
fn checkout_process_kernel_file_cap_is_scoped_to_owned_child() {
    let root = root();
    let directory = filesystem::Directory::pin(root.path()).unwrap();
    let mut run = Run::start_with_limits(
        fake_command(root.path(), "large-file"),
        &directory,
        Limits {
            output: MAX_TREE,
            file: 16384,
            total: 65536,
            entries: 32,
            time: Duration::from_secs(5),
        },
    )
    .unwrap();
    returned(&mut run, &directory, &AtomicBool::new(false));
    assert!(run.take().is_err());
    assert!(
        fs::metadata(root.path().join("large-pack-fixture"))
            .unwrap()
            .len()
            <= 16384
    );
    // The parent has not inherited the child's resource limit.
    fs::write(root.path().join("parent-can-write"), vec![0u8; 32768]).unwrap();
}
