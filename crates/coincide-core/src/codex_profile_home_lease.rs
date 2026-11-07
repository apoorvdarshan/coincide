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
        Self::capture_locked(home, path, identity, &file)
    }
    fn capture_locked(
        home: &Path,
        path: PathBuf,
        identity: crate::private_fs::Identity,
        file: &File,
    ) -> Result<Self> {
        let result = (|| {
            let generation = Self::generation(home)?;
            let lease = Self {
                path,
                identity,
                generation,
            };
            lease.validate()?;
            Ok(lease)
        })();
        // A metadata pin retains no lock. Closing this FD alone is insufficient
        // on Unix when a concurrent fork inherited the same open-file-description:
        // its duplicate can keep flock alive until exec. Explicitly release only
        // this short capture lease, including validation failures. Actual Held
        // child/worker leases below deliberately remain locked through cleanup.
        let unlocked = file
            .unlock()
            .context("Codex metadata lease could not be released");
        let lease = result?;
        unlocked?;
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
    #[cfg(unix)]
    #[test]
    fn metadata_capture_unlocks_inherited_like_duplicate_but_actual_held_still_excludes_change() {
        use std::os::unix::fs::DirBuilderExt;
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("owned");
        fs::DirBuilder::new().mode(0o700).create(&home).unwrap();
        Lease::capture(&home).unwrap();
        let path = home.join(".native-account-owner");
        let file = open_file(&path, false).unwrap();
        file.try_lock_shared().unwrap();
        // dup models the same open-file-description retained by a parallel
        // fork before exec, without executing any child or provider.
        let inherited = file.try_clone().unwrap();
        let identity = crate::private_fs::file_identity(&file).unwrap();
        let pin = Lease::capture_locked(&home, path.clone(), identity, &file).unwrap();
        let exclusive = open_file(&path, false).unwrap();
        exclusive.try_lock().unwrap();
        assert!(pin.acquire().is_err());
        exclusive.unlock().unwrap();
        let actual = pin.acquire().unwrap();
        assert!(exclusive.try_lock().is_err());
        drop(file);
        drop(inherited);
        assert!(
            exclusive.try_lock().is_err(),
            "Actual worker lease must survive metadata FD cleanup"
        );
        drop(actual);
        exclusive.try_lock().unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn rejected_metadata_capture_releases_only_its_own_shared_lease() {
        use std::os::unix::fs::DirBuilderExt;
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("owned");
        fs::DirBuilder::new().mode(0o700).create(&home).unwrap();
        Lease::capture(&home).unwrap();
        let path = home.join(".native-account-owner");
        let file = open_file(&path, false).unwrap();
        file.set_len(65).unwrap();
        file.try_lock_shared().unwrap();
        let inherited = file.try_clone().unwrap();
        let identity = crate::private_fs::file_identity(&file).unwrap();
        assert!(Lease::capture_locked(&home, path.clone(), identity, &file).is_err());
        let exclusive = open_file(&path, false).unwrap();
        exclusive.try_lock().unwrap();
        drop(inherited);
    }
}
