//! Explicit macOS 24/7 sleep setting. Merely opening Settings or starting the
//! app never changes system power. The restore journal is written before the
//! user-authorized command, so an interrupted operation can still be undone.
use anyhow::{Context, Result, bail, ensure};
use coincide_core::api::SharedEngine;
use serde_json::{Value, json};

const DOCUMENT: &str = "rust-persistent-awake.json";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Power {
    sleep_disabled: bool,
    charger_sleep: u32,
}
impl Power {
    fn parse(general: &str, custom: &str) -> Result<Self> {
        let sleep_disabled = general
            .lines()
            .filter_map(|line| {
                let mut fields = line.split_whitespace();
                (fields.next()? == "SleepDisabled")
                    .then(|| fields.next())
                    .flatten()
            })
            .last()
            .map_or(Ok(false), |value| match value {
                "0" => Ok(false),
                "1" => Ok(true),
                _ => bail!("Unrecognized SleepDisabled value"),
            })?;
        let mut ac = false;
        let mut charger_sleep = None;
        for line in custom.lines() {
            let line = line.trim();
            if line.ends_with("Power:") {
                ac = line == "AC Power:";
                continue;
            }
            if ac {
                let mut fields = line.split_whitespace();
                if fields.next() == Some("sleep") {
                    let minutes: u32 = fields
                        .next()
                        .context("Missing charger sleep timer")?
                        .parse()?;
                    ensure!(minutes <= 100_000, "Invalid charger sleep timer");
                    charger_sleep = Some(minutes);
                }
            }
        }
        Ok(Self {
            sleep_disabled,
            charger_sleep: charger_sleep.context("Charger sleep timer is unavailable")?,
        })
    }
    fn from_value(value: &Value) -> Result<Self> {
        let sleep_disabled = value["sleepDisabled"]
            .as_bool()
            .context("Invalid saved sleep setting")?;
        let charger_sleep = value["chargerSleep"]
            .as_u64()
            .context("Invalid saved charger timer")?;
        ensure!(charger_sleep <= 100_000, "Invalid saved charger timer");
        Ok(Self {
            sleep_disabled,
            charger_sleep: charger_sleep as u32,
        })
    }
    fn value(self) -> Value {
        json!({"sleepDisabled":self.sleep_disabled,"chargerSleep":self.charger_sleep})
    }
    fn restore_script(self) -> String {
        format!(
            "failed=; /usr/bin/pmset -c sleep {} || failed=1; /usr/bin/pmset -a disablesleep {} || failed=1; [ -z \"$failed\" ]",
            self.charger_sleep,
            u8::from(self.sleep_disabled)
        )
    }
    fn apply_script(self) -> String {
        // Only fixed commands and validated integers enter this shell script.
        format!(
            "{{ /usr/bin/pmset -c sleep 0 && /usr/bin/pmset -a disablesleep 1; }} || {{ {}; exit 1; }}",
            self.restore_script()
        )
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Admin {
    Done,
    Cancelled,
}
#[derive(Clone, Copy)]
pub(super) enum Action {
    Enable,
    Disable,
    Reapply,
}
trait Backend {
    fn read_power(&mut self) -> Result<Power>;
    fn authorize(&mut self, script: &str, enabling: bool) -> Result<Admin>;
}
trait Journal {
    fn load(&mut self) -> Result<Option<Value>>;
    fn save(&mut self, value: &Value) -> Result<()>;
}
fn stage(value: Option<&Value>) -> Result<&str> {
    let Some(value) = value else { return Ok("off") };
    ensure!(value["version"] == 1, "Unsupported Keep Awake journal");
    match value["stage"].as_str() {
        Some("off") => Ok("off"),
        Some("prepared" | "enabled") => {
            Power::from_value(&value["original"])?;
            Ok(value["stage"].as_str().unwrap())
        }
        _ => bail!("Invalid Keep Awake journal"),
    }
}
fn transition(
    journal: &mut impl Journal,
    backend: &mut impl Backend,
    action: Action,
) -> Result<Admin> {
    let previous = journal.load()?;
    let current = stage(previous.as_ref())?;
    if matches!(action, Action::Enable | Action::Reapply) {
        if matches!(action, Action::Reapply) {
            ensure!(
                current == "enabled",
                "Keep Awake must be on before it can be reapplied"
            );
            let before = backend.read_power()?;
            match backend.authorize(&before.apply_script(), true)? {
                Admin::Done => {
                    let applied = backend.read_power()?;
                    ensure!(
                        applied.sleep_disabled && applied.charger_sleep == 0,
                        "macOS did not confirm the requested sleep settings"
                    );
                    return Ok(Admin::Done);
                }
                Admin::Cancelled => return Ok(Admin::Cancelled),
            }
        }
        ensure!(
            current == "off",
            "Restore the previous sleep settings first"
        );
        let power = backend.read_power()?;
        // Save the original values before any administrator command is run.
        journal.save(&json!({"version":1,"stage":"prepared","original":power.value()}))?;
        match backend.authorize(&power.apply_script(), true) {
            Ok(Admin::Done) => {
                let applied = backend.read_power()?;
                ensure!(
                    applied.sleep_disabled && applied.charger_sleep == 0,
                    "macOS did not confirm the requested sleep settings; restore the saved settings"
                );
                journal.save(&json!({"version":1,"stage":"enabled","original":power.value()}))?;
                Ok(Admin::Done)
            }
            Ok(Admin::Cancelled) => {
                // No shell command runs when the administrator prompt is cancelled.
                journal.save(&json!({"version":1,"stage":"off"}))?;
                Ok(Admin::Cancelled)
            }
            // The command may have run partially or completed without an
            // acknowledgement. Keep the journal so Restore remains available.
            Err(error) => Err(error),
        }
    } else {
        ensure!(
            current != "off",
            "There are no Coincide sleep settings to restore"
        );
        let original = Power::from_value(&previous.as_ref().unwrap()["original"])?;
        match backend.authorize(&original.restore_script(), false)? {
            Admin::Done => {
                ensure!(
                    backend.read_power()? == original,
                    "macOS did not confirm the restored sleep settings; try restoring again"
                );
                journal.save(&json!({"version":1,"stage":"off"}))?;
                Ok(Admin::Done)
            }
            Admin::Cancelled => Ok(Admin::Cancelled),
        }
    }
}

struct EngineJournal(SharedEngine);
impl Journal for EngineJournal {
    fn load(&mut self) -> Result<Option<Value>> {
        self.0
            .lock()
            .map_err(|_| anyhow::anyhow!("App engine unavailable"))?
            .store
            .local_document(DOCUMENT)
    }
    fn save(&mut self, value: &Value) -> Result<()> {
        self.0
            .lock()
            .map_err(|_| anyhow::anyhow!("App engine unavailable"))?
            .store
            .save_document(DOCUMENT, value)
    }
}

#[cfg(target_os = "macos")]
struct MacBackend;
#[cfg(target_os = "macos")]
impl Backend for MacBackend {
    fn read_power(&mut self) -> Result<Power> {
        fn read(args: &[&str]) -> Result<String> {
            let output = std::process::Command::new("/usr/bin/pmset")
                .args(args)
                .output()
                .context("Could not read sleep settings")?;
            ensure!(
                output.status.success(),
                "macOS did not return sleep settings"
            );
            String::from_utf8(output.stdout).context("Invalid sleep settings")
        }
        Power::parse(&read(&["-g"])?, &read(&["-g", "custom"])?)
    }
    fn authorize(&mut self, script: &str, enabling: bool) -> Result<Admin> {
        let prompt = if enabling {
            "Coincide needs permission to keep this Mac awake with the lid closed. It will restore the previous sleep settings when you turn this off."
        } else {
            "Coincide needs permission to restore this Mac's previous sleep settings."
        };
        let output = std::process::Command::new("/usr/bin/osascript")
            .args(["-e", "on run argv", "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges", "-e", "end run", script, prompt])
            .output().context("Could not request administrator permission")?;
        if output.status.success() {
            return Ok(Admin::Done);
        }
        let error = String::from_utf8_lossy(&output.stderr);
        if error.contains("(-128)") {
            return Ok(Admin::Cancelled);
        }
        bail!(
            "macOS could not change the sleep settings: {}",
            error.trim().chars().take(512).collect::<String>()
        )
    }
}

#[cfg(target_os = "macos")]
pub(super) fn run(engine: SharedEngine, action: Action) -> Result<bool> {
    use std::sync::atomic::{AtomicBool, Ordering};
    static BUSY: AtomicBool = AtomicBool::new(false);
    ensure!(
        BUSY.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok(),
        "Another Keep Awake change is already in progress"
    );
    struct BusyGuard;
    impl Drop for BusyGuard {
        fn drop(&mut self) {
            BUSY.store(false, Ordering::Release);
        }
    }
    let _guard = BusyGuard;
    Ok(transition(&mut EngineJournal(engine), &mut MacBackend, action)? == Admin::Done)
}

#[cfg(target_os = "macos")]
pub(super) fn verify() -> Result<bool> {
    let power = MacBackend.read_power()?;
    Ok(power.sleep_disabled && power.charger_sleep == 0)
}

#[cfg(target_os = "macos")]
pub(super) fn status(engine: &SharedEngine) -> Result<String> {
    let engine = super::try_state(engine)?;
    let document = engine.store.local_document(DOCUMENT)?;
    Ok(stage(document.as_ref())?.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Default)]
    struct FakeJournal {
        value: Option<Value>,
        writes: Vec<Value>,
        fail: bool,
        fail_at: Option<usize>,
    }
    impl Journal for FakeJournal {
        fn load(&mut self) -> Result<Option<Value>> {
            Ok(self.value.clone())
        }
        fn save(&mut self, value: &Value) -> Result<()> {
            ensure!(
                !self.fail && self.fail_at != Some(self.writes.len()),
                "fixture journal error"
            );
            self.value = Some(value.clone());
            self.writes.push(value.clone());
            Ok(())
        }
    }
    struct FakeBackend {
        power: Power,
        original: Power,
        result: Result<Admin>,
        scripts: Vec<String>,
        apply_effect: bool,
    }
    impl Backend for FakeBackend {
        fn read_power(&mut self) -> Result<Power> {
            Ok(self.power)
        }
        fn authorize(&mut self, script: &str, enabling: bool) -> Result<Admin> {
            self.scripts.push(script.into());
            let result = std::mem::replace(&mut self.result, Ok(Admin::Done));
            if self.apply_effect && matches!(&result, Ok(Admin::Done)) {
                self.power = if enabling {
                    Power {
                        sleep_disabled: true,
                        charger_sleep: 0,
                    }
                } else {
                    self.original
                };
            }
            result
        }
    }
    fn fake() -> FakeBackend {
        let power = Power {
            sleep_disabled: false,
            charger_sleep: 12,
        };
        FakeBackend {
            power,
            original: power,
            result: Ok(Admin::Done),
            scripts: vec![],
            apply_effect: true,
        }
    }
    #[test]
    fn parsing_checks_power_values_and_script_is_fixed() {
        let p = Power::parse(
            "System-wide power settings:\n SleepDisabled 1\n",
            "Battery Power:\n sleep 4\nAC Power:\n sleep 12 (sleep prevented by x)\n",
        )
        .unwrap();
        assert_eq!(
            p,
            Power {
                sleep_disabled: true,
                charger_sleep: 12
            }
        );
        assert!(Power::parse("SleepDisabled garbage", "AC Power:\n sleep 12\n").is_err());
        assert!(Power::parse("", "AC Power:\n sleep 100001\n").is_err());
        assert!(Power::parse("", "Battery Power:\n sleep 3\n").is_err());
        assert!(p.apply_script().contains("/usr/bin/pmset -c sleep 12"));
        assert!(p.restore_script().contains("disablesleep 1"));
    }
    #[test]
    fn opt_in_records_and_restores_the_exact_prior_values() {
        let (mut journal, mut backend) = (FakeJournal::default(), fake());
        assert_eq!(
            transition(&mut journal, &mut backend, Action::Enable).unwrap(),
            Admin::Done
        );
        assert_eq!(journal.writes[0]["stage"], "prepared");
        assert_eq!(journal.writes[1]["stage"], "enabled");
        assert!(backend.scripts[0].contains("disablesleep 1"));
        assert_eq!(
            transition(&mut journal, &mut backend, Action::Disable).unwrap(),
            Admin::Done
        );
        assert!(backend.scripts[1].contains("-c sleep 12"));
        assert!(backend.scripts[1].contains("disablesleep 0"));
        assert_eq!(stage(journal.value.as_ref()).unwrap(), "off");
    }
    #[test]
    fn cancellation_and_uncertain_failures_preserve_the_right_recovery_state() {
        let (mut journal, mut backend) = (FakeJournal::default(), fake());
        backend.result = Ok(Admin::Cancelled);
        assert_eq!(
            transition(&mut journal, &mut backend, Action::Enable).unwrap(),
            Admin::Cancelled
        );
        assert_eq!(stage(journal.value.as_ref()).unwrap(), "off");
        backend.result = Err(anyhow::anyhow!("unknown outcome"));
        assert!(transition(&mut journal, &mut backend, Action::Enable).is_err());
        assert_eq!(stage(journal.value.as_ref()).unwrap(), "prepared");
        assert!(transition(&mut journal, &mut backend, Action::Enable).is_err());
        backend.result = Ok(Admin::Cancelled);
        assert_eq!(
            transition(&mut journal, &mut backend, Action::Disable).unwrap(),
            Admin::Cancelled
        );
        assert_eq!(stage(journal.value.as_ref()).unwrap(), "prepared");
        assert_eq!(
            transition(&mut journal, &mut backend, Action::Disable).unwrap(),
            Admin::Done
        );
        assert_eq!(stage(journal.value.as_ref()).unwrap(), "off");
    }
    #[test]
    fn failed_journal_never_runs_the_administrator_command() {
        let mut journal = FakeJournal {
            fail: true,
            ..Default::default()
        };
        let mut backend = fake();
        assert!(transition(&mut journal, &mut backend, Action::Enable).is_err());
        assert!(backend.scripts.is_empty());
    }
    #[test]
    fn unconfirmed_os_changes_keep_the_restore_journal() {
        let (mut journal, mut backend) = (FakeJournal::default(), fake());
        backend.apply_effect = false;
        assert!(transition(&mut journal, &mut backend, Action::Enable).is_err());
        assert_eq!(stage(journal.value.as_ref()).unwrap(), "prepared");
        assert!(transition(&mut journal, &mut backend, Action::Disable).is_ok());
        assert_eq!(stage(journal.value.as_ref()).unwrap(), "off");
        let (mut journal, mut backend) = (FakeJournal::default(), fake());
        transition(&mut journal, &mut backend, Action::Enable).unwrap();
        backend.apply_effect = false;
        assert!(transition(&mut journal, &mut backend, Action::Disable).is_err());
        assert_eq!(stage(journal.value.as_ref()).unwrap(), "enabled");
    }
    #[test]
    fn failed_final_save_retains_the_original_values_for_recovery() {
        let mut journal = FakeJournal {
            fail_at: Some(1),
            ..Default::default()
        };
        let mut backend = fake();
        assert!(transition(&mut journal, &mut backend, Action::Enable).is_err());
        assert!(backend.power.sleep_disabled);
        assert_eq!(stage(journal.value.as_ref()).unwrap(), "prepared");
        journal.fail_at = None;
        transition(&mut journal, &mut backend, Action::Disable).unwrap();
        assert_eq!(backend.power, backend.original);
        assert_eq!(stage(journal.value.as_ref()).unwrap(), "off");
    }
    #[test]
    fn reapply_keeps_the_original_restore_point() {
        let (mut journal, mut backend) = (FakeJournal::default(), fake());
        transition(&mut journal, &mut backend, Action::Enable).unwrap();
        backend.power = Power {
            sleep_disabled: false,
            charger_sleep: 45,
        };
        transition(&mut journal, &mut backend, Action::Reapply).unwrap();
        assert!(backend.power.sleep_disabled);
        assert_eq!(
            journal.value.as_ref().unwrap()["original"]["chargerSleep"],
            12
        );
        transition(&mut journal, &mut backend, Action::Disable).unwrap();
        assert_eq!(backend.power.charger_sleep, 12);
    }
    #[test]
    fn restore_journal_survives_a_store_reopen() {
        use coincide_core::{api::Engine, store::Store};
        use std::sync::{Arc, Mutex};
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("state.sqlite");
        let engine = Arc::new(Mutex::new(Engine::new(Store::open(&path).unwrap())));
        let mut journal = EngineJournal(engine.clone());
        let mut backend = fake();
        backend.result = Err(anyhow::anyhow!("interrupted"));
        assert!(transition(&mut journal, &mut backend, Action::Enable).is_err());
        // Simulate a command that applied even though its acknowledgement was lost.
        backend.power = Power {
            sleep_disabled: true,
            charger_sleep: 0,
        };
        drop(journal);
        drop(engine);
        let reopened = Arc::new(Mutex::new(Engine::new(Store::open(&path).unwrap())));
        let mut journal = EngineJournal(reopened);
        assert_eq!(stage(journal.load().unwrap().as_ref()).unwrap(), "prepared");
        transition(&mut journal, &mut backend, Action::Disable).unwrap();
        assert_eq!(stage(journal.load().unwrap().as_ref()).unwrap(), "off");
    }
}
