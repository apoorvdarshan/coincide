//! Read-only gh transport. A suspended child joins our Job before running;
//! cancellation/deadline drains that exact Job before the worker returns.
use super::*;
use std::{
    fs::{File, OpenOptions},
    io::{Read, Write},
    mem::{size_of, size_of_val},
    os::windows::{
        fs::{MetadataExt, OpenOptionsExt},
        io::{AsRawHandle, FromRawHandle, OwnedHandle},
        process::CommandExt,
    },
    process::{Child, Command, Stdio},
    ptr::null,
};
use windows_sys::Win32::{
    Foundation::{
        ERROR_BROKEN_PIPE, ERROR_MORE_DATA, GetLastError, HANDLE, INVALID_HANDLE_VALUE,
        WAIT_OBJECT_0,
    },
    Storage::FileSystem::{
        FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
        FILE_SHARE_READ, FILE_SHARE_WRITE,
    },
    System::{
        Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
        },
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, IsProcessInJob,
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, JOBOBJECT_BASIC_ACCOUNTING_INFORMATION,
            JOBOBJECT_BASIC_PROCESS_ID_LIST, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            JobObjectBasicAccountingInformation, JobObjectBasicProcessIdList,
            JobObjectExtendedLimitInformation, QueryInformationJobObject, SetInformationJobObject,
            TerminateJobObject,
        },
        Pipes::PeekNamedPipe,
        Threading::{
            CREATE_NO_WINDOW, CREATE_SUSPENDED, GetExitCodeProcess, OpenProcess, OpenThread,
            PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, ResumeThread,
            THREAD_SUSPEND_RESUME, WaitForSingleObject,
        },
    },
};
fn owned(raw: HANDLE) -> Result<OwnedHandle> {
    ensure!(
        !raw.is_null() && raw != INVALID_HANDLE_VALUE,
        "GitHub process handle unavailable"
    );
    Ok(unsafe { OwnedHandle::from_raw_handle(raw) })
}
struct Process {
    child: Child,
    job: OwnedHandle,
    writer: Option<std::thread::JoinHandle<std::io::Result<()>>>,
}
impl Process {
    fn spawn(command: &mut Command) -> Result<Self> {
        let job = owned(unsafe { CreateJobObjectW(null(), null()) })?;
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        ensure!(
            unsafe {
                SetInformationJobObject(
                    job.as_raw_handle(),
                    JobObjectExtendedLimitInformation,
                    (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                    size_of_val(&limits) as u32,
                )
            } != 0,
            "GitHub Job setup failed"
        );
        let mut child = command
            .creation_flags(CREATE_SUSPENDED | CREATE_NO_WINDOW)
            .spawn()
            .context("Unable to start configured gh")?;
        if unsafe { AssignProcessToJobObject(job.as_raw_handle(), child.as_raw_handle()) } == 0 {
            let _ = child.kill();
            child.wait().context("GitHub child cleanup incomplete")?;
            bail!("GitHub child isolation failed");
        }
        let mut process = Self {
            child,
            job,
            writer: None,
        };
        if let Err(error) = process.resume() {
            process.finish()?;
            return Err(error);
        }
        Ok(process)
    }
    fn resume(&self) -> Result<()> {
        let snapshot = owned(unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) })?;
        let mut entry: THREADENTRY32 = unsafe { std::mem::zeroed() };
        entry.dwSize = size_of::<THREADENTRY32>() as u32;
        let mut present = unsafe { Thread32First(snapshot.as_raw_handle(), &mut entry) };
        while present != 0 {
            if entry.th32OwnerProcessID == self.child.id() {
                let thread =
                    owned(unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID) })?;
                ensure!(
                    unsafe { ResumeThread(thread.as_raw_handle()) } == 1,
                    "GitHub child resume failed"
                );
                return Ok(());
            }
            entry.dwSize = size_of::<THREADENTRY32>() as u32;
            present = unsafe { Thread32Next(snapshot.as_raw_handle(), &mut entry) };
        }
        bail!("GitHub child primary thread unavailable")
    }
    fn exited(&self) -> Result<Option<bool>> {
        if unsafe { WaitForSingleObject(self.child.as_raw_handle(), 0) } != WAIT_OBJECT_0 {
            return Ok(None);
        }
        let mut code = 1;
        ensure!(
            unsafe { GetExitCodeProcess(self.child.as_raw_handle(), &mut code) } != 0,
            "GitHub exit status unavailable"
        );
        Ok(Some(code == 0))
    }
    fn finish(&mut self) -> Result<()> {
        let cleanup = self.drain();
        let written = self.writer.take().map(|writer| writer.join());
        cleanup?;
        if let Some(result) = written {
            result
                .map_err(|_| anyhow::anyhow!("GitHub input worker panicked"))?
                .context("GitHub request input failed")?;
        }
        Ok(())
    }
    /// A process leaves the Job's count before its own handles (one on the
    /// root, say) are closed, so each member the Job lists is held open and
    /// counts as stopped only once signalled.
    fn hold_members(&self, members: &mut Vec<(u32, OwnedHandle)>) -> Result<()> {
        let offset = std::mem::offset_of!(JOBOBJECT_BASIC_PROCESS_ID_LIST, ProcessIdList)
            / size_of::<usize>();
        let mut capacity = 64;
        let buffer = loop {
            let mut buffer = vec![0usize; offset + capacity];
            let queried = unsafe {
                QueryInformationJobObject(
                    self.job.as_raw_handle(),
                    JobObjectBasicProcessIdList,
                    buffer.as_mut_ptr().cast(),
                    size_of_val(buffer.as_slice()) as u32,
                    std::ptr::null_mut(),
                )
            } != 0;
            let more = !queried && unsafe { GetLastError() } == ERROR_MORE_DATA;
            let list = unsafe { &*buffer.as_ptr().cast::<JOBOBJECT_BASIC_PROCESS_ID_LIST>() };
            if queried && list.NumberOfProcessIdsInList >= list.NumberOfAssignedProcesses {
                break buffer;
            }
            ensure!(
                (queried || more) && capacity < 65_536,
                "GitHub Job cleanup unconfirmed"
            );
            capacity *= 4;
        };
        let list = unsafe { &*buffer.as_ptr().cast::<JOBOBJECT_BASIC_PROCESS_ID_LIST>() };
        let listed = (list.NumberOfProcessIdsInList as usize).min(capacity);
        for &id in &buffer[offset..offset + listed] {
            let Ok(id) = u32::try_from(id) else {
                continue;
            };
            if members.iter().any(|(held, _)| *held == id) {
                continue;
            }
            let access = PROCESS_SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION;
            // Unopenable means already gone: signalled before its ID was free.
            let Ok(member) = owned(unsafe { OpenProcess(access, 0, id) }) else {
                continue;
            };
            let mut ours = 0;
            if unsafe {
                IsProcessInJob(member.as_raw_handle(), self.job.as_raw_handle(), &mut ours)
            } != 0
                && ours != 0
            {
                members.push((id, member));
            }
        }
        Ok(())
    }
    fn drain(&mut self) -> Result<()> {
        // Held before termination, while every member is still listed.
        let mut members = Vec::new();
        let held = self.hold_members(&mut members);
        ensure!(
            unsafe { TerminateJobObject(self.job.as_raw_handle(), 1) } != 0,
            "GitHub Job cleanup incomplete"
        );
        held?;
        self.child
            .wait()
            .context("GitHub child cleanup incomplete")?;
        let started = Instant::now();
        loop {
            self.hold_members(&mut members)?;
            let mut accounting: JOBOBJECT_BASIC_ACCOUNTING_INFORMATION =
                unsafe { std::mem::zeroed() };
            ensure!(
                unsafe {
                    QueryInformationJobObject(
                        self.job.as_raw_handle(),
                        JobObjectBasicAccountingInformation,
                        (&mut accounting as *mut JOBOBJECT_BASIC_ACCOUNTING_INFORMATION).cast(),
                        size_of_val(&accounting) as u32,
                        std::ptr::null_mut(),
                    )
                } != 0,
                "GitHub Job cleanup unconfirmed"
            );
            if accounting.ActiveProcesses == 0 {
                break;
            }
            ensure!(
                started.elapsed() < Duration::from_secs(5),
                "GitHub descendants still stopping"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        for (_, member) in &members {
            let left = Duration::from_secs(5).saturating_sub(started.elapsed());
            ensure!(
                unsafe { WaitForSingleObject(member.as_raw_handle(), left.as_millis() as u32) }
                    == WAIT_OBJECT_0,
                "GitHub descendants still stopping"
            );
        }
        Ok(())
    }
}
impl Drop for Process {
    fn drop(&mut self) {
        unsafe {
            TerminateJobObject(self.job.as_raw_handle(), 1);
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(writer) = self.writer.take() {
            let _ = writer.join();
        }
    }
}
fn hold_root(root: &Path) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
        .open(root)?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_dir() && metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT == 0,
        "GitHub project root is unavailable"
    );
    ensure!(
        crate::native_file::file_identity(&file)? == crate::native_file::path_identity(root)?,
        "GitHub project root changed"
    );
    Ok(file)
}
pub(super) fn capture(
    runner: &GhRunner,
    root: &Path,
    args: &[String],
    cancelled: &AtomicBool,
) -> Result<Vec<u8>> {
    capture_with_input(runner, root, args, cancelled, None)
}
pub(crate) fn capture_with_input(
    runner: &GhRunner,
    root: &Path,
    args: &[String],
    cancelled: &AtomicBool,
    input: Option<Vec<u8>>,
) -> Result<Vec<u8>> {
    ensure!(
        input.as_ref().is_none_or(|body| body.len() <= 256 * 1024),
        "Request body too large"
    );
    ensure!(
        !cancelled.load(Ordering::Acquire),
        "GitHub operation cancelled"
    );
    let held_root = hold_root(root)?;
    let root_identity = crate::native_file::file_identity(&held_root)?;
    let mut held_executable = OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .share_mode(FILE_SHARE_READ)
        .open(&runner.executable)
        .context("Configured gh cannot be held read-only")?;
    let metadata = held_executable.metadata()?;
    ensure!(
        metadata.is_file() && metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT == 0,
        "Configured gh is not a regular native executable"
    );
    let mut signature = [0u8; 2];
    held_executable.read_exact(&mut signature)?;
    ensure!(
        signature == *b"MZ",
        "Configured gh must be a native Windows executable"
    );
    let executable_identity = crate::native_file::file_identity(&held_executable)?;
    let mut command = Command::new(&runner.executable);
    command.env_clear();
    // gh may use its own configured authentication or these official token
    // variables. Unrelated provider/password-manager credentials stay out.
    for key in [
        "PATH",
        "PATHEXT",
        "SystemRoot",
        "WINDIR",
        "COMSPEC",
        "HOME",
        "USERPROFILE",
        "APPDATA",
        "LOCALAPPDATA",
        "TEMP",
        "TMP",
        "GH_CONFIG_DIR",
        "GH_TOKEN",
        "GITHUB_TOKEN",
        "HTTPS_PROXY",
        "HTTP_PROXY",
        "NO_PROXY",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
    ] {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    command
        .args(args)
        .current_dir(root)
        .env("GH_HOST", "github.com")
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_PAGER", "cat")
        .env("PAGER", "cat")
        .env("NO_COLOR", "1")
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    ensure!(
        crate::native_file::path_identity(&runner.executable)? == executable_identity,
        "Configured gh changed"
    );
    let mut process = Process::spawn(&mut command)?;
    if let Some(body) = input {
        let mut stdin = process
            .child
            .stdin
            .take()
            .context("Missing GitHub input pipe")?;
        process.writer = Some(
            std::thread::Builder::new()
                .name("coincide-github-input".into())
                .spawn(move || stdin.write_all(&body))
                .context("Unable to own GitHub input worker")?,
        );
    }
    let result = (|| -> Result<Vec<u8>> {
        let mut stdout = process.child.stdout.take().context("Missing gh stdout")?;
        let mut bytes = Vec::new();
        let mut eof = false;
        let started = Instant::now();
        loop {
            ensure!(
                !cancelled.load(Ordering::Acquire),
                "GitHub operation cancelled"
            );
            ensure!(
                started.elapsed() < runner.timeout,
                "GitHub operation timed out"
            );
            let mut available = 0;
            let readable = unsafe {
                PeekNamedPipe(
                    stdout.as_raw_handle(),
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null_mut(),
                    &mut available,
                    std::ptr::null_mut(),
                )
            };
            if readable == 0 {
                ensure!(
                    unsafe { GetLastError() } == ERROR_BROKEN_PIPE,
                    "GitHub output pipe failed"
                );
                eof = true;
            } else if available > 0 {
                let mut chunk = [0u8; 16384];
                let count = (available as usize).min(chunk.len());
                let n = stdout
                    .read(&mut chunk[..count])
                    .context("Unable to read gh output")?;
                ensure!(bytes.len() + n <= MAX_OUTPUT, "GitHub output exceeds 3 MiB");
                bytes.extend_from_slice(&chunk[..n]);
                eof = n == 0;
            }
            if let Some(success) = process.exited()? {
                ensure!(
                    success,
                    "gh read failed; check configured authentication and repository access"
                );
                if eof {
                    return Ok(bytes);
                }
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    })();
    process.finish()?;
    ensure!(
        crate::native_file::path_identity(root)? == root_identity
            && crate::native_file::path_identity(&runner.executable)? == executable_identity,
        "GitHub native context changed"
    );
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    const FIXTURE: &str = "github_api::windows::tests::synthetic_gh_child";
    const DESCENDANT: &str = "github_api::windows::tests::synthetic_gh_descendant";
    fn args(filter: &str) -> Vec<String> {
        [
            "--ignored",
            "--exact",
            filter,
            "--nocapture",
            "--test-threads=1",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect()
    }
    #[test]
    #[ignore = "only owned synthetic GitHub subprocess invokes this"]
    fn synthetic_gh_child() {
        let mode = std::fs::read_to_string("mode").unwrap();
        match mode.as_str() {
            "success" => println!("synthetic-read-result"),
            "failed" => std::process::exit(7),
            "large" => {
                use std::io::Write;
                std::io::stdout()
                    .write_all(&vec![b'x'; MAX_OUTPUT + 1])
                    .unwrap();
            }
            "descendant" => {
                let mut child = Command::new(std::env::current_exe().unwrap())
                    .args(args(DESCENDANT))
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .unwrap();
                let _ = child.wait();
            }
            "timeout" => loop {
                std::thread::sleep(Duration::from_secs(1));
            },
            _ => panic!("unknown private fixture mode"),
        }
    }
    #[test]
    #[ignore = "only owned synthetic GitHub subprocess invokes this"]
    fn synthetic_gh_descendant() {
        std::fs::write("descendant-pid", std::process::id().to_string()).unwrap();
        loop {
            std::thread::sleep(Duration::from_secs(1));
        }
    }
    fn runner(timeout: Duration) -> GhRunner {
        GhRunner {
            executable: std::env::current_exe().unwrap().canonicalize().unwrap(),
            timeout,
        }
    }
    #[test]
    fn native_windows_reads_bound_output_exit_and_timeout() {
        let root = tempfile::tempdir().unwrap();
        for mode in ["success", "failed", "large", "timeout"] {
            std::fs::write(root.path().join("mode"), mode).unwrap();
            let captured = capture(
                &runner(Duration::from_secs(if mode == "timeout" { 2 } else { 15 })),
                root.path(),
                &args(FIXTURE),
                &AtomicBool::new(false),
            );
            if mode == "success" {
                assert!(
                    String::from_utf8(captured.unwrap())
                        .unwrap()
                        .contains("synthetic-read-result")
                );
            } else {
                let error = captured.unwrap_err().to_string();
                assert!(
                    match mode {
                        "failed" => error.contains("gh read failed"),
                        "large" => error.contains("exceeds 3 MiB"),
                        _ => error.contains("timed out"),
                    },
                    "{mode}: {error}"
                );
            }
        }
    }
    #[test]
    fn native_windows_cancellation_waits_for_owned_descendant_and_releases_root() {
        let root = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("mode"), "descendant").unwrap();
        let cancelled = Arc::new(AtomicBool::new(false));
        let signal = cancelled.clone();
        let path = root.path().to_owned();
        let cancel = std::thread::spawn(move || {
            use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_SYNCHRONIZE};
            let started = Instant::now();
            let descendant = loop {
                if let Some(pid) = std::fs::read_to_string(path.join("descendant-pid"))
                    .ok()
                    .and_then(|s| s.parse::<u32>().ok())
                {
                    // Hold the exact live process before cancellation. Looking up
                    // its PID after cleanup can observe an unrelated process if
                    // Windows has already reused the now-unreferenced PID.
                    break owned(unsafe { OpenProcess(PROCESS_SYNCHRONIZE, 0, pid) }).unwrap();
                }
                assert!(
                    started.elapsed() < Duration::from_secs(10),
                    "descendant fixture did not start"
                );
                std::thread::sleep(Duration::from_millis(10));
            };
            signal.store(true, Ordering::Release);
            descendant
        });
        let result = capture(
            &runner(Duration::from_secs(15)),
            root.path(),
            &args(FIXTURE),
            &cancelled,
        );
        let descendant = cancel.join().unwrap();
        assert!(result.unwrap_err().to_string().contains("cancelled"));
        assert_eq!(
            unsafe { WaitForSingleObject(descendant.as_raw_handle(), 0) },
            WAIT_OBJECT_0,
            "actual owned descendant must have exited before return"
        );
        let renamed = root.path().with_extension("renamed");
        std::fs::rename(root.path(), &renamed).unwrap();
        std::fs::rename(&renamed, root.path()).unwrap();
    }
}
