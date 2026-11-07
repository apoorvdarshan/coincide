//! Legacy context pins are cacheable without keeping a home busy. Actual
//! transport/catalog children retain a shared lease until their owned cleanup.
//! Neither pin nor lease changes existing serialized subscription proofs.
use super::*;
use std::{fmt, sync::Arc};
#[derive(Clone)]
pub(crate) struct Lease {
    path: PathBuf,
    identity: crate::private_fs::Identity,
    generation: [u8; 32],
}
impl fmt::Debug for Lease {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("CodexHomeLease")
    }
}
impl PartialEq for Lease {
    fn eq(&self, other: &Self) -> bool {
        self.path == other.path
            && self.identity == other.identity
            && self.generation == other.generation
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
        let generation = Self::generation(home)?;
        let lease = Self {
            path,
            identity,
            generation,
        };
        lease.validate()?;
        Ok(lease)
    }
    pub(crate) fn validate(&self) -> Result<()> {
        private(&self.path, false)?;
        ensure!(
            crate::private_fs::identity(&self.path)? == self.identity
                && Self::generation(self.path.parent().context("Codex home missing")?)?
                    == self.generation,
            "Codex account owner was replaced"
        );
        Ok(())
    }
    pub(crate) fn generation(home: &Path) -> Result<[u8; 32]> {
        let path = home.join(".native-account-owner");
        private(&path, false)?;
        let mut file = open_file(&path, false)?;
        let identity = crate::private_fs::file_identity(&file)?;
        let length = file.metadata()?.len();
        ensure!(
            length <= 64 && crate::private_fs::identity(&path)? == identity,
            "Codex account owner is invalid"
        );
        let mut bytes = [0u8; 64];
        file.read_exact(&mut bytes[..length as usize])?;
        ensure!(
            file.metadata()?.len() == length && crate::private_fs::identity(&path)? == identity,
            "Codex account owner changed while reading"
        );
        Ok(Sha256::digest(&bytes[..length as usize]).into())
    }
    pub(crate) fn acquire(&self) -> Result<Held> {
        self.validate()?;
        let file = open_file(&self.path, false)?;
        ensure!(
            crate::private_fs::file_identity(&file)? == self.identity,
            "Codex account owner changed while opening"
        );
        file.try_lock_shared()
            .context("Codex account is being changed or removed")?;
        self.validate()?;
        Ok(Held {
            _file: Arc::new(file),
        })
    }
}
#[derive(Clone)]
pub(crate) struct Held {
    _file: Arc<File>,
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reviewed_generation_change_rejects_old_queued_context_without_locking_idle_cache() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("owned");
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            fs::DirBuilder::new().mode(0o700).create(&home).unwrap();
        }
        #[cfg(windows)]
        crate::private_fs::windows::create_directory(&home).unwrap();
        let old = Lease::capture(&home).unwrap();
        let mut exclusive = open_file(&home.join(".native-account-owner"), false).unwrap();
        exclusive.try_lock().unwrap();
        exclusive.write_all(Uuid::new_v4().as_bytes()).unwrap();
        exclusive.sync_all().unwrap();
        drop(exclusive);
        assert!(old.acquire().is_err());
        let current = Lease::capture(&home).unwrap();
        assert_ne!(old, current);
        assert!(current.acquire().is_ok());
    }
    #[test]
    fn actual_child_leases_exclude_conversion_but_cached_pins_do_not() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("owned");
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            fs::DirBuilder::new().mode(0o700).create(&home).unwrap();
        }
        #[cfg(windows)]
        crate::private_fs::windows::create_directory(&home).unwrap();
        let pin = Lease::capture(&home).unwrap();
        let first = pin.acquire().unwrap();
        let second = pin.acquire().unwrap();
        let copy = first.clone();
        let exclusive = open_file(&home.join(".native-account-owner"), false).unwrap();
        assert!(exclusive.try_lock().is_err());
        drop(first);
        drop(second);
        assert!(exclusive.try_lock().is_err());
        drop(copy);
        exclusive.try_lock().unwrap();
        assert!(pin.acquire().is_err());
    }
}
