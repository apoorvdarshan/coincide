//! Windows local control uses a single retained, owner-only named pipe.
//!
//! No discovery/token file is needed: directory identity and user SID determine
//! the name. A first-instance reservation prevents another server from joining
//! the same name. Clients verify the pipe owner/DACL before sending a command.
use super::{MAX_FRAME, Server, read_frame, write_frame};
use crate::api::SharedEngine;
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    ffi::c_void,
    fs::{File, OpenOptions},
    io::{self, Read, Write},
    os::windows::{
        ffi::OsStrExt,
        fs::OpenOptionsExt,
        io::{AsRawHandle, FromRawHandle, OwnedHandle},
    },
    path::{Path, PathBuf},
    ptr::{null, null_mut},
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::{Duration, Instant},
};
use windows_sys::Win32::{
    Foundation::{
        ERROR_BROKEN_PIPE, ERROR_IO_INCOMPLETE, ERROR_IO_PENDING, ERROR_NO_DATA, ERROR_PIPE_BUSY,
        ERROR_PIPE_CONNECTED, ERROR_PIPE_NOT_CONNECTED, GENERIC_READ, GENERIC_WRITE, HANDLE,
        INVALID_HANDLE_VALUE, LocalFree, WAIT_OBJECT_0, WAIT_TIMEOUT,
    },
    Security::{
        ACCESS_ALLOWED_ACE, ACE_HEADER, ACL,
        Authorization::{
            ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
            GetSecurityInfo, SDDL_REVISION_1, SE_FILE_OBJECT, SE_KERNEL_OBJECT, SE_OBJECT_TYPE,
        },
        DACL_SECURITY_INFORMATION, GetAce, GetSecurityDescriptorControl, GetTokenInformation,
        OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID, SE_DACL_PROTECTED,
        SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER, TokenUser,
    },
    Storage::FileSystem::{
        CreateFileW, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_FIRST_PIPE_INSTANCE,
        FILE_FLAG_OVERLAPPED, FILE_ID_INFO, FILE_READ_ATTRIBUTES, FILE_SHARE_READ,
        FILE_SHARE_WRITE, FileIdInfo, GetFileInformationByHandleEx, GetFinalPathNameByHandleW,
        OPEN_EXISTING, PIPE_ACCESS_DUPLEX, READ_CONTROL, ReadFile, SECURITY_IDENTIFICATION,
        SECURITY_SQOS_PRESENT, VOLUME_NAME_GUID, WriteFile,
    },
    System::{
        IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED},
        Pipes::{
            ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, PIPE_READMODE_BYTE,
            PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_WAIT,
        },
        Threading::{CreateEventW, GetCurrentProcess, OpenProcessToken, WaitForSingleObject},
    },
};

const SERVER_TIMEOUT: Duration = Duration::from_secs(2);
const CLIENT_TIMEOUT: Duration = Duration::from_secs(10);
const RESPONSE_ACK: u8 = 6;

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}
fn win_ok(ok: i32) -> io::Result<()> {
    if ok == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}
fn owned(handle: HANDLE) -> io::Result<OwnedHandle> {
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        Err(io::Error::last_os_error())
    } else {
        // Ownership transfers from the successful Win32 creation function.
        Ok(unsafe { OwnedHandle::from_raw_handle(handle) })
    }
}
pub(crate) struct LocalAllocation(pub(crate) *mut c_void);
impl Drop for LocalAllocation {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                LocalFree(self.0);
            }
        }
    }
}
fn sid_string(sid: PSID) -> Result<String> {
    ensure!(!sid.is_null(), "Control endpoint has no owner SID");
    let mut string = null_mut();
    win_ok(unsafe { ConvertSidToStringSidW(sid, &mut string) })?;
    let allocation = LocalAllocation(string.cast());
    // ConvertSidToStringSidW allocates a NUL-terminated SID string. SID strings
    // are short ASCII; bound the traversal independently of the API contract.
    let mut length = 0;
    while length < 256 && unsafe { *string.add(length) } != 0 {
        length += 1;
    }
    ensure!(length < 256, "Invalid owner SID");
    let result = String::from_utf16(unsafe { std::slice::from_raw_parts(string, length) })?;
    drop(allocation);
    Ok(result)
}
pub(crate) fn current_sid() -> Result<String> {
    let mut token = null_mut();
    win_ok(unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) })?;
    let token = owned(token)?;
    let mut needed = 0;
    unsafe {
        GetTokenInformation(token.as_raw_handle(), TokenUser, null_mut(), 0, &mut needed);
    }
    ensure!(needed > 0 && needed <= 64 * 1024, "Invalid user token size");
    // usize storage guarantees alignment for TOKEN_USER and its embedded SID.
    let mut storage = vec![0usize; (needed as usize).div_ceil(size_of::<usize>())];
    win_ok(unsafe {
        GetTokenInformation(
            token.as_raw_handle(),
            TokenUser,
            storage.as_mut_ptr().cast(),
            needed,
            &mut needed,
        )
    })?;
    let user = unsafe { &*storage.as_ptr().cast::<TOKEN_USER>() };
    sid_string(user.User.Sid)
}

