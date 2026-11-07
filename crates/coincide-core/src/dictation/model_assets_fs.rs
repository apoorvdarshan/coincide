//! A private pinned model directory. Unix mutations are relative to its open
//! descriptor; Windows holds a directory handle without delete sharing.
use super::{Error, Result};
use crate::native_file::{self, Identity};
use std::{
    fs::{self, File, OpenOptions},
    path::{Path, PathBuf},
};
pub(super) struct Directory {
    pub path: PathBuf,
    pub file: File,
    pub identity: Identity,
}
impl Directory {
    pub fn open(path: PathBuf) -> Result<Self> {
        native_file::private_directory(&path).map_err(|_| Error::Storage)?;
        let mut options = OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC);
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            use windows_sys::Win32::Storage::FileSystem::*;
            options
                .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
                .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE);
        }
        let file = options.open(&path).map_err(|_| Error::Storage)?;
        let identity = native_file::file_identity(&file).map_err(|_| Error::Storage)?;
        let result = Self {
            path,
            file,
            identity,
        };
        result.check()?;
        Ok(result)
    }
    pub fn check(&self) -> Result<()> {
        if native_file::file_identity(&self.file).map_err(|_| Error::Changed)? != self.identity {
            return Err(Error::Changed);
        }
        let metadata = fs::symlink_metadata(&self.path).map_err(|_| Error::Changed)?;
        if !metadata.is_dir()
            || metadata.file_type().is_symlink()
            || native_file::path_identity(&self.path).map_err(|_| Error::Changed)? != self.identity
        {
            return Err(Error::Changed);
        }
        Ok(())
    }
    pub fn open_file(&self, name: &str) -> Result<File> {
        self.check()?;
        #[cfg(unix)]
        {
            use std::os::fd::{AsRawFd, FromRawFd};
            let name = std::ffi::CString::new(name).map_err(|_| Error::Storage)?;
            let fd = unsafe {
                libc::openat(
                    self.file.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if fd < 0 {
                return Err(
                    if std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound {
                        Error::NotDownloaded
                    } else {
                        Error::Changed
                    },
                );
            }
            let file = unsafe { File::from_raw_fd(fd) };
            if !file.metadata().map_err(|_| Error::Storage)?.is_file() {
                return Err(Error::Changed);
            }
            Ok(file)
        }
        #[cfg(not(unix))]
        {
            native_file::open_regular(&self.path.join(name), false).map_err(|error| {
                if self.path.join(name).exists() {
                    let _ = error;
                    Error::Changed
                } else {
                    Error::NotDownloaded
                }
            })
        }
    }
    pub fn create(&self, name: &str) -> Result<File> {
        self.check()?;
        #[cfg(unix)]
        {
            use std::os::fd::{AsRawFd, FromRawFd};
            let name = std::ffi::CString::new(name).map_err(|_| Error::Storage)?;
            let fd = unsafe {
                libc::openat(
                    self.file.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDWR
                        | libc::O_CREAT
                        | libc::O_EXCL
                        | libc::O_NOFOLLOW
                        | libc::O_CLOEXEC,
                    0o600,
                )
            };
            if fd < 0 {
                return Err(Error::Storage);
            }
            Ok(unsafe { File::from_raw_fd(fd) })
        }
        #[cfg(not(unix))]
        {
            native_file::create_private_file(&self.path.join(name)).map_err(|_| Error::Storage)
        }
    }
    pub fn link_no_replace(&self, source: &str, destination: &str) -> Result<()> {
        self.check()?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            let source = std::ffi::CString::new(source).map_err(|_| Error::Storage)?;
            let destination = std::ffi::CString::new(destination).map_err(|_| Error::Storage)?;
            if unsafe {
                libc::linkat(
                    self.file.as_raw_fd(),
                    source.as_ptr(),
                    self.file.as_raw_fd(),
                    destination.as_ptr(),
                    0,
                )
            } != 0
            {
                return Err(Error::ExistingPreserved);
            }
        }
        #[cfg(not(unix))]
        {
            fs::hard_link(self.path.join(source), self.path.join(destination))
                .map_err(|_| Error::ExistingPreserved)?;
        }
        self.check()
    }
    pub fn unlink_owned(&self, name: &str, expected: Identity) -> Result<()> {
        self.check()?;
        let current = self.open_file(name)?;
        if native_file::file_identity(&current).map_err(|_| Error::Changed)? != expected {
            return Err(Error::Changed);
        }
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            let name = std::ffi::CString::new(name).map_err(|_| Error::Storage)?;
            if unsafe { libc::unlinkat(self.file.as_raw_fd(), name.as_ptr(), 0) } != 0 {
                return Err(Error::Storage);
            }
        }
        #[cfg(not(unix))]
        {
            drop(current);
            fs::remove_file(self.path.join(name)).map_err(|_| Error::Storage)?;
        }
        Ok(())
    }
    /// Atomically move the current name out before checking identity. A
    /// replacement is restored without overwrite or retained for recovery.
    pub fn quarantine(&self, name: &str, temporary: &str) -> Result<()> {
        self.check()?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            let source = std::ffi::CString::new(name).map_err(|_| Error::Storage)?;
            let destination = std::ffi::CString::new(temporary).map_err(|_| Error::Storage)?;
            #[cfg(target_os = "linux")]
            let moved = unsafe {
                libc::syscall(
                    libc::SYS_renameat2,
                    self.file.as_raw_fd(),
                    source.as_ptr(),
                    self.file.as_raw_fd(),
                    destination.as_ptr(),
                    libc::RENAME_NOREPLACE,
                )
            };
            #[cfg(target_os = "macos")]
            let moved = unsafe {
                libc::renameatx_np(
                    self.file.as_raw_fd(),
                    source.as_ptr(),
                    self.file.as_raw_fd(),
                    destination.as_ptr(),
                    libc::RENAME_EXCL,
                )
            };
            #[cfg(not(any(target_os = "linux", target_os = "macos")))]
            return Err(Error::Unavailable);
            #[cfg(any(target_os = "linux", target_os = "macos"))]
            if moved != 0 {
                return Err(Error::Storage);
            }
        }
        #[cfg(windows)]
        {
            use std::os::windows::ffi::OsStrExt;
            let source: Vec<u16> = self
                .path
                .join(name)
                .as_os_str()
                .encode_wide()
                .chain(Some(0))
                .collect();
            let destination: Vec<u16> = self
                .path
                .join(temporary)
                .as_os_str()
                .encode_wide()
                .chain(Some(0))
                .collect();
            if unsafe {
                windows_sys::Win32::Storage::FileSystem::MoveFileExW(
                    source.as_ptr(),
                    destination.as_ptr(),
                    0,
                )
            } == 0
            {
                return Err(Error::Storage);
            }
        }
        #[cfg(not(any(unix, windows)))]
        return Err(Error::Unavailable);
        Ok(())
    }
    pub fn available_bytes(&self) -> Result<u64> {
        self.check()?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            let mut value: libc::statvfs = unsafe { std::mem::zeroed() };
            if unsafe { libc::fstatvfs(self.file.as_raw_fd(), &mut value) } != 0 {
                return Err(Error::Storage);
            }
            Ok((value.f_bavail as u64).saturating_mul(value.f_frsize as u64))
        }
        #[cfg(windows)]
        {
            use std::os::windows::ffi::OsStrExt;
            let path: Vec<u16> = self.path.as_os_str().encode_wide().chain(Some(0)).collect();
            let mut available = 0u64;
            if unsafe {
                windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW(
                    path.as_ptr(),
                    &mut available,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                )
            } == 0
            {
                return Err(Error::Storage);
            }
            Ok(available)
        }
        #[cfg(not(any(unix, windows)))]
        {
            Err(Error::Unavailable)
        }
    }
}
pub(super) fn identity(file: &File) -> Result<Identity> {
    native_file::file_identity(file).map_err(|_| Error::Storage)
}
pub(super) fn canonical_data_root(path: &Path) -> Result<PathBuf> {
    let path = path.canonicalize().map_err(|_| Error::Storage)?;
    if !path.is_absolute() || !path.is_dir() {
        return Err(Error::Storage);
    }
    Ok(path)
}
