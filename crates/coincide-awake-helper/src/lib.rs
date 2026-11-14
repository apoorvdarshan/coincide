//! Pure decisions for the opt-in macOS lid and battery helpers. Tests use fake
//! hardware and private fixture files; constructing these types has no effects.
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Preferences {
    pub enabled: bool,
    pub display_off_on_close: bool,
    pub keep_displays_off: bool,
    pub mute_while_closed: bool,
    pub sleep_on_battery: bool,
    pub battery_approval_pending: bool,
    pub battery_disable_pending: bool,
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            enabled: false,
            display_off_on_close: true,
            keep_displays_off: false,
            mute_while_closed: false,
            sleep_on_battery: false,
            battery_approval_pending: false,
            battery_disable_pending: false,
        }
    }
}

impl Preferences {
    /// Unknown, missing, interrupted, or unsupported documents never enable a
    /// helper. An existing version-one 24/7 setting gets Swift's defaults.
    pub fn from_document(document: Option<&Value>) -> Result<Self> {
        let defaults = Self::default();
        let Some(document) = document else {
            return Ok(defaults);
        };
        ensure!(document["version"] == 1, "Unsupported Keep Awake settings");
        let enabled = match document["stage"].as_str() {
            Some("enabled") => true,
            Some("prepared" | "off") => false,
            _ => anyhow::bail!("Invalid Keep Awake stage"),
        };
        let options = document.get("options");
        ensure!(
            options.is_none_or(Value::is_object),
            "Invalid Keep Awake options"
        );
        let flag = |key: &str, default: bool| -> Result<bool> {
            match options.and_then(|options| options.get(key)) {
                None => Ok(default),
                Some(value) => value.as_bool().with_context(|| format!("Invalid {key}")),
            }
        };
        let battery_approval_pending = flag("batteryApprovalPending", false)?;
        let battery_disable_pending = flag("batteryDisablePending", false)?;
        ensure!(
            !(battery_approval_pending && battery_disable_pending),
            "Conflicting battery transitions"
        );
        Ok(Self {
            enabled,
            display_off_on_close: flag("displayOffOnClose", true)?,
            keep_displays_off: flag("keepDisplaysOff", false)?,
            mute_while_closed: flag("muteWhileClosed", false)?,
            sleep_on_battery: flag("sleepOnBattery", false)?,
            battery_approval_pending,
            battery_disable_pending,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AudioState {
    pub uid: String,
    pub muted: bool,
}

pub trait LidHardware {
    fn sleep_displays(&mut self) -> Result<()>;
    fn idle_seconds(&mut self) -> Result<Option<f64>>;
    fn default_output(&mut self) -> Result<Option<AudioState>>;
    fn output_muted(&mut self, uid: &str) -> Result<Option<bool>>;
    fn set_output_muted(&mut self, uid: &str, muted: bool) -> Result<bool>;
}

pub trait AudioJournal {
    fn load(&mut self) -> Result<Vec<AudioState>>;
    /// Persist the full set before muting or after a confirmed restoration.
    fn save(&mut self, states: &[AudioState]) -> Result<()>;
}

#[derive(Default)]
pub struct LidWatcher {
    previous_lid: Option<bool>,
}

impl LidWatcher {
    /// Returns whether a short tick is needed. Unknown lid state never causes a
    /// display or mute change; already-saved audio remains recoverable.
    pub fn update(
        &mut self,
        hardware: &mut impl LidHardware,
        journal: &mut impl AudioJournal,
        preferences: Preferences,
        lid_closed: Option<bool>,
        tick: bool,
    ) -> Result<bool> {
        let changed = lid_closed.is_some() && lid_closed != self.previous_lid;
        let mut saved = journal.load()?;
        if !preferences.enabled || !preferences.mute_while_closed || lid_closed == Some(false) {
            restore_audio(hardware, journal, &mut saved)?;
        }
        if preferences.enabled && lid_closed == Some(true) {
            if changed && preferences.display_off_on_close {
                hardware.sleep_displays()?;
            } else if tick
                && preferences.keep_displays_off
                && hardware
                    .idle_seconds()?
                    .is_some_and(|idle| (0.0..3.0).contains(&idle))
            {
                hardware.sleep_displays()?;
            }
            self.previous_lid = lid_closed;
            if preferences.mute_while_closed
                && let Some(output) = hardware.default_output()?
                && !output.muted
            {
                if !saved.iter().any(|state| state.uid == output.uid) {
                    ensure!(saved.len() < 32, "Too many audio devices to restore");
                    ensure!(
                        !output.uid.is_empty() && output.uid.len() <= 1024,
                        "Invalid audio device identity"
                    );
                    saved.push(output.clone());
                    journal.save(&saved)?;
                }
                let _ = hardware.set_output_muted(&output.uid, true)?;
            }
        } else if lid_closed.is_some() {
            self.previous_lid = lid_closed;
        }
        Ok((preferences.enabled && lid_closed == Some(true)) || !saved.is_empty())
    }

    /// Called on orderly shutdown or when the user turns the feature off.
    pub fn stop(
        &mut self,
        hardware: &mut impl LidHardware,
        journal: &mut impl AudioJournal,
    ) -> Result<bool> {
        let mut saved = journal.load()?;
        restore_audio(hardware, journal, &mut saved)?;
        Ok(saved.is_empty())
    }
}

fn restore_audio(
    hardware: &mut impl LidHardware,
    journal: &mut impl AudioJournal,
    saved: &mut Vec<AudioState>,
) -> Result<()> {
    if saved.is_empty() {
        return Ok(());
    }
    let mut remaining = Vec::new();
    for state in saved.iter() {
        let restored = match hardware.output_muted(&state.uid) {
            Ok(Some(current)) if current == state.muted => true,
            Ok(Some(_)) => hardware
                .set_output_muted(&state.uid, state.muted)
                .unwrap_or(false),
            _ => false,
        };
        if !restored {
            remaining.push(state.clone());
        }
    }
    if remaining.len() != saved.len() {
        journal.save(&remaining)?;
        *saved = remaining;
    }
    Ok(())
}

/// `disablesleep` is global. A registered privileged helper changes it only
/// when the power source and current state are both known and disagree.
pub fn battery_change(on_battery: Option<bool>, sleep_disabled: Option<bool>) -> Option<bool> {
    let wanted = !on_battery?;
    (sleep_disabled? != wanted).then_some(wanted)
}

#[cfg(target_os = "macos")]
pub fn on_battery() -> Option<bool> {
    unsafe extern "C" {
        fn coincide_awake_on_battery() -> std::ffi::c_int;
    }
    match unsafe { coincide_awake_on_battery() } {
        0 => Some(false),
        1 => Some(true),
        _ => None,
    }
}

#[cfg(unix)]
pub mod journal {
    use super::{AudioJournal, AudioState};
    use anyhow::{Context, Result, ensure};
    use serde::{Deserialize, Serialize};
    use std::{
        collections::HashSet,
        fs::{self, File, OpenOptions},
        io::{Read, Write},
        os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
        path::{Path, PathBuf},
        sync::atomic::{AtomicU64, Ordering},
    };

    const FILE: &str = "always-on-audio-state.json";
    const MAX_BYTES: u64 = 64 * 1024;
    static NONCE: AtomicU64 = AtomicU64::new(0);

    #[derive(Serialize, Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Document {
        version: u8,
        devices: Vec<AudioState>,
    }

    pub struct FileJournal {
        directory: PathBuf,
    }

    impl FileJournal {
        /// The caller supplies only the app's existing private data directory.
        pub fn new(directory: &Path) -> Result<Self> {
            ensure!(
                directory.is_absolute(),
                "Audio journal directory must be absolute"
            );
            let metadata = fs::symlink_metadata(directory)?;
            ensure!(
                metadata.is_dir()
                    && !metadata.file_type().is_symlink()
                    && metadata.uid() == unsafe { libc::geteuid() }
                    && metadata.permissions().mode() & 0o077 == 0,
                "Audio journal directory is not private"
            );
            Ok(Self {
                directory: directory.to_owned(),
            })
        }
        fn path(&self) -> PathBuf {
            self.directory.join(FILE)
        }
        fn sync_directory(&self) -> Result<()> {
            File::open(&self.directory)?
                .sync_all()
                .context("Sync audio journal directory")
        }
    }

    fn validate(states: &[AudioState]) -> Result<()> {
        ensure!(states.len() <= 32, "Too many saved audio devices");
        let mut seen = HashSet::new();
        for state in states {
            ensure!(
                !state.uid.is_empty() && state.uid.len() <= 1024 && !state.uid.contains('\0'),
                "Invalid saved audio device"
            );
            ensure!(seen.insert(&state.uid), "Duplicate saved audio device");
        }
        Ok(())
    }

    impl AudioJournal for FileJournal {
        fn load(&mut self) -> Result<Vec<AudioState>> {
            let mut file = match OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(self.path())
            {
                Ok(file) => file,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
                Err(error) => return Err(error.into()),
            };
            let metadata = file.metadata()?;
            ensure!(
                metadata.is_file()
                    && metadata.uid() == unsafe { libc::geteuid() }
                    && metadata.permissions().mode() & 0o077 == 0
                    && metadata.len() <= MAX_BYTES,
                "Audio restore journal is not private or is too large"
            );
            let mut bytes = Vec::new();
            Read::by_ref(&mut file)
                .take(MAX_BYTES + 1)
                .read_to_end(&mut bytes)?;
            ensure!(
                bytes.len() as u64 <= MAX_BYTES,
                "Audio restore journal is too large"
            );
            let document: Document =
                serde_json::from_slice(&bytes).context("Invalid audio restore journal")?;
            ensure!(document.version == 1, "Unsupported audio restore journal");
            validate(&document.devices)?;
            Ok(document.devices)
        }

        fn save(&mut self, states: &[AudioState]) -> Result<()> {
            validate(states)?;
            if states.is_empty() {
                match fs::remove_file(self.path()) {
                    Ok(()) => self.sync_directory()?,
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(error) => return Err(error.into()),
                }
                return Ok(());
            }
            let bytes = serde_json::to_vec(&Document {
                version: 1,
                devices: states.to_vec(),
            })?;
            ensure!(
                bytes.len() as u64 <= MAX_BYTES,
                "Audio restore journal is too large"
            );
            let name = format!(
                ".always-on-audio-{}-{}",
                std::process::id(),
                NONCE.fetch_add(1, Ordering::Relaxed)
            );
            let temp = self.directory.join(name);
            let result = (|| -> Result<()> {
                let mut file = OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                    .open(&temp)?;
                file.write_all(&bytes)?;
                file.sync_all()?;
                fs::rename(&temp, self.path())?;
                self.sync_directory()?;
                Ok(())
            })();
            if result.is_err() {
                let _ = fs::remove_file(&temp);
            }
            result
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[derive(Default)]
    struct FakeHardware {
        displays_slept: usize,
        idle: Option<f64>,
        default: Option<String>,
        outputs: BTreeMap<String, bool>,
        writes: Vec<(String, bool)>,
    }
    impl LidHardware for FakeHardware {
        fn sleep_displays(&mut self) -> Result<()> {
            self.displays_slept += 1;
            Ok(())
        }
        fn idle_seconds(&mut self) -> Result<Option<f64>> {
            Ok(self.idle)
        }
        fn default_output(&mut self) -> Result<Option<AudioState>> {
            Ok(self.default.as_ref().and_then(|uid| {
                self.outputs.get(uid).map(|muted| AudioState {
                    uid: uid.clone(),
                    muted: *muted,
                })
            }))
        }
        fn output_muted(&mut self, uid: &str) -> Result<Option<bool>> {
            Ok(self.outputs.get(uid).copied())
        }
        fn set_output_muted(&mut self, uid: &str, muted: bool) -> Result<bool> {
            let Some(value) = self.outputs.get_mut(uid) else {
                return Ok(false);
            };
            *value = muted;
            self.writes.push((uid.into(), muted));
            Ok(true)
        }
    }
    #[derive(Default)]
    struct FakeJournal {
        states: Vec<AudioState>,
        fail_save: bool,
    }
    impl AudioJournal for FakeJournal {
        fn load(&mut self) -> Result<Vec<AudioState>> {
            Ok(self.states.clone())
        }
        fn save(&mut self, states: &[AudioState]) -> Result<()> {
            ensure!(!self.fail_save, "fixture save failed");
            self.states = states.to_vec();
            Ok(())
        }
    }
    fn prefs() -> Preferences {
        Preferences {
            enabled: true,
            display_off_on_close: true,
            keep_displays_off: false,
            mute_while_closed: false,
            sleep_on_battery: false,
            battery_approval_pending: false,
            battery_disable_pending: false,
        }
    }

    #[test]
    fn display_sleeps_once_on_close_and_only_repeats_for_recent_input() {
        let (mut watcher, mut hardware, mut journal) = (
            LidWatcher::default(),
            FakeHardware::default(),
            FakeJournal::default(),
        );
        watcher
            .update(&mut hardware, &mut journal, prefs(), Some(false), false)
            .unwrap();
        watcher
            .update(&mut hardware, &mut journal, prefs(), Some(true), false)
            .unwrap();
        watcher
            .update(&mut hardware, &mut journal, prefs(), Some(true), true)
            .unwrap();
        assert_eq!(hardware.displays_slept, 1);
        let mut keep = prefs();
        keep.keep_displays_off = true;
        hardware.idle = Some(10.0);
        watcher
            .update(&mut hardware, &mut journal, keep, Some(true), true)
            .unwrap();
        assert_eq!(hardware.displays_slept, 1);
        hardware.idle = Some(0.5);
        watcher
            .update(&mut hardware, &mut journal, keep, Some(true), true)
            .unwrap();
        assert_eq!(hardware.displays_slept, 2);
        watcher
            .update(&mut hardware, &mut journal, keep, None, true)
            .unwrap();
        assert_eq!(hardware.displays_slept, 2);
    }

    #[test]
    fn mute_is_journaled_before_change_and_all_changed_devices_are_restored() {
        let (mut watcher, mut hardware, mut journal) = (
            LidWatcher::default(),
            FakeHardware::default(),
            FakeJournal::default(),
        );
        hardware.outputs.insert("speakers".into(), false);
        hardware.outputs.insert("headphones".into(), false);
        hardware.default = Some("speakers".into());
        let mut muted = prefs();
        muted.mute_while_closed = true;
        muted.display_off_on_close = false;
        journal.fail_save = true;
        assert!(
            watcher
                .update(&mut hardware, &mut journal, muted, Some(true), false)
                .is_err()
        );
        assert!(hardware.writes.is_empty());
        journal.fail_save = false;
        watcher
            .update(&mut hardware, &mut journal, muted, Some(true), true)
            .unwrap();
        hardware.default = Some("headphones".into());
        watcher
            .update(&mut hardware, &mut journal, muted, Some(true), true)
            .unwrap();
        assert_eq!(journal.states.len(), 2);
        hardware.outputs.remove("speakers");
        watcher
            .update(&mut hardware, &mut journal, muted, Some(false), false)
            .unwrap();
        assert_eq!(hardware.outputs["headphones"], false);
        assert_eq!(journal.states.len(), 1);
        hardware.outputs.insert("speakers".into(), true);
        assert!(watcher.stop(&mut hardware, &mut journal).unwrap());
        assert_eq!(hardware.outputs["speakers"], false);
        assert!(journal.states.is_empty());
    }

    #[test]
    fn already_muted_audio_is_not_changed_or_recorded() {
        let (mut watcher, mut hardware, mut journal) = (
            LidWatcher::default(),
            FakeHardware::default(),
            FakeJournal::default(),
        );
        hardware.outputs.insert("speakers".into(), true);
        hardware.default = Some("speakers".into());
        let mut muted = prefs();
        muted.mute_while_closed = true;
        muted.display_off_on_close = false;
        watcher
            .update(&mut hardware, &mut journal, muted, Some(true), false)
            .unwrap();
        watcher
            .update(&mut hardware, &mut journal, muted, Some(false), false)
            .unwrap();
        assert!(hardware.writes.is_empty());
        assert!(journal.states.is_empty());
    }

    #[test]
    fn battery_never_guesses_unknown_values_or_writes_when_already_correct() {
        assert_eq!(battery_change(None, Some(true)), None);
        assert_eq!(battery_change(Some(true), None), None);
        assert_eq!(battery_change(Some(true), Some(true)), Some(false));
        assert_eq!(battery_change(Some(false), Some(false)), Some(true));
        assert_eq!(battery_change(Some(false), Some(true)), None);
        assert_eq!(battery_change(Some(true), Some(false)), None);
    }

    #[test]
    fn invalid_and_interrupted_documents_never_activate_the_helper() {
        assert!(!Preferences::from_document(None).unwrap().enabled);
        assert!(
            !Preferences::from_document(Some(&serde_json::json!({"version":1,"stage":"prepared"})))
                .unwrap()
                .enabled
        );
        assert!(
            Preferences::from_document(Some(&serde_json::json!({"version":2,"stage":"enabled"})))
                .is_err()
        );
        assert!(Preferences::from_document(Some(&serde_json::json!({"version":1,"stage":"enabled","options":{"muteWhileClosed":"yes"}}))).is_err());
        let existing =
            Preferences::from_document(Some(&serde_json::json!({"version":1,"stage":"enabled"})))
                .unwrap();
        assert!(existing.enabled && existing.display_off_on_close && !existing.mute_while_closed);
    }

    #[cfg(unix)]
    #[test]
    fn audio_restore_journal_survives_reopen_and_refuses_symlinks() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut journal = journal::FileJournal::new(directory.path()).unwrap();
        let saved = vec![AudioState {
            uid: "synthetic-output".into(),
            muted: false,
        }];
        journal.save(&saved).unwrap();
        let path = directory.path().join("always-on-audio-state.json");
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        drop(journal);
        let mut reopened = journal::FileJournal::new(directory.path()).unwrap();
        assert_eq!(reopened.load().unwrap(), saved);
        reopened.save(&[]).unwrap();
        assert!(!path.exists());

        let unrelated = directory.path().join("unrelated");
        std::fs::write(&unrelated, b"keep").unwrap();
        symlink(&unrelated, &path).unwrap();
        assert!(reopened.load().is_err());
        assert_eq!(std::fs::read(&unrelated).unwrap(), b"keep");
    }

    #[cfg(unix)]
    #[test]
    fn audio_restore_journal_requires_a_private_owned_directory() {
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(journal::FileJournal::new(directory.path()).is_err());
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    }
}