struct Endpoint {
    name: Vec<u16>,
    sid: String,
    // Deny directory rename/delete while the endpoint is owned, preventing its
    // file identity from being recycled beneath an active server.
    _directory: File,
}
fn endpoint(path: &Path) -> Result<Endpoint> {
    let parent = path
        .parent()
        .context("Control endpoint requires a data directory")?;
    let filename = path
        .file_name()
        .context("Control endpoint requires a filename")?;
    let directory = OpenOptions::new()
        .access_mode(FILE_READ_ATTRIBUTES)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(parent)
        .context("Opening control data directory")?;
    ensure!(
        directory.metadata()?.is_dir(),
        "Control parent is not a directory"
    );
    let mut information: FILE_ID_INFO = unsafe { std::mem::zeroed() };
    win_ok(unsafe {
        GetFileInformationByHandleEx(
            directory.as_raw_handle(),
            FileIdInfo,
            (&mut information as *mut FILE_ID_INFO).cast(),
            size_of::<FILE_ID_INFO>() as u32,
        )
    })?;
    // A volume GUID avoids collisions between cloned volumes with the same
    // serial number. Remote shares without a local volume identity fail closed.
    let mut volume_path = vec![0u16; 32768];
    let length = unsafe {
        GetFinalPathNameByHandleW(
            directory.as_raw_handle(),
            volume_path.as_mut_ptr(),
            volume_path.len() as u32,
            VOLUME_NAME_GUID,
        )
    };
    ensure!(
        length > 0 && (length as usize) < volume_path.len(),
        "Control data directory must be on a local identifiable Windows volume"
    );
    let volume_path = String::from_utf16(&volume_path[..length as usize])?;
    let end = volume_path
        .find('}')
        .context("Control data directory has no volume GUID")?;
    ensure!(
        volume_path.starts_with(r"\\?\Volume{"),
        "Control data directory must be on a local volume"
    );
    let sid = current_sid()?;
    let mut hash = Sha256::new();
    hash.update(b"Coincide Rust local control v1\0");
    hash.update(sid.as_bytes());
    hash.update(volume_path[..=end].to_ascii_lowercase().as_bytes());
    hash.update(information.FileId.Identifier);
    for unit in filename.encode_wide() {
        let unit = if (b'A' as u16..=b'Z' as u16).contains(&unit) {
            unit + 32
        } else {
            unit
        };
        hash.update(unit.to_le_bytes());
    }
    let name = wide(&format!(
        r"\\.\pipe\CoincideRust-{}",
        crate::digest_hex::lower_hex(hash.finalize())
    ));
    Ok(Endpoint {
        name,
        sid,
        _directory: directory,
    })
}
pub(crate) fn private_descriptor(sid: &str) -> Result<LocalAllocation> {
    descriptor_text(&format!("O:{sid}D:P(A;;GA;;;{sid})"))
}
pub(crate) fn private_directory_descriptor(sid: &str) -> Result<LocalAllocation> {
    descriptor_text(&format!("O:{sid}D:P(A;OICI;FA;;;{sid})"))
}
fn descriptor_text(text: &str) -> Result<LocalAllocation> {
    let text = wide(text);
    let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
    win_ok(unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            text.as_ptr(),
            SDDL_REVISION_1,
            &mut descriptor,
            null_mut(),
        )
    })?;
    Ok(LocalAllocation(descriptor))
}
fn verify_owner(handle: HANDLE, sid: &str) -> Result<()> {
    verify_owner_kind(handle, sid, SE_KERNEL_OBJECT, 0)
}
pub(crate) fn verify_file_owner(handle: HANDLE, directory: bool) -> Result<()> {
    verify_owner_kind(
        handle,
        &current_sid()?,
        SE_FILE_OBJECT,
        if directory { 3 } else { 0 },
    )
}
/// Existing application containers may inherit SYSTEM/Administrators grants;
/// private children accept only their owner, including inherited owner ACEs.
pub(crate) fn verify_private_path(handle: HANDLE, container: bool) -> Result<()> {
    let sid = current_sid()?;
    let mut owner: PSID = null_mut();
    let mut dacl: *mut ACL = null_mut();
    let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
    let error = unsafe {
        GetSecurityInfo(
            handle,
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut owner,
            null_mut(),
            &mut dacl,
            null_mut(),
            &mut descriptor,
        )
    };
    ensure!(error == 0, "Cannot inspect private file ACL");
    let _allocation = LocalAllocation(descriptor);
    ensure!(
        sid_string(owner)? == sid && !dacl.is_null(),
        "Private file belongs to another owner or has no DACL"
    );
    let count = unsafe { (*dacl).AceCount };
    ensure!(count > 0 && count <= 32, "Invalid private file ACL");
    for index in 0..count {
        let mut ace = null_mut();
        win_ok(unsafe { GetAce(dacl, index as u32, &mut ace) })?;
        let header = unsafe { &*ace.cast::<ACE_HEADER>() };
        ensure!(
            header.AceType == 0
                && header.AceFlags & !0x13 == 0
                && header.AceSize as usize >= size_of::<ACCESS_ALLOWED_ACE>(),
            "Unexpected private file ACL entry"
        );
        let ace = unsafe { &*ace.cast::<ACCESS_ALLOWED_ACE>() };
        let allowed = sid_string((&ace.SidStart as *const u32).cast_mut().cast())?;
        ensure!(
            allowed == sid
                || (container && matches!(allowed.as_str(), "S-1-5-18" | "S-1-5-32-544")),
            "Private file grants another user access"
        );
    }
    Ok(())
}
fn verify_owner_kind(handle: HANDLE, sid: &str, kind: SE_OBJECT_TYPE, flags: u8) -> Result<()> {
    let mut owner: PSID = null_mut();
    let mut dacl: *mut ACL = null_mut();
    let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
    let error = unsafe {
        GetSecurityInfo(
            handle,
            kind,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut owner,
            null_mut(),
            &mut dacl,
            null_mut(),
            &mut descriptor,
        )
    };
    if error != 0 {
        return Err(io::Error::from_raw_os_error(error as i32).into());
    }
    let _allocation = LocalAllocation(descriptor);
    ensure!(
        sid_string(owner)? == sid,
        "Control endpoint belongs to another user"
    );
    let mut control = 0;
    let mut revision = 0;
    win_ok(unsafe { GetSecurityDescriptorControl(descriptor, &mut control, &mut revision) })?;
    ensure!(
        control & SE_DACL_PROTECTED != 0 && !dacl.is_null() && unsafe { (*dacl).AceCount } == 1,
        "Control endpoint does not have a private owner-only ACL"
    );
    let mut ace = null_mut();
    win_ok(unsafe { GetAce(dacl, 0, &mut ace) })?;
    let header = unsafe { &*ace.cast::<ACE_HEADER>() };
    // ACCESS_ALLOWED_ACE_TYPE is 0. No inherited/conditional/deny ACE can stand
    // in for the single explicit owner grant created above.
    ensure!(
        header.AceType == 0
            && header.AceFlags == flags
            && header.AceSize as usize >= size_of::<ACCESS_ALLOWED_ACE>(),
        "Unexpected control endpoint ACL"
    );
    let ace = unsafe { &*ace.cast::<ACCESS_ALLOWED_ACE>() };
    let allowed_sid = (&ace.SidStart as *const u32).cast_mut().cast();
    ensure!(
        sid_string(allowed_sid)? == sid,
        "Control endpoint grants access to another user"
    );
    Ok(())
}

