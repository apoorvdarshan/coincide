//! Offline whisper-cli.exe: private owner-only files, fixed arguments and an
//! owned suspended child admitted to a kill-on-close Job before execution.
use super::{LocalError, LocalWhisper, MAX_OUTPUT, parse_output, validate_input};
use std::{
    fs,
    io::{Read, Write},
    mem::{size_of, size_of_val},
    os::windows::{
        io::{AsRawHandle, FromRawHandle, OwnedHandle},
        process::CommandExt,
    },
    path::PathBuf,
    process::{Child, Command, Stdio},
    ptr::null,
    time::{Duration, Instant},
};
use windows_sys::Win32::{
    Foundation::{HANDLE, INVALID_HANDLE_VALUE},
    System::{
        Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
        },
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            JOBOBJECT_BASIC_ACCOUNTING_INFORMATION, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            JobObjectBasicAccountingInformation, JobObjectExtendedLimitInformation,
            QueryInformationJobObject, SetInformationJobObject, TerminateJobObject,
        },
        Threading::{
            CREATE_NO_WINDOW, CREATE_SUSPENDED, OpenThread, ResumeThread, THREAD_SUSPEND_RESUME,
        },
    },
};

pub(super) fn configuration(backend: &LocalWhisper) -> Result<(), LocalError> {
    for path in [&backend.executable, &backend.model] {
        if !matches!(path.components().next(), Some(std::path::Component::Prefix(prefix))
            if matches!(prefix.kind(), std::path::Prefix::Disk(_) | std::path::Prefix::VerbatimDisk(_)))
        {
            return Err(LocalError::InvalidConfiguration);
        }
    }
    if !backend
        .executable
        .extension()
        .and_then(|value| value.to_str())
        .is_some_and(|value| value.eq_ignore_ascii_case("exe"))
    {
        return Err(LocalError::InvalidConfiguration);
    }
    let mut executable = crate::native_file::open_regular(&backend.executable, false)
        .map_err(|_| LocalError::InvalidConfiguration)?;
    let mut signature = [0; 2];
    executable
        .read_exact(&mut signature)
        .map_err(|_| LocalError::InvalidConfiguration)?;
    if signature != *b"MZ" {
        return Err(LocalError::InvalidConfiguration);
    }
    crate::native_file::open_regular(&backend.model, false)
        .map_err(|_| LocalError::InvalidConfiguration)?;
    Ok(())
}
struct Directory {
    path: PathBuf,
    identity: crate::native_file::Identity,
    cleanup_allowed: bool,
}
impl Directory {
    fn new() -> Result<Self, LocalError> {
        let path = std::env::temp_dir().join(format!("coincide-whisper-{}", uuid::Uuid::new_v4()));
        crate::native_file::private_directory(&path).map_err(|_| LocalError::Unavailable)?;
        let identity =
            crate::native_file::path_identity(&path).map_err(|_| LocalError::Unavailable)?;
        Ok(Self {
            path,
            identity,
            cleanup_allowed: true,
        })
    }
    fn cleanup(&mut self) -> Result<(), LocalError> {
        if !self.cleanup_allowed {
            return Err(LocalError::CleanupPending);
        }
        if crate::native_file::path_identity(&self.path).ok() != Some(self.identity) {
            return Err(LocalError::CleanupPending);
        }
        fs::remove_dir_all(&self.path).map_err(|_| LocalError::CleanupPending)?;
        self.cleanup_allowed = false;
        Ok(())
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = self.cleanup();
    }
}
fn owned(handle: HANDLE) -> Result<OwnedHandle, LocalError> {
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return Err(LocalError::Unavailable);
    }
    Ok(unsafe { OwnedHandle::from_raw_handle(handle) })
}
struct Process {
    child: Child,
    job: OwnedHandle,
}
impl Process {
    fn spawn(command: &mut Command, directory: &mut Directory) -> Result<Self, LocalError> {
        let job = owned(unsafe { CreateJobObjectW(null(), null()) })?;
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if unsafe {
            SetInformationJobObject(
                job.as_raw_handle(),
                JobObjectExtendedLimitInformation,
                (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                size_of_val(&limits) as u32,
            )
        } == 0
        {
            return Err(LocalError::Unavailable);
        }
        let mut child = command
            .creation_flags(CREATE_SUSPENDED | CREATE_NO_WINDOW)
            .spawn()
            .map_err(|_| LocalError::Unavailable)?;
        directory.cleanup_allowed = false;
        if unsafe { AssignProcessToJobObject(job.as_raw_handle(), child.as_raw_handle()) } == 0 {
            let _ = child.kill();
            directory.cleanup_allowed = child.wait().is_ok();
            return Err(if directory.cleanup_allowed {
                LocalError::Unavailable
            } else {
                LocalError::CleanupPending
            });
        }
        let mut process = Self { child, job };
        if let Err(error) = process.resume() {
            if process.finish().is_ok() {
                directory.cleanup_allowed = true;
            } else {
                return Err(LocalError::CleanupPending);
            }
            return Err(error);
        }
        Ok(process)
    }
    fn resume(&mut self) -> Result<(), LocalError> {
        let snapshot = owned(unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) })?;
        let mut entry: THREADENTRY32 = unsafe { std::mem::zeroed() };
        entry.dwSize = size_of::<THREADENTRY32>() as u32;
        let mut present = unsafe { Thread32First(snapshot.as_raw_handle(), &mut entry) };
        while present != 0 {
            if entry.th32OwnerProcessID == self.child.id() {
                let thread =
                    owned(unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID) })?;
                if unsafe { ResumeThread(thread.as_raw_handle()) } != 1 {
                    return Err(LocalError::Unavailable);
                }
                return Ok(());
            }
            entry.dwSize = size_of::<THREADENTRY32>() as u32;
            present = unsafe { Thread32Next(snapshot.as_raw_handle(), &mut entry) };
        }
        Err(LocalError::Unavailable)
    }
    fn finish(&mut self) -> Result<(), LocalError> {
        if unsafe { TerminateJobObject(self.job.as_raw_handle(), 1) } == 0 {
            return Err(LocalError::CleanupPending);
        }
        self.child.wait().map_err(|_| LocalError::CleanupPending)?;
        let started = Instant::now();
        loop {
            let mut accounting: JOBOBJECT_BASIC_ACCOUNTING_INFORMATION =
                unsafe { std::mem::zeroed() };
            if unsafe {
                QueryInformationJobObject(
                    self.job.as_raw_handle(),
                    JobObjectBasicAccountingInformation,
                    (&mut accounting as *mut JOBOBJECT_BASIC_ACCOUNTING_INFORMATION).cast(),
                    size_of_val(&accounting) as u32,
                    std::ptr::null_mut(),
                )
            } == 0
            {
                return Err(LocalError::CleanupPending);
            }
            if accounting.ActiveProcesses == 0 {
                return Ok(());
            }
            if started.elapsed() >= Duration::from_secs(5) {
                return Err(LocalError::CleanupPending);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}
impl Drop for Process {
    fn drop(&mut self) {
        // Closing this exact Job remains kill-on-close, including unwinds.
        unsafe {
            TerminateJobObject(self.job.as_raw_handle(), 1);
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
pub(super) fn transcribe(
    backend: &LocalWhisper,
    wav: &[u8],
    cancelled: &impl Fn() -> bool,
) -> Result<String, LocalError> {
    validate_input(wav)?;
    configuration(backend)?;
    if cancelled() {
        return Err(LocalError::Cancelled);
    }
    let mut directory = Directory::new()?;
    let input = directory.path.join("dictation.wav");
    let prefix = directory.path.join("transcript");
    let output = prefix.with_extension("json");
    let mut file =
        crate::native_file::create_private_file(&input).map_err(|_| LocalError::Unavailable)?;
    file.write_all(wav).map_err(|_| LocalError::Unavailable)?;
    drop(file);
    // Preserve a private ACL if the CLI truncates its ordinary output file.
    drop(crate::native_file::create_private_file(&output).map_err(|_| LocalError::Unavailable)?);
    let mut command = Command::new(&backend.executable);
    command
        .arg("-m")
        .arg(&backend.model)
        .arg("-f")
        .arg(&input)
        .arg("-oj")
        .arg("-of")
        .arg(&prefix)
        .arg("-l")
        .arg(&backend.language)
        .arg("-t")
        .arg(backend.threads.to_string())
        .arg("-np")
        .current_dir(&directory.path)
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    for key in [
        "SystemRoot",
        "WINDIR",
        "PATH",
        "TEMP",
        "TMP",
        "USERPROFILE",
        "LOCALAPPDATA",
        "APPDATA",
        "LANG",
    ] {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    if cancelled() {
        return Err(LocalError::Cancelled);
    }
    let mut process = Process::spawn(&mut command, &mut directory)?;
    let started = Instant::now();
    let result = loop {
        if cancelled() {
            break Err(LocalError::Cancelled);
        }
        if started.elapsed() >= backend.timeout {
            break Err(LocalError::TimedOut);
        }
        if fs::metadata(&output).is_ok_and(|metadata| metadata.len() > MAX_OUTPUT as u64) {
            break Err(LocalError::TooLarge);
        }
        match process.child.try_wait() {
            Ok(Some(status)) if status.success() => break Ok(()),
            Ok(Some(_)) => break Err(LocalError::ProcessFailed),
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            Err(_) => break Err(LocalError::Unavailable),
        }
    };
    process.finish()?;
    directory.cleanup_allowed = true;
    drop(process);
    let result = result.and_then(|()| {
        if cancelled() {
            return Err(LocalError::Cancelled);
        }
        let mut file = crate::private_fs::windows::open_file(&output, false)
            .map_err(|_| LocalError::InvalidOutput)?;
        if file
            .metadata()
            .map_err(|_| LocalError::InvalidOutput)?
            .len()
            > MAX_OUTPUT as u64
        {
            return Err(LocalError::TooLarge);
        }
        let mut bytes = Vec::new();
        (&mut file)
            .take(MAX_OUTPUT as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| LocalError::InvalidOutput)?;
        parse_output(&bytes)
    });
    directory.cleanup()?;
    result
}
