//! Directory-relative staging mutations. Unix uses openat/mkdirat; Windows pins
//! every directory without delete sharing and refuses final reparse points.
use super::*;
use std::fs::OpenOptions;
pub(super) struct PinnedFile {
    pub path: PathBuf,
    file: File,
    identity: Identity,
    size: u64,
    modified: std::time::SystemTime,
}
impl PinnedFile {
    pub fn open(path: &Path) -> Result<Self> {
        ensure!(path.is_absolute(), "Native executable must be absolute");
        let path = path.canonicalize()?;
        let file = native_file::open_regular(&path, false)?;
        let metadata = file.metadata()?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            ensure!(
                metadata.permissions().mode() & 0o111 != 0,
                "Configured native tool is not executable"
            );
        }
        #[cfg(windows)]
        {
            let mut probe = file.try_clone()?;
            let mut signature = [0u8; 2];
            probe.read_exact(&mut signature)?;
            ensure!(
                signature == *b"MZ"
                    && path
                        .extension()
                        .is_some_and(|extension| extension.eq_ignore_ascii_case("exe")),
                "Configured tool must be a native executable"
            );
        }
        Ok(Self {
            identity: native_file::file_identity(&file)?,
            size: metadata.len(),
            modified: metadata.modified()?,
            path,
            file,
        })
    }
    pub fn check(&self) -> Result<()> {
        let metadata = self.file.metadata()?;
        ensure!(
            native_file::file_identity(&self.file)? == self.identity
                && native_file::path_identity(&self.path)? == self.identity
                && metadata.len() == self.size
                && metadata.modified()? == self.modified,
            "Captured native executable changed"
        );
        let current = native_file::open_regular(&self.path, false)?;
        ensure!(
            current.metadata()?.len() == self.size
                && current.metadata()?.modified()? == self.modified,
            "Captured native executable changed"
        );
        Ok(())
    }
}
pub(super) struct Directory {
    pub path: PathBuf,
    file: File,
    identity: Identity,
}
impl Directory {
    pub fn pin(path: &Path) -> Result<Self> {
        ensure!(path.is_absolute(), "Native directory must be absolute");
        let metadata = fs::symlink_metadata(path)?;
        ensure!(
            metadata.is_dir() && !metadata.file_type().is_symlink(),
            "Native directory changed"
        );
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
        let file = options.open(path)?;
        let identity = native_file::file_identity(&file)?;
        let owner = Self {
            path: path.to_owned(),
            file,
            identity,
        };
        owner.check()?;
        Ok(owner)
    }
    pub fn check(&self) -> Result<()> {
        let metadata = fs::symlink_metadata(&self.path)?;
        ensure!(
            metadata.is_dir()
                && !metadata.file_type().is_symlink()
                && native_file::file_identity(&self.file)? == self.identity
                && native_file::path_identity(&self.path)? == self.identity,
            "Pinned native directory changed"
        );
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            ensure!(
                metadata.file_attributes()
                    & windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT
                    == 0,
                "Native directory became a reparse point"
            );
        }
        Ok(())
    }
    pub fn clone_handle(&self) -> Result<Self> {
        self.check()?;
        Ok(Self {
            path: self.path.clone(),
            file: self.file.try_clone()?,
            identity: self.identity,
        })
    }
    pub fn available_bytes(&self) -> Result<u64> {
        self.check()?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            let mut info: libc::statvfs = unsafe { std::mem::zeroed() };
            ensure!(
                unsafe { libc::fstatvfs(self.file.as_raw_fd(), &mut info) } == 0,
                "Could not inspect staging capacity"
            );
            Ok((info.f_bavail as u128)
                .saturating_mul(info.f_frsize as u128)
                .min(u64::MAX as u128) as u64)
        }
        #[cfg(windows)]
        {
            use std::os::windows::ffi::OsStrExt;
            let path = self
                .path
                .as_os_str()
                .encode_wide()
                .chain(Some(0))
                .collect::<Vec<_>>();
            let mut available = 0u64;
            ensure!(
                unsafe {
                    windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW(
                        path.as_ptr(),
                        &mut available,
                        std::ptr::null_mut(),
                        std::ptr::null_mut(),
                    )
                } != 0,
                "Could not inspect staging capacity"
            );
            Ok(available)
        }
        #[cfg(not(any(unix, windows)))]
        {
            anyhow::bail!("Staging capacity inspection unavailable")
        }
    }
    pub fn create_directory(&self, name: &str) -> Result<Self> {
        ensure!(
            !name.is_empty() && !name.contains(['/', '\\', '\0']) && !matches!(name, "." | ".."),
            "Expected single private directory component"
        );
        self.check()?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            let c = std::ffi::CString::new(name)?;
            ensure!(
                unsafe { libc::mkdirat(self.file.as_raw_fd(), c.as_ptr(), 0o700) } == 0,
                "Private destination exists or cannot be created"
            );
        }
        #[cfg(windows)]
        {
            let path = self.path.join(name);
            ensure!(
                fs::symlink_metadata(&path)
                    .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound),
                "Private destination exists"
            );
            fs::create_dir(&path)?;
            native_file::private_directory(&path)?;
        }
        #[cfg(not(any(unix, windows)))]
        {
            anyhow::bail!("Private materialization is unavailable");
        }
        self.check()?;
        let result = Self::pin(&self.path.join(name))?;
        native_file::private_directory(&result.path)?;
        Ok(result)
    }
    pub fn create_file(&self, name: &str) -> Result<File> {
        ensure!(
            !name.is_empty() && !name.contains(['/', '\\', '\0']) && !matches!(name, "." | ".."),
            "Expected single private file component"
        );
        self.check()?;
        #[cfg(unix)]
        {
            use std::os::fd::{AsRawFd, FromRawFd};
            let c = std::ffi::CString::new(name)?;
            let fd = unsafe {
                libc::openat(
                    self.file.as_raw_fd(),
                    c.as_ptr(),
                    libc::O_RDWR
                        | libc::O_CREAT
                        | libc::O_EXCL
                        | libc::O_NOFOLLOW
                        | libc::O_CLOEXEC,
                    0o600,
                )
            };
            ensure!(fd >= 0, "Private file exists or cannot be created");
            Ok(unsafe { File::from_raw_fd(fd) })
        }
        #[cfg(not(unix))]
        {
            native_file::create_private_file(&self.path.join(name))
        }
    }
}
pub(super) fn set_executable(file: &File, executable: bool) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(fs::Permissions::from_mode(if executable {
            0o700
        } else {
            0o600
        }))?;
    }
    #[cfg(not(unix))]
    {
        let _ = (file, executable);
    }
    Ok(())
}