/// The buffers and OVERLAPPED stay alive until completion, including timeout
/// cancellation. Returning early without draining cancellation would be unsafe.
struct Operation {
    handle: HANDLE,
    overlapped: Box<OVERLAPPED>,
    event: OwnedHandle,
    pending: bool,
}
impl Operation {
    fn new(handle: HANDLE) -> io::Result<Self> {
        let event = owned(unsafe { CreateEventW(null(), 1, 0, null()) })?;
        let mut overlapped: Box<OVERLAPPED> = Box::new(unsafe { std::mem::zeroed() });
        overlapped.hEvent = event.as_raw_handle();
        Ok(Self {
            handle,
            overlapped,
            event,
            pending: false,
        })
    }
    fn started(&mut self, ok: i32) -> io::Result<()> {
        if ok == 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(ERROR_IO_PENDING as i32) {
                return Err(error);
            }
        }
        self.pending = true;
        Ok(())
    }
    fn wait(
        &mut self,
        deadline: Option<Instant>,
        mut tick: impl FnMut() -> io::Result<()>,
    ) -> io::Result<u32> {
        loop {
            tick()?;
            let delay = if let Some(deadline) = deadline {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "Control I/O deadline expired",
                    ));
                }
                remaining.as_millis().clamp(1, 20) as u32
            } else {
                20
            };
            match unsafe { WaitForSingleObject(self.event.as_raw_handle(), delay) } {
                WAIT_OBJECT_0 => {
                    let mut bytes = 0;
                    let ok = unsafe {
                        GetOverlappedResult(self.handle, &*self.overlapped, &mut bytes, 0)
                    };
                    // An event means the kernel has completed this request,
                    // successfully or with a terminal I/O error.
                    if ok == 0 {
                        let error = io::Error::last_os_error();
                        // Defensive: never release an OVERLAPPED buffer if the
                        // kernel still considers it outstanding.
                        self.pending = error.raw_os_error() == Some(ERROR_IO_INCOMPLETE as i32);
                        return Err(error);
                    }
                    self.pending = false;
                    return Ok(bytes);
                }
                WAIT_TIMEOUT => {}
                _ => return Err(io::Error::last_os_error()),
            }
        }
    }
}
impl Drop for Operation {
    fn drop(&mut self) {
        if self.pending {
            unsafe {
                CancelIoEx(self.handle, &*self.overlapped);
                let mut ignored = 0;
                GetOverlappedResult(self.handle, &*self.overlapped, &mut ignored, 1);
            }
        }
    }
}
struct PipeStream<'a> {
    handle: &'a OwnedHandle,
    deadline: Instant,
}
impl Read for PipeStream<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        let mut operation = Operation::new(self.handle.as_raw_handle())?;
        let ok = unsafe {
            ReadFile(
                self.handle.as_raw_handle(),
                buffer.as_mut_ptr(),
                buffer.len().min(u32::MAX as usize) as u32,
                null_mut(),
                &mut *operation.overlapped,
            )
        };
        operation.started(ok)?;
        Ok(operation.wait(Some(self.deadline), || Ok(()))? as usize)
    }
}
impl Write for PipeStream<'_> {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        let mut operation = Operation::new(self.handle.as_raw_handle())?;
        let ok = unsafe {
            WriteFile(
                self.handle.as_raw_handle(),
                buffer.as_ptr(),
                buffer.len().min(u32::MAX as usize) as u32,
                null_mut(),
                &mut *operation.overlapped,
            )
        };
        operation.started(ok)?;
        Ok(operation.wait(Some(self.deadline), || Ok(()))? as usize)
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
fn accept(handle: &OwnedHandle, stop: &AtomicBool, engine: &SharedEngine) -> Result<bool> {
    let mut operation = Operation::new(handle.as_raw_handle())?;
    let ok = unsafe { ConnectNamedPipe(handle.as_raw_handle(), &mut *operation.overlapped) };
    if ok == 0 && io::Error::last_os_error().raw_os_error() == Some(ERROR_PIPE_CONNECTED as i32) {
        return Ok(true);
    }
    operation.started(ok)?;
    let result = operation.wait(None, || {
        if stop.load(Ordering::Relaxed) {
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "Control server stopped",
            ));
        }
        if let Ok(mut engine) = engine.lock() {
            engine.poll();
        }
        Ok(())
    });
    match result {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::Interrupted => Ok(false),
        Err(error) => Err(error.into()),
    }
}

