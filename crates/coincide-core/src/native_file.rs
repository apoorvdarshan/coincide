//! Native UI filesystem primitives. This module provides no instruction write
//! API, configurable path authority, JSON serialization, or control RPC route.
use anyhow::{Result, ensure};
use std::{
    fs::{self, File, OpenOptions},
    path::Path,
};
pub type Identity = (u64, [u8; 16]);
pub fn file_identity(file: &File) -> Result<Identity> {
    crate::private_fs::file_identity(file)
}
pub fn path_identity(path: &Path) -> Result<Identity> {
    crate::private_fs::identity(path)
}
pub fn link_target(path: &Path) -> Result<Option<std::path::PathBuf>> {
    let metadata = fs::symlink_metadata(path)?;
    let linked = metadata.file_type().is_symlink();
    #[cfg(windows)]
    let linked = {
        use std::os::windows::fs::MetadataExt;
        linked
            || metadata.file_attributes()
                & windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT
                != 0
    };
    if linked {
        Ok(Some(fs::read_link(path)?))
    } else {
        Ok(None)
    }
}
/// A resolved existing regular file. A final symlink/reparse point is refused;
/// callers must separately bind/check their complete original link chain.
pub fn open_regular(path: &Path, write: bool) -> Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(write);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        use windows_sys::Win32::Storage::FileSystem::{
            FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
        };
        options
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
            .share_mode(
                FILE_SHARE_READ | FILE_SHARE_WRITE | if write { 0 } else { FILE_SHARE_DELETE },
            );
    }
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file() && !metadata.file_type().is_symlink(),
        "Native editor source is not a regular file"
    );
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        ensure!(
            metadata.file_attributes()
                & windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT
                == 0,
            "Native editor source is a reparse point"
        );
    }
    Ok(file)
}
/// Create/validate a single private child directory; never changes an existing
/// directory's permissions or follows a symlink to adopt another location.
pub fn private_directory(path: &Path) -> Result<()> {
    ensure!(
        path.is_absolute(),
        "Private native directory must be absolute"
    );
    #[cfg(windows)]
    {
        crate::private_fs::windows::create_directory(path)
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
        let mut builder = fs::DirBuilder::new();
        builder.mode(0o700);
        match builder.create(path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.into()),
        }
        let metadata = fs::symlink_metadata(path)?;
        ensure!(
            metadata.is_dir()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.permissions().mode() & 0o077 == 0,
            "Native recovery directory is not privately owned"
        );
        Ok(())
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = path;
        anyhow::bail!("Private native files unavailable")
    }
}
pub fn create_private_file(path: &Path) -> Result<File> {
    #[cfg(windows)]
    {
        crate::private_fs::windows::open_file(path, true)
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        Ok(OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)?)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = path;
        anyhow::bail!("Private native files unavailable")
    }
}
