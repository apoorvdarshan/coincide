//! Owned runtime artifact directory. No caller-supplied filename, adoption of
//! existing files, recursive cleanup or deletion inferred from a timeout.
use super::Png;
use crate::native_file::{self, Identity};
use anyhow::{Result, ensure};
use std::{
    fs::File,
    io::Write,
    path::{Path, PathBuf},
    sync::Arc,
};

pub struct Directory {
    path: PathBuf,
    directory: File,
    identity: Identity,
    #[cfg(windows)]
    _ancestors: Vec<File>,
}
impl Directory {
    /// Called only by an explicit native screenshot admission, never render or
    /// BrowserRequest JSON deserialization. Parent is the owned runtime profile.
    pub fn open(path: &Path) -> Result<Arc<Self>> {
        native_file::private_directory(path)?;
        #[cfg(unix)]
        let directory = {
            use std::os::unix::fs::OpenOptionsExt;
            std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(path)?
        };
        #[cfg(windows)]
        let (directory, ancestors) = {
            use std::os::windows::fs::OpenOptionsExt;
            let mut ancestors = Vec::new();
            for ancestor in path
                .ancestors()
                .skip(1)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
            {
                ensure!(
                    native_file::link_target(ancestor)?.is_none(),
                    "Snapshot ancestor is a reparse point"
                );
                ancestors.push(
                    std::fs::OpenOptions::new()
                        .read(true)
                        .share_mode(3)
                        .custom_flags(0x02000000 | 0x00200000)
                        .open(ancestor)?,
                );
            }
            ensure!(
                native_file::link_target(path)?.is_none(),
                "Snapshot directory is a reparse point"
            );
            let file = std::fs::OpenOptions::new()
                .read(true)
                .share_mode(3)
                .custom_flags(0x02000000 | 0x00200000)
                .open(path)?;
            (file, ancestors)
        };
        #[cfg(not(any(unix, windows)))]
        anyhow::bail!("Native snapshot files are unsupported");
        let identity = native_file::file_identity(&directory)?;
        ensure!(
            native_file::path_identity(path)? == identity,
            "Snapshot directory changed"
        );
        Ok(Arc::new(Self {
            path: path.to_owned(),
            directory,
            identity,
            #[cfg(windows)]
            _ancestors: ancestors,
        }))
    }
    pub fn matches(&self) -> bool {
        native_file::file_identity(&self.directory).ok() == Some(self.identity)
            && native_file::path_identity(&self.path).ok() == Some(self.identity)
            && native_file::link_target(&self.path).ok() == Some(None)
    }
    pub fn write(self: &Arc<Self>, png: &Png) -> Result<Artifact> {
        ensure!(self.matches(), "Snapshot runtime directory changed");
        let mut bytes = 0u64;
        for (count, entry) in std::fs::read_dir(&self.path)?.enumerate() {
            ensure!(count < 64, "Snapshot runtime artifact count exceeds limit");
            let entry = entry?;
            let path = entry.path();
            let metadata = std::fs::symlink_metadata(&path)?;
            ensure!(
                metadata.is_file()
                    && native_file::link_target(&path)?.is_none()
                    && path.extension().is_some_and(|ext| ext == "png")
                    && path
                        .file_stem()
                        .and_then(|stem| stem.to_str())
                        .is_some_and(|stem| uuid::Uuid::parse_str(stem).is_ok()),
                "Snapshot runtime contains an unowned entry"
            );
            bytes = bytes
                .checked_add(metadata.len())
                .ok_or_else(|| anyhow::anyhow!("Snapshot runtime size overflow"))?;
            ensure!(
                bytes + png.bytes().len() as u64 <= 128 * 1024 * 1024,
                "Snapshot runtime exceeds 128 MiB budget"
            );
        }
        ensure!(self.matches(), "Snapshot runtime directory changed");
        let name = format!("{}.png", uuid::Uuid::new_v4());
        #[cfg(unix)]
        let mut file = {
            use std::os::fd::{AsRawFd, FromRawFd};
            let name = std::ffi::CString::new(name.as_bytes())?;
            let fd = unsafe {
                libc::openat(
                    self.directory.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_CREAT
                        | libc::O_EXCL
                        | libc::O_RDWR
                        | libc::O_NOFOLLOW
                        | libc::O_CLOEXEC,
                    0o600,
                )
            };
            ensure!(fd >= 0, "Cannot create private snapshot artifact");
            unsafe { File::from_raw_fd(fd) }
        };
        #[cfg(not(unix))]
        let mut file = native_file::create_private_file(&self.path.join(&name))?;
        let identity = native_file::file_identity(&file)?;
        let artifact = Artifact {
            directory: self.clone(),
            name,
            identity,
            width: png.width(),
            height: png.height(),
        };
        // All output remains owned even if a write/source check fails. Never
        // recursively remove another file/directory from an error path.
        let result: Result<()> = (|| {
            ensure!(artifact.matches(), "Snapshot destination changed");
            file.write_all(png.bytes())?;
            file.sync_all()?;
            ensure!(artifact.matches(), "Snapshot destination changed");
            Ok(())
        })();
        if let Err(error) = result {
            return match artifact.discard() {
                Ok(()) => Err(error),
                Err(cleanup) => {
                    Err(error.context(format!("Snapshot cleanup retained its artifact: {cleanup}")))
                }
            };
        }
        Ok(artifact)
    }
}
pub struct Artifact {
    directory: Arc<Directory>,
    name: String,
    identity: Identity,
    width: u32,
    height: u32,
}
impl Artifact {
    pub fn path(&self) -> PathBuf {
        self.directory.path.join(&self.name)
    }
    pub fn width(&self) -> u32 {
        self.width
    }
    pub fn height(&self) -> u32 {
        self.height
    }
    pub fn matches(&self) -> bool {
        self.directory.matches()
            && native_file::path_identity(&self.path()).ok() == Some(self.identity)
            && native_file::link_target(&self.path()).ok() == Some(None)
    }
    /// Explicit cleanup receipt, never called implicitly from Drop. A changed
    /// directory or file remains retained and is reported to the native owner.
    pub fn discard(self) -> Result<()> {
        ensure!(
            self.matches(),
            "Snapshot cleanup retained a changed artifact"
        );
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            let name = std::ffi::CString::new(self.name)?;
            ensure!(
                unsafe { libc::unlinkat(self.directory.directory.as_raw_fd(), name.as_ptr(), 0) }
                    == 0,
                "Snapshot cleanup did not return success"
            );
        }
        #[cfg(not(unix))]
        std::fs::remove_file(self.path())?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn artifact_custody_rejects_replacement_and_unknown_entries() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("screenshots");
        let root = Directory::open(&path).unwrap();
        let png = super::super::redact_rgba(
            1,
            1,
            vec![0, 0, 0, 255],
            &super::super::Geometry::checked(1., 1., vec![]).unwrap(),
        )
        .unwrap();
        let artifact = root.write(&png).unwrap();
        let artifact_path = artifact.path();
        assert!(artifact.matches());
        assert_eq!(std::fs::read(&artifact_path).unwrap(), png.bytes());
        let replacement = path.join("future-private-file");
        std::fs::write(&replacement, b"preserve").unwrap();
        assert!(root.write(&png).is_err());
        std::fs::rename(&artifact_path, path.join("old.png")).unwrap();
        std::fs::write(&artifact_path, b"newer file").unwrap();
        assert!(!artifact.matches());
        assert!(artifact.discard().is_err());
        assert_eq!(std::fs::read(&artifact_path).unwrap(), b"newer file");
        assert_eq!(std::fs::read(&replacement).unwrap(), b"preserve");
    }
    #[test]
    fn explicit_discard_removes_only_generated_artifact() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("screenshots");
        let root = Directory::open(&path).unwrap();
        let png = super::super::redact_rgba(
            1,
            1,
            vec![0; 4],
            &super::super::Geometry::checked(1., 1., vec![]).unwrap(),
        )
        .unwrap();
        let artifact = root.write(&png).unwrap();
        let file = artifact.path();
        artifact.discard().unwrap();
        assert!(!file.exists());
        assert!(root.matches());
    }
}
