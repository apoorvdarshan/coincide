//! Readonly setup helpers retain the exact native Store. Windows uses native
//! no-reparse, no-delete-sharing handles rather than Unix-only media helpers.
use super::*;
pub(super) struct Source {
    pub file: File,
    #[cfg(windows)]
    parent: File,
}
impl Source {
    pub fn open(path: &Path) -> Result<Self> {
        #[cfg(unix)]
        {
            Ok(Self {
                file: crate::legacy_media_service::open_regular_existing(path)?,
            })
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            use windows_sys::Win32::Storage::FileSystem::{
                FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ,
                FILE_SHARE_WRITE,
            };
            let parent_path = path.parent().context("Setup Store parent missing")?;
            private(parent_path, true)?;
            private(path, false)?;
            let parent = fs::OpenOptions::new()
                .read(true)
                .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
                .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
                .open(parent_path)?;
            let file = fs::OpenOptions::new()
                .read(true)
                .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
                .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
                .open(path)?;
            ensure!(
                file.metadata()?.is_file()
                    && crate::private_fs::file_identity(&file)?
                        == crate::private_fs::identity(path)?
                    && crate::private_fs::file_identity(&parent)?
                        == crate::private_fs::identity(parent_path)?,
                "Setup Store or private parent changed while opening"
            );
            private(parent_path, true)?;
            private(path, false)?;
            Ok(Self { file, parent })
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = path;
            anyhow::bail!("Native setup source custody is unavailable")
        }
    }
    pub fn verify(&self, path: &Path, db: &rusqlite::Connection) -> Result<()> {
        #[cfg(unix)]
        {
            crate::legacy_media_service::verify_database_identity(path, &self.file, db)
        }
        #[cfg(windows)]
        {
            let parent = path.parent().context("Setup Store parent missing")?;
            private(parent, true)?;
            private(path, false)?;
            ensure!(
                crate::private_fs::file_identity(&self.parent)?
                    == crate::private_fs::identity(parent)?
                    && crate::private_fs::file_identity(&self.file)?
                        == crate::private_fs::identity(path)?,
                "Setup Store identity changed"
            );
            ensure!(
                db.path()
                    .map(Path::new)
                    .context("Setup SQLite source missing")?
                    .canonicalize()?
                    == path.canonicalize()?,
                "SQLite opened another setup source"
            );
            // Both handles exclude FILE_SHARE_DELETE. The private parent and
            // DB cannot be replaced while SQLite reads this exact path.
            Ok(())
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = (path, db);
            anyhow::bail!("Native setup source custody is unavailable")
        }
    }
}
