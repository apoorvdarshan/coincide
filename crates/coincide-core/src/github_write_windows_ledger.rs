//! Windows ledger custody. Existing ACLs are validated, never repaired; handles
//! deny replacement for the service lifetime and one native file lock excludes
//! a competing writer. Request payloads and secrets are never stored here.
use super::*;
use std::os::windows::fs::OpenOptionsExt;
use windows_sys::Win32::Storage::FileSystem::{
    FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ, FILE_SHARE_WRITE,
};
pub(super) struct Custody {
    directory: File,
    directory_path: PathBuf,
    database: Option<File>,
    identity: Option<File>,
}
impl Custody {
    pub(super) fn open(directory: &Path, initialize: bool) -> Result<Self> {
        if initialize {
            crate::native_file::private_directory(directory)?;
        }
        crate::private_fs::windows::verify(directory, true)?;
        let held = fs::OpenOptions::new()
            .read(true)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
            .open(directory)?;
        ensure!(
            crate::native_file::file_identity(&held)?
                == crate::native_file::path_identity(directory)?,
            "GitHub ledger directory changed"
        );
        Ok(Self {
            directory: held,
            directory_path: directory.into(),
            database: None,
            identity: None,
        })
    }
    pub(super) fn hold_files(mut self, database: &Path, identity: &Path) -> Result<Self> {
        self.database = Some(crate::private_fs::windows::open_file(database, false)?);
        self.identity = Some(crate::private_fs::windows::open_file(identity, false)?);
        self.validate(database, identity)?;
        Ok(self)
    }
    pub(super) fn validate(&self, database: &Path, identity: &Path) -> Result<()> {
        ensure!(
            crate::native_file::file_identity(&self.directory)?
                == crate::native_file::path_identity(&self.directory_path)?,
            "GitHub ledger directory changed"
        );
        for (held, path) in [
            (self.database.as_ref(), database),
            (self.identity.as_ref(), identity),
        ] {
            let held = held.context("GitHub ledger custody missing")?;
            crate::private_fs::windows::verify(path, false)?;
            ensure!(
                crate::native_file::file_identity(held)?
                    == crate::native_file::path_identity(path)?,
                "GitHub ledger source changed"
            );
        }
        Ok(())
    }
}
pub(super) fn lock(path: &Path) -> Result<File> {
    let file = match crate::private_fs::windows::open_file(path, true) {
        Ok(file) => file,
        Err(error)
            if error
                .downcast_ref::<std::io::Error>()
                .is_some_and(|error| error.kind() == std::io::ErrorKind::AlreadyExists) =>
        {
            crate::private_fs::windows::open_file(path, false)?
        }
        Err(error) => return Err(error),
    };
    File::try_lock(&file).context("GitHub ledger already in use")?;
    Ok(file)
}
