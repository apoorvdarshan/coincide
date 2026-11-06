//! Bound global-master editor state, reachable only from its native UI module.
//! Writes preserve the existing file's inode and all existing symlinks. The
//! private recovery copy is durable before mutation and retained on any error.
use anyhow::{Context as _, Result, ensure};
use coincide_core::native_file::{self, Identity};
use std::{
    fs::{self, File},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};
const LIMIT: usize = 1024 * 1024;
#[derive(Clone, Debug, PartialEq, Eq)]
struct LinkState {
    path: PathBuf,
    identity: Identity,
    target: Option<PathBuf>,
    link_modified: Option<std::time::SystemTime>,
}
#[derive(Clone)]
struct Snapshot {
    resolved: PathBuf,
    links: Vec<LinkState>,
    identity: Identity,
    modified: std::time::SystemTime,
    bytes: Vec<u8>,
}
pub(super) struct EditorFile {
    master: PathBuf,
    recovery_root: PathBuf,
    snapshot: Option<Snapshot>,
}
impl EditorFile {
    /// Only a native-owned scope can bind a writer. Persisted JSON paths and
    /// arbitrary caller strings cannot construct this editor.
    pub(super) fn from_native_scope(
        scope: &super::super::instructions_scope::NativeScope,
    ) -> Result<Self> {
        Ok(Self {
            master: scope.master_path().to_owned(),
            recovery_root: coincide_core::control::data_directory()?.join("instruction-recovery"),
            snapshot: None,
        })
    }
    #[cfg(test)]
    fn fixture(master: PathBuf, recovery_root: PathBuf) -> Self {
        Self {
            master,
            recovery_root,
            snapshot: None,
        }
    }
    pub(super) fn path(&self) -> &Path {
        &self.master
    }
    pub(super) fn load(&mut self) -> Result<String> {
        let snapshot=capture(&self.master).context("The selected instruction file could not be opened. Existing files are never created or replaced by Reload")?;
        let text =
            String::from_utf8(snapshot.bytes.clone()).context("Instructions must be UTF-8 text")?;
        self.snapshot = Some(snapshot);
        Ok(text)
    }
    pub(super) fn baseline(&self) -> Option<&str> {
        self.snapshot
            .as_ref()
            .and_then(|snapshot| std::str::from_utf8(&snapshot.bytes).ok())
    }
    pub(super) fn validate_review_source(&self) -> Result<()> {
        let expected = self
            .snapshot
            .as_ref()
            .context("Load this native source before reviewing it")?;
        let mut file = native_file::open_regular(&expected.resolved, false)?;
        ensure!(
            matches_source(&self.master, expected, &mut file)?,
            "Reviewed instruction source changed; review it again"
        );
        Ok(())
    }
    pub(super) fn save(&mut self, text: &str) -> Result<()> {
        self.save_using(text, |file, bytes| {
            file.seek(SeekFrom::Start(0))?;
            file.write_all(bytes)?;
            file.set_len(bytes.len() as u64)?;
            file.sync_all()?;
            Ok(())
        })
    }
    fn save_using(
        &mut self,
        text: &str,
        write: impl FnOnce(&mut File, &[u8]) -> Result<()>,
    ) -> Result<()> {
        ensure!(text.len() <= LIMIT, "Instructions must fit within 1 MiB");
        let expected = self
            .snapshot
            .as_ref()
            .context("Reload an existing global master before saving")?;
        let mut file = native_file::open_regular(&expected.resolved, true)?;
        // Cooperative readers/editors can coexist; only this short Save owns a
        // standard exclusive file lease. A busy lease never falls back to write.
        file.try_lock()
            .context("Another editor is saving this file; retry after it finishes")?;
        ensure!(
            native_file::file_identity(&file)? == expected.identity,
            "Instruction file was replaced; keep your edits and reload"
        );
        ensure!(
            matches_source(&self.master, expected, &mut file)?,
            "Instructions changed on disk; your edits are kept. Review the current file before saving"
        );
        if text.as_bytes() == expected.bytes {
            return Ok(());
        }
        native_file::private_directory(&self.recovery_root)?;
        let backup = self
            .recovery_root
            .join(format!("global-{}.md", uuid::Uuid::new_v4()));
        let mut recovery = native_file::create_private_file(&backup)?;
        recovery.write_all(&expected.bytes)?;
        recovery.sync_all()?;
        #[cfg(unix)]
        File::open(&self.recovery_root)?.sync_all()?;
        // Recheck after the recovery write: no changed path or bytes can gain
        // write authority merely because an old recovery snapshot exists.
        ensure!(
            matches_source(&self.master, expected, &mut file)?,
            "Instruction file changed while preparing recovery; no instruction bytes were written"
        );
        if let Err(_error) = write(&mut file, text.as_bytes()) {
            let restored = (|| -> Result<()> {
                file.seek(SeekFrom::Start(0))?;
                file.write_all(&expected.bytes)?;
                file.set_len(expected.bytes.len() as u64)?;
                file.sync_all()?;
                let mut restored_expected = expected.clone();
                restored_expected.modified = file.metadata()?.modified()?;
                ensure!(
                    matches_source(&self.master, &restored_expected, &mut file)?,
                    "Original bytes could not be verified"
                );
                Ok(())
            })();
            // Finalize Windows' write timestamp before keeping a reusable
            // baseline. A verified rollback may be retried without losing the
            // user's typed replacement or pretending the failed Save succeeded.
            drop(file);
            let recovered = if restored.is_ok() {
                capture(&self.master).ok().filter(|current| {
                    current.identity == expected.identity
                        && current.links == expected.links
                        && current.bytes == expected.bytes
                })
            } else {
                None
            };
            let recovered_ok = recovered.is_some();
            if let Some(recovered) = recovered {
                self.snapshot = Some(recovered);
            }
            anyhow::bail!(
                "Save failed; {}. A private recovery copy remains at {}",
                if recovered_ok {
                    "the original file bytes were restored"
                } else {
                    "automatic recovery did not complete"
                },
                backup.display()
            );
        }
        let (resolved, links) = path_state(&self.master)?;
        let current = Snapshot {
            resolved,
            links,
            identity: native_file::file_identity(&file)?,
            modified: file.metadata()?.modified()?,
            bytes: read_bounded(&mut file)?,
        };
        ensure!(
            current.identity == expected.identity
                && current.links == expected.links
                && current.bytes == text.as_bytes(),
            "Save verification failed; the private recovery copy remains at {}",
            backup.display()
        );
        // Windows may finalize LastWriteTime only after closing its write
        // handle. Release the lease, then capture/verify the exact saved bytes
        // again before adopting a reusable baseline or removing recovery.
        drop(file);
        let refreshed = capture(&self.master).with_context(|| {
            format!(
                "Saved bytes need verification; a private recovery copy remains at {}",
                backup.display()
            )
        })?;
        ensure!(
            refreshed.identity == expected.identity
                && refreshed.links == expected.links
                && refreshed.bytes == text.as_bytes(),
            "Instruction file changed after Save; a private recovery copy remains at {}",
            backup.display()
        );
        self.snapshot = Some(refreshed);
        // Successful verified Save is the only automatic recovery-file removal.
        drop(recovery);
        fs::remove_file(&backup)
            .context("Saved successfully, but its private recovery copy could not be removed")?;
        Ok(())
    }
}
fn matches_source(master: &Path, expected: &Snapshot, file: &mut File) -> Result<bool> {
    let (resolved, links) = path_state(master)?;
    Ok(resolved == expected.resolved
        && links == expected.links
        && native_file::file_identity(file)? == expected.identity
        && file.metadata()?.modified()? == expected.modified
        && native_file::path_identity(&resolved)? == expected.identity
        && read_bounded(file)? == expected.bytes)
}
fn links(path: &Path) -> Result<Vec<LinkState>> {
    ensure!(path.is_absolute(), "Instruction source must be absolute");
    let mut current = PathBuf::new();
    let mut result = Vec::new();
    for component in path.components() {
        current.push(component.as_os_str());
        if !current.is_absolute() {
            continue;
        }
        let target = native_file::link_target(&current)?;
        result.push(LinkState {
            path: current.clone(),
            identity: native_file::path_identity(&current)?,
            link_modified: if target.is_some() {
                Some(fs::symlink_metadata(&current)?.modified()?)
            } else {
                None
            },
            target,
        });
    }
    Ok(result)
}
fn read_bounded(file: &mut File) -> Result<Vec<u8>> {
    ensure!(
        file.metadata()?.is_file() && file.metadata()?.len() <= LIMIT as u64,
        "Instructions must be a regular UTF-8 file of at most 1 MiB"
    );
    file.seek(SeekFrom::Start(0))?;
    let mut bytes = Vec::new();
    file.take(LIMIT as u64 + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= LIMIT,
        "Instructions exceeded 1 MiB while reading"
    );
    std::str::from_utf8(&bytes).context("Instructions are not UTF-8 text")?;
    Ok(bytes)
}
fn capture(master: &Path) -> Result<Snapshot> {
    let (resolved, all_links) = path_state(master)?;
    let mut file = native_file::open_regular(&resolved, false)?;
    let identity = native_file::file_identity(&file)?;
    let modified = file.metadata()?.modified()?;
    let bytes = read_bounded(&mut file)?;
    ensure!(
        path_state(master)? == (resolved.clone(), all_links.clone())
            && native_file::path_identity(&resolved)? == identity
            && file.metadata()?.modified()? == modified
            && read_bounded(&mut file)? == bytes,
        "Instructions changed while reading; reload them"
    );
    Ok(Snapshot {
        resolved,
        links: all_links,
        identity,
        modified,
        bytes,
    })
}
fn path_state(master: &Path) -> Result<(PathBuf, Vec<LinkState>)> {
    let mut all = links(master)?;
    let resolved = master.canonicalize()?;
    all.extend(links(&resolved)?);
    Ok((resolved, all))
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture {
        root: PathBuf,
        master: PathBuf,
        recovery: PathBuf,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "coincide-global-editor-fixture-{}",
                uuid::Uuid::new_v4()
            ));
            native_file::private_directory(&root).unwrap();
            let master = root.join("AGENTS.md");
            let mut file = native_file::create_private_file(&master).unwrap();
            file.write_all(b"# Private synthetic instructions\nKeep every byte.\r\n")
                .unwrap();
            file.sync_all().unwrap();
            Self {
                recovery: root.join("recovery"),
                root,
                master,
            }
        }
        fn editor(&self) -> EditorFile {
            EditorFile::fixture(self.master.clone(), self.recovery.clone())
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
    #[test]
    fn typed_project_scope_binds_exact_source_without_adopting_imported_master_paths() {
        let fixture = Fixture::new();
        let mut store =
            coincide_core::store::Store::open(&fixture.root.join("state.sqlite")).unwrap();
        let project = store
            .create_project(&fixture.root, Some("Synthetic native project"))
            .unwrap();
        store.save_document("instructions.json",&serde_json::json!({"global":{"masterPath":"/untrusted/imported/AGENTS.md","isEnabled":true}})).unwrap();
        let scope = super::super::super::instructions_scope::NativeScope::project_native(
            &store,
            project["id"].as_str().unwrap(),
        )
        .unwrap();
        let mut editor = EditorFile::from_native_scope(&scope).unwrap();
        // Override only the recovery destination in this synthetic fixture; the
        // production source constructor still accepts the typed scope alone.
        editor.recovery_root = fixture.recovery.clone();
        assert_eq!(editor.path(), fixture.master.canonicalize().unwrap());
        let original = editor.load().unwrap();
        assert!(original.contains("Private synthetic instructions"));
        editor
            .save("Saved to the bound synthetic project only\n")
            .unwrap();
        assert_eq!(
            fs::read_to_string(&fixture.master).unwrap(),
            "Saved to the bound synthetic project only\n"
        );
        store.close_for_shutdown().unwrap();
    }
    #[test]
    fn retained_review_writer_refuses_same_bytes_replacement_between_plan_check_and_write() {
        let fixture = Fixture::new();
        let mut store =
            coincide_core::store::Store::open(&fixture.root.join("review.sqlite")).unwrap();
        let project = store
            .create_project(&fixture.root, Some("Synthetic retained review"))
            .unwrap();
        let scope = super::super::super::instructions_scope::NativeScope::project_native(
            &store,
            project["id"].as_str().unwrap(),
        )
        .unwrap();
        fs::write(fixture.root.join("CLAUDE.md"), "Synthetic merge source\n").unwrap();
        let mut writer = EditorFile::from_native_scope(&scope).unwrap();
        writer.recovery_root = fixture.recovery.clone();
        let baseline = writer.load().unwrap();
        let plan = scope.review_native(&store).unwrap();
        writer.validate_review_source().unwrap();
        let choices = plan
            .targets
            .iter()
            .map(|t| t.state.default_choice())
            .collect::<Vec<_>>();
        let old = fixture.root.join("original-reviewed.md");
        let error = plan
            .apply_native(&store, &choices, |path, expected, replacement| {
                assert_eq!(expected, baseline);
                fs::rename(path, &old)?;
                fs::write(path, expected)?;
                // The path now has the same bytes but a different identity. No
                // apply-time reload may adopt it into the retained Save capability.
                writer.save(replacement)
            })
            .err()
            .unwrap();
        assert!(error.to_string().contains("replaced"), "{error}");
        assert_eq!(fs::read_to_string(&fixture.master).unwrap(), baseline);
        assert_eq!(fs::read_to_string(&old).unwrap(), baseline);
        assert_eq!(
            fs::read_to_string(fixture.root.join("CLAUDE.md")).unwrap(),
            "Synthetic merge source\n"
        );
        assert!(
            !fs::symlink_metadata(fixture.root.join("CLAUDE.md"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert!(!fixture.recovery.exists());
        store.close_for_shutdown().unwrap();
    }
    #[test]
    fn explicit_save_preserves_master_file_identity_and_exact_utf8_bytes() {
        let fixture = Fixture::new();
        let mut editor = fixture.editor();
        let original = editor.load().unwrap();
        assert!(original.ends_with("\r\n"));
        let identity = native_file::path_identity(&fixture.master).unwrap();
        let text = "# Synthetic global master\nCafé 中文\n\n";
        editor.save(text).unwrap();
        assert_eq!(fs::read(&fixture.master).unwrap(), text.as_bytes());
        assert_eq!(
            native_file::path_identity(&fixture.master).unwrap(),
            identity
        );
        assert_eq!(editor.baseline(), Some(text));
        editor
            .save("# A second explicit Save uses the finalized file timestamp\n")
            .unwrap();
        assert_eq!(
            native_file::path_identity(&fixture.master).unwrap(),
            identity
        );
        assert_eq!(fs::read_dir(&fixture.recovery).unwrap().count(), 0);
    }
    #[test]
    fn external_byte_change_and_file_replacement_cannot_be_overwritten() {
        let fixture = Fixture::new();
        let mut editor = fixture.editor();
        editor.load().unwrap();
        fs::write(&fixture.master, "External synthetic update\n").unwrap();
        assert!(editor.save("Must not replace external update").is_err());
        assert_eq!(
            fs::read_to_string(&fixture.master).unwrap(),
            "External synthetic update\n"
        );
        assert!(!fixture.recovery.exists());
        editor.load().unwrap();
        let previous = fixture.root.join("previous.md");
        fs::rename(&fixture.master, &previous).unwrap();
        fs::write(&fixture.master, "External synthetic update\n").unwrap();
        assert!(
            editor
                .save("Same bytes on another inode grant no authority")
                .is_err()
        );
        assert_eq!(
            fs::read_to_string(&fixture.master).unwrap(),
            "External synthetic update\n"
        );
    }
    #[test]
    fn partial_write_failure_restores_original_inode_bytes_and_retains_private_recovery() {
        let fixture = Fixture::new();
        let mut editor = fixture.editor();
        let original = editor.load().unwrap();
        let identity = native_file::path_identity(&fixture.master).unwrap();
        let error = editor
            .save_using("Replacement synthetic text", |file, _| {
                file.seek(SeekFrom::Start(0))?;
                file.write_all(b"partial")?;
                file.set_len(7)?;
                anyhow::bail!("synthetic failure after mutation")
            })
            .unwrap_err()
            .to_string();
        assert!(error.contains("original file bytes were restored"));
        assert!(
            !error.contains("Keep every byte"),
            "Diagnostics must never include instruction contents"
        );
        assert_eq!(fs::read(&fixture.master).unwrap(), original.as_bytes());
        assert_eq!(
            native_file::path_identity(&fixture.master).unwrap(),
            identity
        );
        let recovery = fs::read_dir(&fixture.recovery)
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        assert_eq!(fs::read(&recovery).unwrap(), original.as_bytes());
        editor
            .save("A subsequent explicit Save succeeds after rollback\n")
            .unwrap();
        assert_eq!(
            native_file::path_identity(&fixture.master).unwrap(),
            identity
        );
        assert_eq!(
            fs::read(&recovery).unwrap(),
            original.as_bytes(),
            "The earlier failed-operation recovery is never silently deleted"
        );
    }
    #[test]
    fn busy_exclusive_save_lease_refuses_without_any_instruction_mutation() {
        let fixture = Fixture::new();
        let mut editor = fixture.editor();
        let original = editor.load().unwrap();
        let locked = native_file::open_regular(&fixture.master, true).unwrap();
        locked.try_lock().unwrap();
        assert!(
            editor
                .save("Must not write through another editor lease")
                .is_err()
        );
        drop(locked);
        assert_eq!(fs::read(&fixture.master).unwrap(), original.as_bytes());
        assert!(!fixture.recovery.exists());
    }
    #[test]
    fn oversized_invalid_utf8_and_missing_files_cannot_gain_save_authority() {
        let fixture = Fixture::new();
        for bytes in [vec![b'x'; LIMIT + 1], vec![0xff, 0xfe]] {
            fs::write(&fixture.master, bytes).unwrap();
            let mut editor = fixture.editor();
            assert!(editor.load().is_err());
            assert!(editor.save("No blank fallback overwrite").is_err());
        }
        fs::remove_file(&fixture.master).unwrap();
        let mut editor = fixture.editor();
        assert!(editor.load().is_err());
        assert!(
            editor
                .save("Do not create a missing master implicitly")
                .is_err()
        );
        assert!(!fixture.master.exists());
        assert!(!fixture.recovery.exists());
    }
    #[cfg(unix)]
    #[test]
    fn native_save_keeps_all_active_aliases_and_retargeted_master_link_fails_cas() {
        use std::os::unix::fs::symlink;
        let fixture = Fixture::new();
        let alias = fixture.root.join("CLAUDE.md");
        symlink("AGENTS.md", &alias).unwrap();
        let before = fs::read_link(&alias).unwrap();
        let mut editor = fixture.editor();
        editor.load().unwrap();
        editor.save("# Saved through original inode\n").unwrap();
        assert_eq!(fs::read_link(&alias).unwrap(), before);
        assert_eq!(
            fs::read_to_string(&alias).unwrap(),
            "# Saved through original inode\n"
        );
        let mut linked = EditorFile::fixture(alias.clone(), fixture.recovery.clone());
        linked.load().unwrap();
        fs::remove_file(&alias).unwrap();
        symlink("AGENTS.md", &alias).unwrap();
        assert!(
            linked
                .save("A new symlink inode cannot reuse old editor authority")
                .is_err()
        );
        assert_eq!(
            fs::read_to_string(&fixture.master).unwrap(),
            "# Saved through original inode\n"
        );
    }
}
