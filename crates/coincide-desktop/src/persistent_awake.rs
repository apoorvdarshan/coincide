//! Explicit macOS 24/7 sleep setting. Merely opening Settings or starting the
//! app never changes system power. The restore journal is written before the
//! user-authorized command, so an interrupted operation can still be undone.
use anyhow::{Context, Result, bail, ensure};
use coincide_awake_helper::Preferences;
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
    fn apply_script(self, sleep_disabled: bool) -> String {
        // Only fixed commands and validated integers enter this shell script.
        format!(
            "{{ /usr/bin/pmset -c sleep 0 && /usr/bin/pmset -a disablesleep {}; }} || {{ {}; exit 1; }}",
            u8::from(sleep_disabled),
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
    SetDisplayOff(bool),
    SetKeepDisplaysOff(bool),
    SetMute(bool),
    SetSleepOnBattery(bool),
    RegisterLidHelper,
    RestoreAudio,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Service {
    Lid,
    Battery,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ServiceStatus {
    NotRegistered,
    Enabled,
    NeedsApproval,
    Missing,
}

trait Backend {
    fn read_power(&mut self) -> Result<Power>;
    fn authorize(&mut self, script: &str, enabling: bool) -> Result<Admin>;
    fn on_battery(&mut self) -> Option<bool> {
        Some(false)
    }
    fn service_status(&mut self, _: Service) -> Result<ServiceStatus> {
        Ok(ServiceStatus::Enabled)
    }
    fn register_service(&mut self, _: Service) -> Result<ServiceStatus> {
        Ok(ServiceStatus::Enabled)
    }
    fn unregister_service(&mut self, _: Service) -> Result<()> {
        Ok(())
    }
    fn restore_audio(&mut self) -> Result<bool> {
        Ok(true)
    }
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

fn preferences(value: Option<&Value>) -> Result<Preferences> {
    Preferences::from_document(value)
}

fn set_options(document: &mut Value, changes: &[(&str, bool)]) -> Result<()> {
    ensure!(document.is_object(), "Invalid Keep Awake document");
    if document.get("options").is_none() {
        document["options"] = json!({});
    }
    ensure!(
        document["options"].is_object(),
        "Invalid Keep Awake options"
    );
    for (key, value) in changes {
        document["options"][*key] = json!(value);
    }
    Ok(())
}

fn replace_stage(previous: Option<&Value>, next: &str, original: Option<Power>) -> Result<Value> {
    let mut document = previous.cloned().unwrap_or_else(|| json!({"version":1}));
    ensure!(document.is_object(), "Invalid Keep Awake document");
    document["version"] = json!(1);
    document["stage"] = json!(next);
    if let Some(power) = original {
        document["original"] = power.value();
    } else if let Some(object) = document.as_object_mut() {
        object.remove("original");
    }
    Ok(document)
}

fn target_disabled(backend: &mut impl Backend, preferences: Preferences) -> Result<bool> {
    if preferences.sleep_on_battery || preferences.battery_approval_pending {
        Ok(!backend
            .on_battery()
            .context("The current power source is unavailable")?)
    } else {
        Ok(true)
    }
}
fn transition(
    journal: &mut impl Journal,
    backend: &mut impl Backend,
    action: Action,
) -> Result<Admin> {
    let previous = journal.load()?;
    let current = stage(previous.as_ref())?;
    let options = preferences(previous.as_ref())?;
    ensure!(
        matches!(action, Action::Enable | Action::Disable | Action::Reapply),
        "Invalid power transition"
    );
    if matches!(action, Action::Enable | Action::Reapply) {
        let wanted = target_disabled(backend, options)?;
        if matches!(action, Action::Reapply) {
            ensure!(
                current == "enabled",
                "Keep Awake must be on before it can be reapplied"
            );
            let before = backend.read_power()?;
            match backend.authorize(&before.apply_script(wanted), true)? {
                Admin::Done => {
                    let applied = backend.read_power()?;
                    ensure!(
                        applied.sleep_disabled == wanted && applied.charger_sleep == 0,
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
        journal.save(&replace_stage(previous.as_ref(), "prepared", Some(power))?)?;
        match backend.authorize(&power.apply_script(wanted), true) {
            Ok(Admin::Done) => {
                let applied = backend.read_power()?;
                ensure!(
                    applied.sleep_disabled == wanted && applied.charger_sleep == 0,
                    "macOS did not confirm the requested sleep settings; restore the saved settings"
                );
                journal.save(&replace_stage(previous.as_ref(), "enabled", Some(power))?)?;
                Ok(Admin::Done)
            }
            Ok(Admin::Cancelled) => {
                // No shell command runs when the administrator prompt is cancelled.
                journal.save(&replace_stage(previous.as_ref(), "off", None)?)?;
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
                let mut off = replace_stage(previous.as_ref(), "off", None)?;
                set_options(
                    &mut off,
                    &[
                        ("batteryApprovalPending", false),
                        ("batteryDisablePending", false),
                    ],
                )?;
                journal.save(&off)?;
                Ok(Admin::Done)
            }
            Admin::Cancelled => Ok(Admin::Cancelled),
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Outcome {
    Done,
    Cancelled,
    NeedsApproval,
    AudioPending,
}

fn active_or_pending(status: ServiceStatus) -> Result<Outcome> {
    match status {
        ServiceStatus::Enabled => Ok(Outcome::Done),
        ServiceStatus::NeedsApproval => Ok(Outcome::NeedsApproval),
        ServiceStatus::NotRegistered | ServiceStatus::Missing => {
            bail!("The Keep Awake background helper is unavailable")
        }
    }
}

fn orchestrate(
    journal: &mut impl Journal,
    backend: &mut impl Backend,
    action: Action,
) -> Result<Outcome> {
    let previous = journal.load()?;
    let current = stage(previous.as_ref())?;
    match action {
        Action::Enable => {
            ensure!(
                backend.service_status(Service::Lid)? != ServiceStatus::Missing,
                "This app build does not include the lid helper"
            );
            if transition(journal, backend, Action::Enable)? == Admin::Cancelled {
                return Ok(Outcome::Cancelled);
            }
            let mut result = active_or_pending(
                backend
                    .register_service(Service::Lid)
                    .context("24/7 is on, but its display helper could not be started")?,
            )
            .context("24/7 is on, but its display helper could not be started")?;
            let saved = journal.load()?;
            let options = preferences(saved.as_ref())?;
            if options.sleep_on_battery || options.battery_approval_pending {
                let mut document = saved.context("Keep Awake settings disappeared")?;
                set_options(
                    &mut document,
                    &[
                        ("batteryApprovalPending", true),
                        ("batteryDisablePending", false),
                    ],
                )?;
                journal.save(&document)?;
                match active_or_pending(
                    backend
                        .register_service(Service::Battery)
                        .context("24/7 is on, but its battery helper could not be started")?,
                )? {
                    Outcome::Done => {
                        set_options(
                            &mut document,
                            &[("sleepOnBattery", true), ("batteryApprovalPending", false)],
                        )?;
                        journal.save(&document)?;
                    }
                    Outcome::NeedsApproval => result = Outcome::NeedsApproval,
                    _ => unreachable!(),
                }
            }
            Ok(result)
        }
        Action::Disable => {
            ensure!(
                current != "off",
                "There are no Coincide sleep settings to restore"
            );
            // The privileged battery helper must be fully stopped before pmset
            // restores the user's original values, or it could race the restore.
            let options = preferences(previous.as_ref())?;
            ensure!(
                !(options.sleep_on_battery
                    || options.battery_approval_pending
                    || options.battery_disable_pending)
                    || backend.service_status(Service::Battery)? != ServiceStatus::Missing,
                "The battery helper is missing, so Coincide cannot confirm it has stopped. Reinstall the current app before restoring sleep settings."
            );
            backend.unregister_service(Service::Battery)?;
            backend.unregister_service(Service::Lid)?;
            let audio_restored = backend.restore_audio().unwrap_or(false);
            match transition(journal, backend, Action::Disable)? {
                Admin::Cancelled => Ok(Outcome::Cancelled),
                Admin::Done if !audio_restored => Ok(Outcome::AudioPending),
                Admin::Done => Ok(Outcome::Done),
            }
        }
        Action::Reapply => {
            ensure!(current == "enabled", "24/7 Keep Awake is not on");
            match transition(journal, backend, Action::Reapply)? {
                Admin::Done => Ok(Outcome::Done),
                Admin::Cancelled => Ok(Outcome::Cancelled),
            }
        }
        Action::SetDisplayOff(value)
        | Action::SetKeepDisplaysOff(value)
        | Action::SetMute(value) => {
            ensure!(
                current != "prepared",
                "Restore the interrupted power change first"
            );
            let mut document = previous.unwrap_or_else(|| json!({"version":1,"stage":"off"}));
            let key = match action {
                Action::SetDisplayOff(_) => "displayOffOnClose",
                Action::SetKeepDisplaysOff(_) => "keepDisplaysOff",
                Action::SetMute(_) => "muteWhileClosed",
                _ => unreachable!(),
            };
            set_options(&mut document, &[(key, value)])?;
            journal.save(&document)?;
            Ok(Outcome::Done)
        }
        Action::SetSleepOnBattery(true) => {
            ensure!(current == "enabled", "Turn on 24/7 Keep Awake first");
            let mut document = previous.context("Keep Awake settings disappeared")?;
            // Durable intent precedes registering a privileged process. If the
            // app exits or macOS asks for approval, the UI can finish or cancel.
            set_options(
                &mut document,
                &[
                    ("batteryApprovalPending", true),
                    ("batteryDisablePending", false),
                ],
            )?;
            journal.save(&document)?;
            match active_or_pending(backend.register_service(Service::Battery)?)? {
                Outcome::Done => {
                    set_options(
                        &mut document,
                        &[("sleepOnBattery", true), ("batteryApprovalPending", false)],
                    )?;
                    journal.save(&document)?;
                    Ok(Outcome::Done)
                }
                Outcome::NeedsApproval => Ok(Outcome::NeedsApproval),
                _ => unreachable!(),
            }
        }
        Action::SetSleepOnBattery(false) => {
            ensure!(current == "enabled", "Turn on 24/7 Keep Awake first");
            let mut document = previous.context("Keep Awake settings disappeared")?;
            let options = preferences(Some(&document))?;
            ensure!(
                !(options.sleep_on_battery
                    || options.battery_approval_pending
                    || options.battery_disable_pending)
                    || backend.service_status(Service::Battery)? != ServiceStatus::Missing,
                "The battery helper is missing, so Coincide cannot confirm it has stopped. Reinstall the current app before changing this policy."
            );
            set_options(
                &mut document,
                &[
                    ("batteryDisablePending", true),
                    ("batteryApprovalPending", false),
                ],
            )?;
            journal.save(&document)?;
            backend.unregister_service(Service::Battery)?;
            let power = backend.read_power()?;
            if !power.sleep_disabled || power.charger_sleep != 0 {
                match backend.authorize(&power.apply_script(true), true)? {
                    Admin::Cancelled => return Ok(Outcome::Cancelled),
                    Admin::Done => {
                        let applied = backend.read_power()?;
                        ensure!(
                            applied.sleep_disabled && applied.charger_sleep == 0,
                            "macOS did not confirm the updated sleep policy"
                        );
                    }
                }
            }
            set_options(
                &mut document,
                &[("sleepOnBattery", false), ("batteryDisablePending", false)],
            )?;
            journal.save(&document)?;
            Ok(Outcome::Done)
        }
        Action::RegisterLidHelper => {
            ensure!(current == "enabled", "Turn on 24/7 Keep Awake first");
            active_or_pending(backend.register_service(Service::Lid)?)
        }
        Action::RestoreAudio => {
            if backend.restore_audio()? {
                Ok(Outcome::Done)
            } else {
                Ok(Outcome::AudioPending)
            }
        }
    }
}

fn sync_battery_approval(journal: &mut impl Journal, backend: &mut impl Backend) -> Result<()> {
    let Some(mut document) = journal.load()? else {
        return Ok(());
    };
    let options = preferences(Some(&document))?;
    if options.enabled
        && options.battery_approval_pending
        && backend.service_status(Service::Battery)? == ServiceStatus::Enabled
    {
        set_options(
            &mut document,
            &[("sleepOnBattery", true), ("batteryApprovalPending", false)],
        )?;
        journal.save(&document)?;
    }
    Ok(())
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
mod mac_service {
    use super::{Result, Service, ServiceStatus, bail};
    use std::ffi::{CStr, c_char, c_int};

    unsafe extern "C" {
        fn coincide_awake_service_status(kind: c_int) -> c_int;
        fn coincide_awake_service_register(
            kind: c_int,
            error: *mut c_char,
            capacity: usize,
        ) -> c_int;
        fn coincide_awake_service_unregister(
            kind: c_int,
            error: *mut c_char,
            capacity: usize,
        ) -> c_int;
        fn coincide_awake_open_login_items();
    }
    fn kind(service: Service) -> c_int {
        match service {
            Service::Lid => 0,
            Service::Battery => 1,
        }
    }
    fn status(value: c_int) -> Result<ServiceStatus> {
        match value {
            0 => Ok(ServiceStatus::NotRegistered),
            1 => Ok(ServiceStatus::Enabled),
            2 => Ok(ServiceStatus::NeedsApproval),
            3 => Ok(ServiceStatus::Missing),
            _ => bail!("macOS Service Management is unavailable"),
        }
    }
    fn error(buffer: &[c_char]) -> String {
        unsafe { CStr::from_ptr(buffer.as_ptr()) }
            .to_string_lossy()
            .chars()
            .take(512)
            .collect()
    }
    pub(super) fn read(service: Service) -> Result<ServiceStatus> {
        status(unsafe { coincide_awake_service_status(kind(service)) })
    }
    pub(super) fn register(service: Service) -> Result<ServiceStatus> {
        let mut buffer = [0 as c_char; 1024];
        let value = unsafe {
            coincide_awake_service_register(kind(service), buffer.as_mut_ptr(), buffer.len())
        };
        if value < 0 {
            bail!("{}", error(&buffer));
        }
        status(value)
    }
    pub(super) fn unregister(service: Service) -> Result<()> {
        let mut buffer = [0 as c_char; 1024];
        let value = unsafe {
            coincide_awake_service_unregister(kind(service), buffer.as_mut_ptr(), buffer.len())
        };
        if value < 0 {
            bail!("{}", error(&buffer));
        }
        Ok(())
    }
    pub(super) fn open_login_items() {
        unsafe { coincide_awake_open_login_items() }
    }
}

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
    fn on_battery(&mut self) -> Option<bool> {
        coincide_awake_helper::on_battery()
    }
    fn service_status(&mut self, service: Service) -> Result<ServiceStatus> {
        mac_service::read(service)
    }
    fn register_service(&mut self, service: Service) -> Result<ServiceStatus> {
        mac_service::register(service)
    }
    fn unregister_service(&mut self, service: Service) -> Result<()> {
        mac_service::unregister(service)
    }
    fn restore_audio(&mut self) -> Result<bool> {
        use coincide_awake_helper::{AudioJournal, journal::FileJournal};
        use std::{
            process::{Command, Stdio},
            time::{Duration, Instant},
        };
        let directory = coincide_core::control::data_directory()?;
        let mut journal = FileJournal::new(&directory)?;
        if journal.load()?.is_empty() {
            return Ok(true);
        }
        let executable = std::env::current_exe()?
            .parent()
            .context("Missing app executable directory")?
            .join("coincide-awake-helper");
        let metadata = std::fs::symlink_metadata(&executable)?;
        ensure!(
            metadata.is_file() && !metadata.file_type().is_symlink(),
            "Keep Awake audio helper is unavailable"
        );
        let mut child = Command::new(executable)
            .arg("--restore-audio")
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if child.try_wait()?.is_some() {
                break;
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                bail!("Audio restoration timed out; its recovery journal is retained");
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        Ok(journal.load()?.is_empty())
    }
}

#[cfg(target_os = "macos")]
static BUSY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(target_os = "macos")]
struct BusyGuard;

#[cfg(target_os = "macos")]
impl BusyGuard {
    fn acquire() -> Result<Self> {
        use std::sync::atomic::Ordering;
        ensure!(
            BUSY.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_ok(),
            "Another Keep Awake check or change is already in progress"
        );
        Ok(Self)
    }
}

#[cfg(target_os = "macos")]
impl Drop for BusyGuard {
    fn drop(&mut self) {
        BUSY.store(false, std::sync::atomic::Ordering::Release);
    }
}

#[cfg(target_os = "macos")]
pub(super) fn run(engine: SharedEngine, action: Action) -> Result<Outcome> {
    let _guard = BusyGuard::acquire()?;
    orchestrate(&mut EngineJournal(engine), &mut MacBackend, action)
}

#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug)]
pub(super) struct Health {
    pub power_matches: bool,
    pub lid: ServiceStatus,
    pub battery: ServiceStatus,
}

#[cfg(target_os = "macos")]
pub(super) fn verify(engine: SharedEngine) -> Result<Health> {
    // Approval completion can update the journal, so it must not race a user
    // turning the battery policy off or restoring the original power state.
    let _guard = BusyGuard::acquire()?;
    let mut journal = EngineJournal(engine);
    let mut backend = MacBackend;
    sync_battery_approval(&mut journal, &mut backend)?;
    let document = journal.load()?;
    let options = preferences(document.as_ref())?;
    let wanted = target_disabled(&mut backend, options)?;
    let power = backend.read_power()?;
    Ok(Health {
        power_matches: power.sleep_disabled == wanted && power.charger_sleep == 0,
        lid: backend.service_status(Service::Lid)?,
        battery: backend.service_status(Service::Battery)?,
    })
}

#[cfg(target_os = "macos")]
pub(super) fn status(engine: &SharedEngine) -> Result<(String, Preferences, bool)> {
    use coincide_awake_helper::{AudioJournal, journal::FileJournal};
    let engine = super::try_state(engine)?;
    let document = engine.store.local_document(DOCUMENT)?;
    let directory = coincide_core::control::data_directory()?;
    let audio_pending = !FileJournal::new(&directory)?.load()?.is_empty();
    Ok((
        stage(document.as_ref())?.to_owned(),
        preferences(document.as_ref())?,
        audio_pending,
    ))
}

#[cfg(target_os = "macos")]
pub(super) fn open_login_items() {
    mac_service::open_login_items();
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(target_os = "macos")]
    #[test]
    fn approval_check_and_user_changes_cannot_run_at_the_same_time() {
        let guard = BusyGuard::acquire().unwrap();
        assert!(BusyGuard::acquire().is_err());
        drop(guard);
        assert!(BusyGuard::acquire().is_ok());
    }

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
        assert!(p.apply_script(true).contains("/usr/bin/pmset -c sleep 12"));
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

    struct Services {
        power: Power,
        original: Power,
        on_battery: Option<bool>,
        lid: ServiceStatus,
        battery: ServiceStatus,
        battery_registration: ServiceStatus,
        fail_stop_battery: bool,
        cancel_admin: bool,
        audio_restored: bool,
        calls: Vec<&'static str>,
    }
    impl Services {
        fn new() -> Self {
            let power = Power {
                sleep_disabled: false,
                charger_sleep: 12,
            };
            Self {
                power,
                original: power,
                on_battery: Some(false),
                lid: ServiceStatus::NotRegistered,
                battery: ServiceStatus::NotRegistered,
                battery_registration: ServiceStatus::Enabled,
                fail_stop_battery: false,
                cancel_admin: false,
                audio_restored: true,
                calls: vec![],
            }
        }
    }
    impl Backend for Services {
        fn read_power(&mut self) -> Result<Power> {
            Ok(self.power)
        }
        fn authorize(&mut self, script: &str, enabling: bool) -> Result<Admin> {
            self.calls.push("authorize");
            if self.cancel_admin {
                return Ok(Admin::Cancelled);
            }
            self.power = if enabling {
                let value = script
                    .split("disablesleep ")
                    .nth(1)
                    .and_then(|s| s.chars().next())
                    .context("missing fixture value")?;
                Power {
                    sleep_disabled: value == '1',
                    charger_sleep: 0,
                }
            } else {
                self.original
            };
            Ok(Admin::Done)
        }
        fn on_battery(&mut self) -> Option<bool> {
            self.on_battery
        }
        fn service_status(&mut self, service: Service) -> Result<ServiceStatus> {
            Ok(match service {
                Service::Lid => self.lid,
                Service::Battery => self.battery,
            })
        }
        fn register_service(&mut self, service: Service) -> Result<ServiceStatus> {
            Ok(match service {
                Service::Lid => {
                    self.calls.push("register lid");
                    self.lid = ServiceStatus::Enabled;
                    self.lid
                }
                Service::Battery => {
                    self.calls.push("register battery");
                    self.battery = self.battery_registration;
                    self.battery
                }
            })
        }
        fn unregister_service(&mut self, service: Service) -> Result<()> {
            match service {
                Service::Battery => {
                    self.calls.push("stop battery");
                    ensure!(!self.fail_stop_battery, "fixture stop failed");
                    self.battery = ServiceStatus::NotRegistered;
                }
                Service::Lid => {
                    self.calls.push("stop lid");
                    self.lid = ServiceStatus::NotRegistered;
                }
            }
            Ok(())
        }
        fn restore_audio(&mut self) -> Result<bool> {
            self.calls.push("restore audio");
            Ok(self.audio_restored)
        }
    }

    #[test]
    fn background_services_are_opt_in_and_battery_approval_is_recoverable() {
        let (mut journal, mut backend) = (FakeJournal::default(), Services::new());
        orchestrate(&mut journal, &mut backend, Action::SetMute(true)).unwrap();
        assert!(
            backend.calls.is_empty(),
            "preferences alone cannot change system state"
        );
        assert_eq!(
            orchestrate(&mut journal, &mut backend, Action::Enable).unwrap(),
            Outcome::Done
        );
        assert_eq!(backend.calls, ["authorize", "register lid"]);
        assert!(
            preferences(journal.value.as_ref())
                .unwrap()
                .mute_while_closed
        );
        backend.battery_registration = ServiceStatus::NeedsApproval;
        assert_eq!(
            orchestrate(&mut journal, &mut backend, Action::SetSleepOnBattery(true)).unwrap(),
            Outcome::NeedsApproval
        );
        let pending = preferences(journal.value.as_ref()).unwrap();
        assert!(pending.battery_approval_pending && !pending.sleep_on_battery);
        backend.battery = ServiceStatus::Enabled;
        sync_battery_approval(&mut journal, &mut backend).unwrap();
        let approved = preferences(journal.value.as_ref()).unwrap();
        assert!(approved.sleep_on_battery && !approved.battery_approval_pending);
        backend.power.sleep_disabled = false; // The fake daemon saw battery power.
        backend.calls.clear();
        assert_eq!(
            orchestrate(&mut journal, &mut backend, Action::Disable).unwrap(),
            Outcome::Done
        );
        assert_eq!(
            backend.calls,
            ["stop battery", "stop lid", "restore audio", "authorize"]
        );
        assert_eq!(backend.power, backend.original);
        assert_eq!(stage(journal.value.as_ref()).unwrap(), "off");
    }

    #[test]
    fn failure_to_stop_root_helper_never_restores_power_under_a_live_daemon() {
        let (mut journal, mut backend) = (FakeJournal::default(), Services::new());
        orchestrate(&mut journal, &mut backend, Action::Enable).unwrap();
        backend.calls.clear();
        backend.fail_stop_battery = true;
        assert!(orchestrate(&mut journal, &mut backend, Action::Disable).is_err());
        assert_eq!(backend.calls, ["stop battery"]);
        assert_eq!(stage(journal.value.as_ref()).unwrap(), "enabled");
        assert!(backend.power.sleep_disabled);
    }

    #[test]
    fn missing_registered_battery_helper_cannot_race_a_power_restore() {
        let (mut journal, mut backend) = (FakeJournal::default(), Services::new());
        orchestrate(&mut journal, &mut backend, Action::Enable).unwrap();
        orchestrate(&mut journal, &mut backend, Action::SetSleepOnBattery(true)).unwrap();
        backend.battery = ServiceStatus::Missing;
        backend.calls.clear();
        assert!(orchestrate(&mut journal, &mut backend, Action::Disable).is_err());
        assert!(orchestrate(&mut journal, &mut backend, Action::SetSleepOnBattery(false)).is_err());
        assert!(backend.calls.is_empty());
        assert_eq!(stage(journal.value.as_ref()).unwrap(), "enabled");
        assert!(
            preferences(journal.value.as_ref())
                .unwrap()
                .sleep_on_battery
        );
    }

    #[test]
    fn interrupted_battery_disable_preserves_intent_and_can_be_finished() {
        let (mut journal, mut backend) = (FakeJournal::default(), Services::new());
        orchestrate(&mut journal, &mut backend, Action::Enable).unwrap();
        orchestrate(&mut journal, &mut backend, Action::SetSleepOnBattery(true)).unwrap();
        backend.power.sleep_disabled = false;
        backend.cancel_admin = true;
        assert_eq!(
            orchestrate(&mut journal, &mut backend, Action::SetSleepOnBattery(false)).unwrap(),
            Outcome::Cancelled
        );
        assert!(
            preferences(journal.value.as_ref())
                .unwrap()
                .battery_disable_pending
        );
        assert_eq!(backend.battery, ServiceStatus::NotRegistered);
        backend.cancel_admin = false;
        assert_eq!(
            orchestrate(&mut journal, &mut backend, Action::SetSleepOnBattery(false)).unwrap(),
            Outcome::Done
        );
        let options = preferences(journal.value.as_ref()).unwrap();
        assert!(!options.sleep_on_battery && !options.battery_disable_pending);
        assert!(backend.power.sleep_disabled);
    }

    #[test]
    fn unavailable_audio_never_blocks_sleep_restore_or_discards_the_journal() {
        let (mut journal, mut backend) = (FakeJournal::default(), Services::new());
        orchestrate(&mut journal, &mut backend, Action::Enable).unwrap();
        backend.audio_restored = false;
        assert_eq!(
            orchestrate(&mut journal, &mut backend, Action::Disable).unwrap(),
            Outcome::AudioPending
        );
        assert_eq!(backend.power, backend.original);
        assert_eq!(stage(journal.value.as_ref()).unwrap(), "off");
        assert_eq!(
            orchestrate(&mut journal, &mut backend, Action::RestoreAudio).unwrap(),
            Outcome::AudioPending
        );
        backend.audio_restored = true;
        assert_eq!(
            orchestrate(&mut journal, &mut backend, Action::RestoreAudio).unwrap(),
            Outcome::Done
        );
    }
}
