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
        #[cfg(not(windows))]
        let file = native_file::open_regular(&path, false)?;
        #[cfg(windows)]
        let file = {
            use std::os::windows::fs::OpenOptionsExt;
            OpenOptions::new()
                .read(true)
                .custom_flags(windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT)
                .share_mode(windows_sys::Win32::Storage::FileSystem::FILE_SHARE_READ)
                .open(&path)?
        };
        let metadata = file.metadata()?;
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            ensure!(
                metadata.is_file()
                    && metadata.file_attributes()
                        & windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT
                        == 0,
                "Native executable is not a regular file"
            );
        }
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
    pub fn child_cwd(&self) -> Result<File> {
        self.check()?;
        Ok(self.file.try_clone()?)
    }
    pub fn hold_read_only(&self, name: &str) -> Result<File> {
        self.check()?;
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            let path = self.path.join(name);
            let file = OpenOptions::new()
                .read(true)
                .custom_flags(windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT)
                .share_mode(windows_sys::Win32::Storage::FileSystem::FILE_SHARE_READ)
                .open(&path)?;
            use std::os::windows::fs::MetadataExt;
            ensure!(
                file.metadata()?.is_file()
                    && file.metadata()?.file_attributes()
                        & windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT
                        == 0
                    && native_file::file_identity(&file)? == native_file::path_identity(&path)?,
                "Private Git configuration changed"
            );
            Ok(file)
        }
        #[cfg(not(windows))]
        {
            self.open_child(std::ffi::OsStr::new(name))
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

impl Directory {
    /// Count actual private files during the owned process. Aggregate disk cap
    /// is sampled (soft between polls); individual Unix files also have RLIMIT.
    /// Never follows symlinks, sockets, devices or a changed directory.
    pub fn inventory(&self, limit: usize) -> Result<(u64, u64)> {
        fn scan(
            directory: &Directory,
            count: &mut usize,
            limit: usize,
            total: &mut u64,
            largest: &mut u64,
            depth: usize,
        ) -> Result<()> {
            ensure!(depth <= 32, "Private Git directory nesting exceeds bound");
            directory.check()?;
            for name in directory.names(limit.saturating_sub(*count))? {
                *count += 1;
                ensure!(*count <= limit, "Private Git file count exceeds bound");
                let file = match directory.open_child(&name) {
                    Ok(file) => file,
                    // Git atomically renames its own temporary pack/index files.
                    // Disappeared entries are sampled again on the next poll;
                    // aggregate size is a soft cap between polls, not a quota.
                    Err(error)
                        if error
                            .downcast_ref::<std::io::Error>()
                            .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
                    {
                        continue;
                    }
                    Err(error) => return Err(error),
                };
                let metadata = file.metadata()?;
                if metadata.is_dir() {
                    let child = Directory {
                        path: directory.path.join(&name),
                        identity: native_file::file_identity(&file)?,
                        file,
                    };
                    scan(&child, count, limit, total, largest, depth + 1)?;
                } else {
                    ensure!(metadata.is_file(), "Private Git contains a special file");
                    *total = total
                        .checked_add(metadata.len())
                        .context("Private Git byte count overflow")?;
                    *largest = (*largest).max(metadata.len());
                }
            }
            directory.check()?;
            Ok(())
        }
        let (mut count, mut total, mut largest) = (0, 0, 0);
        scan(self, &mut count, limit, &mut total, &mut largest, 0)?;
        Ok((total, largest))
    }
    fn open_child(&self, name: &std::ffi::OsStr) -> Result<File> {
        self.check()?;
        #[cfg(unix)]
        {
            use std::os::{
                fd::{AsRawFd, FromRawFd},
                unix::ffi::OsStrExt,
            };
            let name = std::ffi::CString::new(name.as_bytes())?;
            let fd = unsafe {
                libc::openat(
                    self.file.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
                )
            };
            if fd < 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            Ok(unsafe { File::from_raw_fd(fd) })
        }
        #[cfg(windows)]
        {
            let path = self.path.join(name);
            let metadata = fs::symlink_metadata(&path)?;
            if metadata.is_dir() {
                Ok(Directory::pin(&path)?.file)
            } else {
                native_file::open_regular(&path, false)
            }
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = name;
            anyhow::bail!("Private Git monitoring unavailable")
        }
    }
    fn names(&self, limit: usize) -> Result<Vec<std::ffi::OsString>> {
        self.check()?;
        let mut result = Vec::new();
        #[cfg(unix)]
        {
            use std::os::{fd::AsRawFd, unix::ffi::OsStringExt};
            let dot = c".";
            let fd = unsafe {
                libc::openat(
                    self.file.as_raw_fd(),
                    dot.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
                )
            };
            ensure!(fd >= 0, "Private Git directory cannot be enumerated");
            let stream = unsafe { libc::fdopendir(fd) };
            if stream.is_null() {
                unsafe { libc::close(fd) };
                anyhow::bail!("Private Git directory cannot be enumerated");
            }
            struct Entries(*mut libc::DIR);
            impl Drop for Entries {
                fn drop(&mut self) {
                    unsafe { libc::closedir(self.0) };
                }
            }
            let entries = Entries(stream);
            loop {
                #[cfg(target_os = "macos")]
                unsafe {
                    *libc::__error() = 0;
                }
                #[cfg(target_os = "linux")]
                unsafe {
                    *libc::__errno_location() = 0;
                }
                let next = unsafe { libc::readdir(entries.0) };
                if next.is_null() {
                    #[cfg(any(target_os = "macos", target_os = "linux"))]
                    ensure!(
                        std::io::Error::last_os_error().raw_os_error() == Some(0),
                        "Private Git directory enumeration failed"
                    );
                    break;
                }
                let name = unsafe { std::ffi::CStr::from_ptr((*next).d_name.as_ptr()) }.to_bytes();
                if matches!(name, b"." | b"..") {
                    continue;
                }
                ensure!(result.len() < limit, "Private Git file count exceeds bound");
                result.push(std::ffi::OsString::from_vec(name.to_vec()));
            }
        }
        #[cfg(windows)]
        {
            for entry in fs::read_dir(&self.path)? {
                ensure!(result.len() < limit, "Private Git file count exceeds bound");
                result.push(entry?.file_name());
            }
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = limit;
            anyhow::bail!("Private Git monitoring unavailable");
        }
        self.check()?;
        Ok(result)
    }
}
