//! Stable filesystem identity and private Windows files. No credential reads.
use anyhow::Result;
use std::path::Path;
pub(crate) type Identity = (u64, [u8; 16]);
pub(crate) fn file_identity(file: &std::fs::File) -> Result<Identity> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let metadata = file.metadata()?;
        let mut inode = [0; 16];
        inode[..8].copy_from_slice(&metadata.ino().to_le_bytes());
        Ok((metadata.dev(), inode))
    }
    #[cfg(windows)]
    {
        windows::file_identity(file)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = file;
        anyhow::bail!("Private file identity unavailable")
    }
}
pub(crate) fn identity(path: &Path) -> Result<Identity> {
    #[cfg(unix)]
    {
        use std::{fs, os::unix::fs::MetadataExt};
        let metadata = fs::symlink_metadata(path)?;
        let mut inode = [0; 16];
        inode[..8].copy_from_slice(&metadata.ino().to_le_bytes());
        Ok((metadata.dev(), inode))
    }
    #[cfg(windows)]
    {
        windows::identity(path)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = path;
        anyhow::bail!("Private file identity is unavailable")
    }
}
#[cfg(windows)]
pub(crate) mod windows {
    use super::*;
    use anyhow::{Context as _, ensure};
    use std::{
        fs::{self, File, OpenOptions},
        io,
        mem::size_of,
        os::windows::{
            ffi::OsStrExt,
            fs::{MetadataExt, OpenOptionsExt},
            io::{AsRawHandle, FromRawHandle},
        },
        ptr::null_mut,
    };
    use windows_sys::Win32::{
        Foundation::{GENERIC_READ, GENERIC_WRITE, INVALID_HANDLE_VALUE},
        Security::SECURITY_ATTRIBUTES,
        Storage::FileSystem::{
            BY_HANDLE_FILE_INFORMATION, CREATE_NEW, CreateDirectoryW, CreateFileW,
            FILE_ATTRIBUTE_NORMAL, FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS,
            FILE_FLAG_OPEN_REPARSE_POINT, FILE_ID_INFO, FILE_READ_ATTRIBUTES, FILE_SHARE_READ,
            FILE_SHARE_WRITE, FileIdInfo, GetFileInformationByHandle, GetFileInformationByHandleEx,
            OPEN_EXISTING, READ_CONTROL,
        },
    };
    fn wide(path: &Path) -> Vec<u16> {
        path.as_os_str().encode_wide().chain(Some(0)).collect()
    }
    fn handle(path: &Path) -> Result<File> {
        Ok(OpenOptions::new()
            .access_mode(FILE_READ_ATTRIBUTES | READ_CONTROL)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
            .open(path)?)
    }
    pub(crate) fn identity(path: &Path) -> Result<Identity> {
        let file = handle(path)?;
        file_identity(&file)
    }
    pub(crate) fn file_identity(file: &File) -> Result<Identity> {
        let mut info: FILE_ID_INFO = unsafe { std::mem::zeroed() };
        // SAFETY: live handle and correctly sized writable FILE_ID_INFO.
        ensure!(
            unsafe {
                GetFileInformationByHandleEx(
                    file.as_raw_handle(),
                    FileIdInfo,
                    (&mut info as *mut FILE_ID_INFO).cast(),
                    size_of::<FILE_ID_INFO>() as u32,
                )
            } != 0,
            "Windows file identity is unavailable: {}",
            io::Error::last_os_error()
        );
        Ok((info.VolumeSerialNumber, info.FileId.Identifier))
    }
    pub(crate) fn verify(path: &Path, directory: bool) -> Result<()> {
        let metadata = fs::symlink_metadata(path)?;
        ensure!(
            metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT == 0
                && if directory {
                    metadata.is_dir()
                } else {
                    metadata.is_file()
                },
            "Private path cannot be a reparse point"
        );
        let file = handle(path)?;
        crate::control::verify_file_owner(file.as_raw_handle(), directory)?;
        if !directory {
            let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
            ensure!(
                unsafe { GetFileInformationByHandle(file.as_raw_handle(), &mut info) } != 0,
                "Cannot inspect private file link count"
            );
            ensure!(
                info.nNumberOfLinks == 1,
                "Private file has multiple hard links"
            );
        }
        Ok(())
    }
    pub(crate) fn verify_inherited(path: &Path, container: bool) -> Result<()> {
        let metadata = fs::symlink_metadata(path)?;
        ensure!(
            metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT == 0,
            "Private path cannot be a reparse point"
        );
        let file = handle(path)?;
        crate::control::verify_private_path(file.as_raw_handle(), container)?;
        if metadata.is_file() {
            let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
            ensure!(
                unsafe { GetFileInformationByHandle(file.as_raw_handle(), &mut info) } != 0
                    && info.nNumberOfLinks == 1,
                "Private file link count is unsafe"
            );
        }
        Ok(())
    }
    pub(crate) fn create_directory(path: &Path) -> Result<()> {
        let sid = crate::control::current_sid()?;
        let descriptor = crate::control::private_directory_descriptor(&sid)?;
        let attributes = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor.0,
            bInheritHandle: 0,
        };
        // SAFETY: NUL-terminated path and descriptor/attributes live through call.
        if unsafe { CreateDirectoryW(wide(path).as_ptr(), &attributes) } == 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::AlreadyExists {
                return Err(error.into());
            }
        }
        verify(path, true)
    }
    pub(crate) fn open_file(path: &Path, new: bool) -> Result<File> {
        let sid = crate::control::current_sid()?;
        let descriptor = crate::control::private_descriptor(&sid)?;
        let attributes = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor.0,
            bInheritHandle: 0,
        };
        // Deny delete sharing for the lifetime of authority leases; a renamed
        // lock file must never let another Engine obtain a replacement inode.
        let raw = unsafe {
            CreateFileW(
                wide(path).as_ptr(),
                GENERIC_READ | GENERIC_WRITE | READ_CONTROL,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                &attributes,
                if new { CREATE_NEW } else { OPEN_EXISTING },
                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
                null_mut(),
            )
        };
        if raw == INVALID_HANDLE_VALUE || raw.is_null() {
            return Err(io::Error::last_os_error().into());
        }
        // SAFETY: unique successful CreateFile handle ownership transfers here.
        let file = unsafe { File::from_raw_handle(raw) };
        verify(path, false).context("Validating private Windows file")?;
        Ok(file)
    }
}