pub fn serve(path: PathBuf, engine: SharedEngine) -> Result<Server> {
    std::fs::create_dir_all(
        path.parent()
            .context("Control endpoint requires a data directory")?,
    )?;
    let endpoint = endpoint(&path)?;
    let descriptor = private_descriptor(&endpoint.sid)?;
    let attributes = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor.0,
        bInheritHandle: 0,
    };
    let pipe = owned(unsafe {
        CreateNamedPipeW(
            endpoint.name.as_ptr(),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            64 * 1024,
            64 * 1024,
            0,
            &attributes,
        )
    })
    .context("Cannot reserve private control pipe; another instance or name collision may exist")?;
    verify_owner(pipe.as_raw_handle(), &endpoint.sid)?;
    Ok(Server::spawn(move |stopping| {
        let _endpoint = endpoint;
        while !stopping.load(Ordering::Relaxed) {
            match accept(&pipe, &stopping, &engine) {
                Ok(true) => {}
                Ok(false) => break,
                Err(error) => {
                    let disconnected = error
                        .downcast_ref::<io::Error>()
                        .and_then(io::Error::raw_os_error)
                        .is_some_and(|code| {
                            [ERROR_NO_DATA, ERROR_BROKEN_PIPE, ERROR_PIPE_NOT_CONNECTED]
                                .contains(&(code as u32))
                        });
                    unsafe {
                        DisconnectNamedPipe(pipe.as_raw_handle());
                    }
                    if disconnected {
                        continue;
                    }
                    eprintln!("Windows control listener stopped: {error}");
                    break;
                }
            }
            let mut stream = PipeStream {
                handle: &pipe,
                deadline: Instant::now() + SERVER_TIMEOUT,
            };
            let response = (|| -> Result<Value> {
                let request = read_frame(&mut stream)?;
                Ok(engine
                    .lock()
                    .map_err(|_| anyhow::anyhow!("Engine lock failed"))?
                    .dispatch(request))
            })()
            .unwrap_or_else(|error| json!({"error":{"message":error.to_string()}}));
            let response = if serde_json::to_vec(&response)
                .is_ok_and(|bytes| bytes.len() as u64 >= MAX_FRAME)
            {
                json!({"id":response["id"],"error":{"message":"Response exceeds 4 MiB; use itemLimit/itemOffset with threads.read"}})
            } else {
                response
            };
            stream.deadline = Instant::now() + SERVER_TIMEOUT;
            if write_frame(&mut stream, &response).is_ok() {
                // DisconnectNamedPipe discards unread output. An explicit ack
                // proves the client consumed the response, including app.quit.
                // FlushFileBuffers cannot provide a cancellable deadline here.
                stream.deadline = Instant::now() + SERVER_TIMEOUT;
                let mut ack = [0];
                let _ = stream.read_exact(&mut ack);
            }
            unsafe {
                DisconnectNamedPipe(pipe.as_raw_handle());
            }
        }
    }))
}

