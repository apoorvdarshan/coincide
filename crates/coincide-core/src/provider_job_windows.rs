//! A suspended child joins a kill-on-close Job before any provider code runs.
//! This closes descendants' inherited pipes before the owning worker joins I/O.
use anyhow::{Result, ensure};
use std::{
    io,
    mem::size_of,
    os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle},
    process::Child,
    ptr::null,
};
use windows_sys::Win32::{
    Foundation::{HANDLE, INVALID_HANDLE_VALUE},
    System::{
        Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
        },
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
            SetInformationJobObject, TerminateJobObject,
        },
        Threading::{OpenThread, ResumeThread, THREAD_SUSPEND_RESUME},
    },
};
pub(super) struct Job(OwnedHandle);
fn owned(raw: HANDLE) -> Result<OwnedHandle> {
    if raw.is_null() || raw == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error().into());
    }
    // SAFETY: successful Win32 creation transfers unique handle ownership.
    Ok(unsafe { OwnedHandle::from_raw_handle(raw) })
}
impl Job {
    pub(super) fn attach_and_resume(child: &Child) -> Result<Self> {
        let handle = owned(unsafe { CreateJobObjectW(null(), null()) })?;
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        ensure!(
            unsafe {
                SetInformationJobObject(
                    handle.as_raw_handle(),
                    JobObjectExtendedLimitInformation,
                    (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                    size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                )
            } != 0,
            "Cannot configure provider Job: {}",
            io::Error::last_os_error()
        );
        ensure!(
            unsafe { AssignProcessToJobObject(handle.as_raw_handle(), child.as_raw_handle()) } != 0,
            "Cannot isolate provider child Job: {}",
            io::Error::last_os_error()
        );
        let job = Self(handle);
        let snapshot = owned(unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) })?;
        let mut entry: THREADENTRY32 = unsafe { std::mem::zeroed() };
        entry.dwSize = size_of::<THREADENTRY32>() as u32;
        let mut present = unsafe { Thread32First(snapshot.as_raw_handle(), &mut entry) };
        let mut resumed = false;
        while present != 0 {
            if entry.th32OwnerProcessID == child.id() {
                let thread =
                    owned(unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID) })?;
                ensure!(
                    unsafe { ResumeThread(thread.as_raw_handle()) } == 1,
                    "Unexpected provider primary-thread suspend count"
                );
                resumed = true;
                break;
            }
            entry.dwSize = size_of::<THREADENTRY32>() as u32;
            present = unsafe { Thread32Next(snapshot.as_raw_handle(), &mut entry) };
        }
        ensure!(resumed, "Suspended provider primary thread is unavailable");
        Ok(job)
    }
}
impl Drop for Job {
    fn drop(&mut self) {
        unsafe {
            TerminateJobObject(self.0.as_raw_handle(), 1);
        }
    }
}
