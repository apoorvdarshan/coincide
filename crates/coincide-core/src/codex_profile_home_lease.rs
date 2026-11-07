//! Shared custody for legacy subscription homes. The lease is never serialized
//! into existing catalog/session proofs; it only excludes native home mutation.
use super::*;
use std::{fmt, sync::Arc};
#[derive(Clone)]
pub(crate) struct Lease {
    file: Arc<File>,
    path: PathBuf,
    identity: crate::private_fs::Identity,
}
impl fmt::Debug for Lease {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("CodexHomeLease")
    }
}
impl PartialEq for Lease {
    fn eq(&self, other: &Self) -> bool {
        self.path == other.path && self.identity == other.identity
    }
}
impl Eq for Lease {}
impl Lease {
    pub(crate) fn capture(home: &Path) -> Result<Self> {
        private(home, true)?;
        let path = home.join(".native-account-owner");
        let file = match open_file(&path, true) {
            Ok(file) => file,
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|error| error.kind() == std::io::ErrorKind::AlreadyExists) =>
            {
                open_file(&path, false)?
            }
            Err(error) => return Err(error),
        };
        private(&path, false)?;
        let identity = crate::private_fs::identity(&path)?;
        ensure!(
            crate::private_fs::file_identity(&file)? == identity,
            "Codex home owner changed while opening"
        );
        file.try_lock_shared()
            .context("Codex account is being changed or removed")?;
        let lease = Self {
            file: Arc::new(file),
            path,
            identity,
        };
        lease.validate()?;
        Ok(lease)
    }
    pub(crate) fn validate(&self) -> Result<()> {
        private(&self.path, false)?;
        ensure!(
            crate::private_fs::identity(&self.path)? == self.identity
                && crate::private_fs::file_identity(&self.file)? == self.identity,
            "Codex account owner was replaced"
        );
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shared_contexts_exclude_exclusive_conversion_until_last_clone_drops() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("owned");
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            fs::DirBuilder::new().mode(0o700).create(&home).unwrap();
        }
        #[cfg(windows)]
        crate::private_fs::windows::create_directory(&home).unwrap();
        let first = Lease::capture(&home).unwrap();
        let second = Lease::capture(&home).unwrap();
        let copy = first.clone();
        let exclusive = open_file(&home.join(".native-account-owner"), false).unwrap();
        assert!(exclusive.try_lock().is_err());
        drop(first);
        drop(second);
        assert!(exclusive.try_lock().is_err());
        drop(copy);
        exclusive.try_lock().unwrap();
        assert!(Lease::capture(&home).is_err());
    }
}