fn connect(endpoint: &Endpoint, deadline: Instant) -> Result<OwnedHandle> {
    loop {
        let handle = unsafe {
            CreateFileW(
                endpoint.name.as_ptr(),
                GENERIC_READ | GENERIC_WRITE | READ_CONTROL,
                0,
                null(),
                OPEN_EXISTING,
                FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                null_mut(),
            )
        };
        if handle != INVALID_HANDLE_VALUE {
            let handle = owned(handle)?;
            verify_owner(handle.as_raw_handle(), &endpoint.sid)
                .context("Refusing an untrusted control endpoint")?;
            return Ok(handle);
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(ERROR_PIPE_BUSY as i32) {
            return Err(error).context("Cannot reach the Rust Coincide instance");
        }
        ensure!(
            Instant::now() < deadline,
            "Timed out waiting for the Rust Coincide instance"
        );
        thread::sleep(Duration::from_millis(20));
    }
}
pub fn request(path: &Path, request: &Value) -> Result<Value> {
    let endpoint = endpoint(path)?;
    let deadline = Instant::now() + CLIENT_TIMEOUT;
    let pipe = connect(&endpoint, deadline)?;
    let mut stream = PipeStream {
        handle: &pipe,
        deadline,
    };
    write_frame(&mut stream, request).context("Sending control request")?;
    let response = read_frame(&mut stream).context("Reading control reply")?;
    stream
        .write_all(&[RESPONSE_ACK])
        .context("Acknowledging control reply")?;
    Ok(response)
}

#[cfg(test)]
#[path = "control_windows_tests.rs"]
mod tests;
