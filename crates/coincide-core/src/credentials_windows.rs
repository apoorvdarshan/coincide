//! Exact Windows vault subprocess ownership; no shell, vault access or logging.
//! The child joins a non-breakaway Job while suspended. Readiness is polled on
//! the single stdout reader; stdin has a cancellable, actually joined writer.
use super::{CliCommand, Failure};
use anyhow::{Context, Result, bail, ensure};
use std::{
    io::{Read, Write},
    mem::{size_of, size_of_val},
    os::windows::{
        io::{AsRawHandle, FromRawHandle, OwnedHandle},
        process::CommandExt,
    },
    process::{Child, Command, Stdio},
    ptr::null,
    time::{Duration, Instant},
};
use windows_sys::Win32::{
    Foundation::{
        ERROR_BROKEN_PIPE, ERROR_MORE_DATA, GetLastError, HANDLE, INVALID_HANDLE_VALUE,
        WAIT_OBJECT_0,
    },
    System::{
        Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
        },
        IO::CancelSynchronousIo,
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
use zeroize::Zeroizing;
const LIMIT: usize = 8 * 1024 * 1024;
fn owned(raw: HANDLE) -> Result<OwnedHandle> {
    ensure!(
        !raw.is_null() && raw != INVALID_HANDLE_VALUE,
        "Vault process handle unavailable"
    );
    Ok(unsafe { OwnedHandle::from_raw_handle(raw) })
}
struct Process {
    child: Child,
    job: OwnedHandle,
    writer: Option<std::thread::JoinHandle<std::io::Result<()>>>,
    members: Vec<(u32, OwnedHandle)>,
    drained: bool,
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
            "Vault Job setup failed"
        );
        let child = command
            .creation_flags(CREATE_SUSPENDED | CREATE_NO_WINDOW)
            .spawn()
            .context("Unable to start configured vault CLI")?;
        let mut process = Self {
            child,
            job,
            writer: None,
            members: Vec::new(),
            drained: false,
        };
        if unsafe {
            AssignProcessToJobObject(process.job.as_raw_handle(), process.child.as_raw_handle())
        } == 0
        {
            process.finish()?;
            bail!("Vault child isolation failed");
        }
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
                    "Vault child resume failed"
                );
                return Ok(());
            }
            entry.dwSize = size_of::<THREADENTRY32>() as u32;
            present = unsafe { Thread32Next(snapshot.as_raw_handle(), &mut entry) };
        }
        bail!("Vault child primary thread unavailable")
    }
    fn exited(&self) -> Result<Option<bool>> {
        if unsafe { WaitForSingleObject(self.child.as_raw_handle(), 0) } != WAIT_OBJECT_0 {
            return Ok(None);
        }
        let mut code = 1;
        ensure!(
            unsafe { GetExitCodeProcess(self.child.as_raw_handle(), &mut code) } != 0,
            "Vault exit status unavailable"
        );
        Ok(Some(code == 0))
    }
    fn finish(&mut self) -> Result<()> {
        // Cancellation is requested repeatedly until the actual writer returns;
        // an OS cancellation request is not completion evidence. Unknown native
        // custody keeps this worker occupied, preventing new vault admission.
        loop {
            if let Some(writer) = &self.writer {
                unsafe {
                    CancelSynchronousIo(writer.as_raw_handle());
                }
            }
            if self.drain().is_ok() {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let written = if let Some(writer) = self.writer.take() {
            while !writer.is_finished() {
                unsafe {
                    CancelSynchronousIo(writer.as_raw_handle());
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            writer
                .join()
                .map_err(|_| anyhow::anyhow!("Vault input worker failed"))?
        } else {
            Ok(())
        };
        self.drained = true;
        written.context("Vault input could not be delivered")
    }
    /// A process leaves the Job's count before its own handles (one on the
    /// root, say) are closed, so each member the Job lists is held open and
    /// counts as stopped only once signalled.
    fn hold_members(&mut self) -> Result<()> {
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
                "Vault Job cleanup unconfirmed"
            );
            capacity *= 4;
        };
        let list = unsafe { &*buffer.as_ptr().cast::<JOBOBJECT_BASIC_PROCESS_ID_LIST>() };
        let listed = (list.NumberOfProcessIdsInList as usize).min(capacity);
        for &id in &buffer[offset..offset + listed] {
            let Ok(id) = u32::try_from(id) else {
                continue;
            };
            if self.members.iter().any(|(held, _)| *held == id) {
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
                self.members.push((id, member));
            }
        }
        Ok(())
    }
    fn drain(&mut self) -> Result<()> {
        // Held before termination, while every member is still listed.
        let held = self.hold_members();
        ensure!(
            unsafe { TerminateJobObject(self.job.as_raw_handle(), 1) } != 0,
            "Vault Job cleanup incomplete"
        );
        let _ = self.child.kill();
        held?;
        self.child
            .wait()
            .context("Vault child cleanup incomplete")?;
        let started = Instant::now();
        loop {
            self.hold_members()?;
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
                "Vault Job cleanup unconfirmed"
            );
            if accounting.ActiveProcesses == 0 {
                break;
            }
            ensure!(
                started.elapsed() < Duration::from_secs(5),
                "Vault descendants still stopping"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        for (_, member) in &self.members {
            let left = Duration::from_secs(5).saturating_sub(started.elapsed());
            ensure!(
                unsafe { WaitForSingleObject(member.as_raw_handle(), left.as_millis() as u32) }
                    == WAIT_OBJECT_0,
                "Vault descendants still stopping"
            );
        }
        Ok(())
    }
}
impl Drop for Process {
    fn drop(&mut self) {
        if !self.drained {
            let _ = self.finish();
        }
    }
}

pub(super) fn capture(
    cli: &CliCommand,
    args: &[&str],
    input: Option<&[u8]>,
    timeout: Duration,
) -> std::result::Result<Vec<u8>, Failure> {
    if input.is_some_and(|bytes| bytes.len() > LIMIT) {
        return Err(Failure::InvalidResponse);
    }
    let mut command = Command::new(&cli.executable);
    command
        .args(args)
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut process = Process::spawn(&mut command).map_err(|_| Failure::Unavailable)?;
    let mut stdout = process.child.stdout.take().ok_or(Failure::Unavailable)?;
    if let Some(input) = input {
        let mut stdin = process.child.stdin.take().ok_or(Failure::Unavailable)?;
        let input = Zeroizing::new(input.to_vec());
        process.writer = Some(
            std::thread::Builder::new()
                .name("coincide-vault-input".into())
                .spawn(move || stdin.write_all(&input))
                .map_err(|_| Failure::Unavailable)?,
        );
    }
    let result = (|| {
        let started = Instant::now();
        let mut bytes = Zeroizing::new(Vec::new());
        let mut chunk = Zeroizing::new([0u8; 8192]);
        let mut eof = false;
        loop {
            if started.elapsed() >= timeout {
                return Err(Failure::Unavailable);
            }
            let mut available = 0;
            if !eof {
                let peek = unsafe {
                    PeekNamedPipe(
                        stdout.as_raw_handle(),
                        std::ptr::null_mut(),
                        0,
                        std::ptr::null_mut(),
                        &mut available,
                        std::ptr::null_mut(),
                    )
                };
                if peek == 0 {
                    if unsafe { GetLastError() } == ERROR_BROKEN_PIPE {
                        eof = true;
                    } else {
                        return Err(Failure::Unavailable);
                    }
                }
            }
            if available > 0 {
                // Exactly one reader owns this anonymous pipe. Reading at most
                // bytes already present cannot wait for a child that awaits stdin.
                let count = (available as usize).min(chunk.len());
                let count = stdout
                    .read(&mut chunk[..count])
                    .map_err(|_| Failure::Unavailable)?;
                if count == 0 {
                    eof = true;
                } else {
                    if bytes.len() + count > LIMIT {
                        return Err(Failure::InvalidResponse);
                    }
                    bytes.extend_from_slice(&chunk[..count]);
                    continue;
                }
            }
            if eof && let Some(success) = process.exited().map_err(|_| Failure::Unavailable)? {
                return if success {
                    Ok(std::mem::take(&mut *bytes))
                } else {
                    Err(Failure::Unavailable)
                };
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    })();
    // Includes the actual writer join and every retained process handle; never
    // turn a cancellation request or a leader exit into a release receipt.
    let drained = process.finish();
    if drained.is_err() {
        return Err(Failure::Unavailable);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> CliCommand {
        let root = std::env::var_os("SystemRoot").expect("Windows system directory");
        CliCommand::new(
            std::path::PathBuf::from(root).join("System32/WindowsPowerShell/v1.0/powershell.exe"),
        )
        .unwrap()
    }
    fn args(script: &str) -> [&str; 5] {
        [
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            script,
        ]
    }
    #[test]
    fn windows_vault_capture_success_nonzero_and_output_bound() {
        let cli = fixture();
        assert_eq!(
            cli.capture(
                &args("[Console]::Out.Write('synthetic')"),
                Duration::from_secs(8)
            ),
            Ok(b"synthetic".to_vec())
        );
        assert_eq!(
            cli.capture(
                &args("[Console]::Out.Write('synthetic'); exit 7"),
                Duration::from_secs(8)
            ),
            Err(Failure::Unavailable)
        );
        assert_eq!(
            cli.capture(
                &args("[Console]::Out.Write(('x' * (9*1024*1024))); Start-Sleep -Seconds 60"),
                Duration::from_secs(8)
            ),
            Err(Failure::InvalidResponse)
        );
    }
    #[test]
    fn windows_vault_capture_drains_output_while_delivering_large_stdin() {
        let cli = fixture();
        let input = vec![b'a'; 1024 * 1024];
        let script = "[Console]::Out.Write(('x' * (1024*1024))); [Console]::Out.Flush(); $text=[Console]::In.ReadToEnd(); [Console]::Out.Write($text.Length)";
        let output = cli
            .capture_with_input(&args(script), Some(&input), Duration::from_secs(10))
            .unwrap();
        assert_eq!(&output[..1024 * 1024], vec![b'x'; 1024 * 1024]);
        assert_eq!(&output[1024 * 1024..], b"1048576");
    }
    #[test]
    fn windows_vault_capture_cancels_and_joins_a_blocked_stdin_writer() {
        let cli = fixture();
        let input = vec![b'a'; LIMIT];
        let began = Instant::now();
        assert_eq!(
            cli.capture_with_input(
                &args("Start-Sleep -Seconds 60"),
                Some(&input),
                Duration::from_secs(2)
            ),
            Err(Failure::Unavailable)
        );
        assert!(
            began.elapsed() < Duration::from_secs(10),
            "writer deadline must include actual cancellation/join"
        );
    }
    #[test]
    fn windows_vault_capture_waits_for_retained_root_and_pipe_holding_descendant_handles() {
        let temp = tempfile::tempdir().unwrap();
        let marker = temp.path().join("owned-processes.txt");
        let escaped = marker.to_string_lossy().replace('\'', "''");
        // Root exits successfully; the child still owns inherited pipes. A leader
        // exit or disappearing PID alone must not become capture success.
        let script = format!(
            "$child=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 60') -NoNewWindow -PassThru; [IO.File]::WriteAllText('{escaped}', \"$PID,$($child.Id)\"); exit 0"
        );
        let worker =
            std::thread::spawn(move || fixture().capture(&args(&script), Duration::from_secs(8)));
        let began = Instant::now();
        let handles = loop {
            if let Ok(text) = std::fs::read_to_string(&marker) {
                let ids = text
                    .split(',')
                    .filter_map(|id| id.parse::<u32>().ok())
                    .collect::<Vec<_>>();
                if ids.len() == 2 {
                    let handles = ids
                        .into_iter()
                        .map(|id| owned(unsafe { OpenProcess(PROCESS_SYNCHRONIZE, 0, id) }))
                        .collect::<Result<Vec<_>>>();
                    if let Ok(handles) = handles {
                        break handles;
                    }
                }
            }
            assert!(
                began.elapsed() < Duration::from_secs(12),
                "owned helper process handles missing"
            );
            std::thread::sleep(Duration::from_millis(5));
        };
        assert_eq!(worker.join().unwrap(), Err(Failure::Unavailable));
        for handle in handles {
            assert_eq!(
                unsafe { WaitForSingleObject(handle.as_raw_handle(), 0) },
                WAIT_OBJECT_0
            );
        }
        assert!(began.elapsed() < Duration::from_secs(15));
    }
}
