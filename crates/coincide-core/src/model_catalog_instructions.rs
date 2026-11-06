//! Read-only context for the instruction files used by app-managed Codex homes
//! and the selected project. No configuration, file creation, or instruction
//! content is exposed through catalog/resume metadata.
use anyhow::{Context as _, Result, ensure};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    time::SystemTime,
};
const LIMIT: u64 = 1024 * 1024;
const NAMES: [&str; 2] = ["AGENTS.md", "AGENTS.override.md"];

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
struct FileState {
    identity: crate::private_fs::Identity,
    length: u64,
    modified: SystemTime,
    symlink: bool,
}
impl FileState {
    fn path(path: &Path) -> Result<Self> {
        let metadata = fs::symlink_metadata(path)?;
        ensure!(
            metadata.is_file() || metadata.file_type().is_symlink(),
            "Instruction path is not a regular file or file link"
        );
        Ok(Self {
            identity: crate::private_fs::identity(path)?,
            length: metadata.len(),
            modified: metadata.modified()?,
            symlink: metadata.file_type().is_symlink(),
        })
    }
    fn handle(file: &fs::File) -> Result<Self> {
        let metadata = file.metadata()?;
        ensure!(
            metadata.is_file(),
            "Instruction target is not a regular file"
        );
        Ok(Self {
            identity: crate::private_fs::file_identity(file)?,
            length: metadata.len(),
            modified: metadata.modified()?,
            symlink: false,
        })
    }
}
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
struct Fingerprint {
    leaf: FileState,
    resolved: PathBuf,
    target: FileState,
    digest: [u8; 32],
}
impl Fingerprint {
    fn capture(path: &Path) -> Result<Option<Self>> {
        let leaf = match FileState::path(path) {
            Ok(leaf) => leaf,
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|error| error.kind() == std::io::ErrorKind::NotFound) =>
            {
                return Ok(None);
            }
            Err(error) => return Err(error),
        };
        let resolved = path
            .canonicalize()
            .context("Instruction link target is unavailable")?;
        let target = FileState::path(&resolved)?;
        ensure!(
            !target.symlink && target.length <= LIMIT,
            "Instruction target must be a regular file no larger than 1 MiB"
        );
        let mut options = fs::OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            // A replacement FIFO cannot block a metadata-to-open race, and a
            // replacement link cannot redirect the already resolved target.
            options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.custom_flags(
                windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT,
            );
        }
        let mut file = options.open(&resolved)?;
        ensure!(
            FileState::handle(&file)? == target,
            "Instruction target changed before reading"
        );
        let mut bytes = Vec::new();
        (&mut file).take(LIMIT + 1).read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() as u64 <= LIMIT && bytes.len() as u64 == target.length,
            "Instruction file changed or exceeds 1 MiB"
        );
        std::str::from_utf8(&bytes).context("Instruction file is not UTF-8")?;
        ensure!(
            FileState::handle(&file)? == target
                && FileState::path(&resolved)? == target
                && FileState::path(path)? == leaf
                && path.canonicalize()? == resolved,
            "Instruction file or link changed while reading"
        );
        Ok(Some(Self {
            leaf,
            resolved,
            target,
            digest: Sha256::digest(&bytes).into(),
        }))
    }
}
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub(super) struct ContextStamp {
    home: Vec<Option<Fingerprint>>,
    project: Vec<Option<Fingerprint>>,
}
impl ContextStamp {
    pub(super) fn capture(home: &Path, project: &Path) -> Result<Self> {
        let capture = |root: &Path| {
            NAMES
                .iter()
                .map(|name| Fingerprint::capture(&root.join(name)))
                .collect::<Result<Vec<_>>>()
        };
        Ok(Self {
            home: capture(home)?,
            project: capture(project)?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("managed-home");
        let project = root.path().join("project");
        fs::create_dir(&home).unwrap();
        fs::create_dir(&project).unwrap();
        (root, home, project)
    }
    #[test]
    fn content_changes_in_the_same_file_with_restored_timestamp_still_invalidate_context() {
        let (_root, home, project) = fixture();
        let path = home.join("AGENTS.md");
        fs::write(&path, "synthetic one").unwrap();
        let stamp = ContextStamp::capture(&home, &project).unwrap();
        let modified = fs::metadata(&path).unwrap().modified().unwrap();
        fs::write(&path, "synthetic two").unwrap();
        fs::OpenOptions::new()
            .write(true)
            .open(&path)
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(modified))
            .unwrap();
        assert_eq!(fs::metadata(&path).unwrap().modified().unwrap(), modified);
        assert_ne!(ContextStamp::capture(&home, &project).unwrap(), stamp);
    }
    #[test]
    fn creation_removal_project_and_override_changes_are_observed_but_unrelated_files_are_not() {
        let (_root, home, project) = fixture();
        let empty = ContextStamp::capture(&home, &project).unwrap();
        fs::write(project.join("unrelated.txt"), "synthetic").unwrap();
        assert_eq!(ContextStamp::capture(&home, &project).unwrap(), empty);
        for root in [&home, &project] {
            for name in NAMES {
                let path = root.join(name);
                fs::write(&path, "synthetic instructions").unwrap();
                assert_ne!(ContextStamp::capture(&home, &project).unwrap(), empty);
                fs::remove_file(path).unwrap();
                assert_eq!(ContextStamp::capture(&home, &project).unwrap(), empty);
            }
        }
    }
    #[test]
    fn oversized_non_file_and_non_utf8_instruction_sources_refuse_readmission() {
        let (_root, home, project) = fixture();
        let path = home.join("AGENTS.md");
        fs::write(&path, vec![b'x'; LIMIT as usize + 1]).unwrap();
        assert!(ContextStamp::capture(&home, &project).is_err());
        fs::write(&path, [0xff, 0xfe]).unwrap();
        assert!(ContextStamp::capture(&home, &project).is_err());
        fs::remove_file(&path).unwrap();
        fs::create_dir(&path).unwrap();
        assert!(ContextStamp::capture(&home, &project).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn reviewed_file_links_bind_target_content_and_link_identity_without_modifying_the_master() {
        let (root, home, project) = fixture();
        let master = root.path().join("synthetic-master.md");
        let replacement = root.path().join("replacement.md");
        fs::write(&master, "synthetic master").unwrap();
        fs::write(&replacement, "synthetic master").unwrap();
        let link = home.join("AGENTS.md");
        std::os::unix::fs::symlink(&master, &link).unwrap();
        let stamp = ContextStamp::capture(&home, &project).unwrap();
        assert_eq!(fs::read(&master).unwrap(), b"synthetic master");
        fs::remove_file(&link).unwrap();
        std::os::unix::fs::symlink(&replacement, &link).unwrap();
        assert_ne!(ContextStamp::capture(&home, &project).unwrap(), stamp);
        fs::remove_file(&replacement).unwrap();
        assert!(ContextStamp::capture(&home, &project).is_err());
        assert_eq!(fs::read(&master).unwrap(), b"synthetic master");
    }
}
