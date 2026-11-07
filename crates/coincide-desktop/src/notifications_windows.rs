//! Worker-only WinRT toast delivery for the unpackaged native application.
//! Construction is inert. The explicit permission action creates a new Start
//! menu shortcut with the app's AUMID; existing unrelated shortcuts are refused.
//! OS API acknowledgement does not establish visible banner or click acceptance.
use super::{Backend, Payload, Permission};
use crate::notifications::windows_policy::{
    GROUP, MAX_HISTORY, owned_history_id, shell_link_target, toast_xml,
};
use anyhow::{Context, Result, bail, ensure};
use coincide_core::{native_file, platform_host::notifications::Delivery};
use std::{
    fs,
    path::{Path, PathBuf},
};
use uuid::Uuid;
use windows::{
    Data::Xml::Dom::XmlDocument,
    UI::Notifications::{NotificationSetting, ToastNotification, ToastNotificationManager},
    Win32::{
        Foundation::PROPERTYKEY,
        Storage::FileSystem::MoveFileW,
        System::{
            Com::{
                CLSCTX_INPROC_SERVER, CoCreateInstance, CoTaskMemFree, IPersistFile, STGM_READ,
                StructuredStorage::{
                    PROPVARIANT, PROPVARIANT_0, PROPVARIANT_0_0, PROPVARIANT_0_0_0,
                },
            },
            Variant::VT_LPWSTR,
            WinRT::{RO_INIT_MULTITHREADED, RoInitialize, RoUninitialize},
        },
        UI::Shell::{
            FOLDERID_Programs, IShellLinkW, KF_FLAG_DEFAULT, PropertiesSystem::IPropertyStore,
            SHGetKnownFolderPath, SHStrDupW, ShellLink,
        },
    },
    core::{BSTR, GUID, HSTRING, Interface, PCWSTR},
};

const APP_ID: &str = "com.apoorvdarshan.coincide.rust";
const SHORTCUT: &str = "Coincide Rust.lnk";
// SDK PKEY_AppUserModel_ID; avoiding the unrelated EnhancedStorage feature.
const APP_ID_KEY: PROPERTYKEY = PROPERTYKEY {
    fmtid: GUID::from_u128(0x9f4c2855_9f79_4b39_a8d0_e1d42de1d5f3),
    pid: 5,
};

/// Each synchronous call initializes and balances its own worker apartment.
/// No COM object or apartment is transferred into GPUI or retained across calls.
struct Apartment;
impl Apartment {
    fn new() -> Result<Self> {
        unsafe { RoInitialize(RO_INIT_MULTITHREADED) }
            .map_err(|_| anyhow::anyhow!("Windows notification apartment unavailable"))?;
        Ok(Self)
    }
}
impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe { RoUninitialize() };
    }
}

pub(crate) struct NativeBackend;
fn wide(path: &Path) -> Result<Vec<u16>> {
    use std::os::windows::ffi::OsStrExt;
    let mut value: Vec<u16> = path.as_os_str().encode_wide().collect();
    ensure!(
        !value.contains(&0) && value.len() < 32767,
        "Invalid notification path"
    );
    value.push(0);
    Ok(value)
}
fn programs() -> Result<PathBuf> {
    // The OS known folder, not an environment path or a control-provided path.
    let value = unsafe { SHGetKnownFolderPath(&FOLDERID_Programs, KF_FLAG_DEFAULT, None) }
        .map_err(|_| anyhow::anyhow!("Windows Start menu folder unavailable"))?;
    let result = unsafe { value.to_string() }.map(PathBuf::from);
    unsafe { CoTaskMemFree(Some(value.0.cast())) };
    let result = result.context("Invalid Windows Start menu folder")?;
    ensure!(
        result.is_absolute() && result.is_dir(),
        "Windows Start menu folder unavailable"
    );
    Ok(result)
}
fn executable() -> Result<PathBuf> {
    let path = std::env::current_exe()?.canonicalize()?;
    let _file = native_file::open_regular(&path, false)?;
    Ok(path)
}
fn shortcut_matches(path: &Path, exe: &Path, app_id: &str) -> Result<bool> {
    // Hold the exact regular source across the COM read, with no Resolve/search,
    // MSI repair, shell execution, icon retrieval or environment expansion.
    let file = native_file::open_regular(path, false)?;
    let identity = native_file::file_identity(&file)?;
    ensure!(
        file.metadata()?.len() <= 64 * 1024,
        "Notification shortcut exceeds limit"
    );
    let link: IShellLinkW = unsafe { CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER) }?;
    let persist: IPersistFile = link.cast()?;
    let path_wide = wide(path)?;
    unsafe { persist.Load(PCWSTR(path_wide.as_ptr()), STGM_READ) }?;
    let mut target = [0u16; 32768];
    let mut args = [0u16; 32768];
    unsafe {
        link.GetPath(&mut target, std::ptr::null_mut(), 4)?; // SLGP_RAWPATH
        link.GetArguments(&mut args)?;
    }
    let target_len = target
        .iter()
        .position(|c| *c == 0)
        .context("Invalid shortcut target")?;
    let target = PathBuf::from(String::from_utf16(&target[..target_len])?);
    let store: IPropertyStore = link.cast()?;
    let value = unsafe { store.GetValue(&APP_ID_KEY) }?;
    let stored = BSTR::try_from(&value)?.to_string();
    ensure!(
        native_file::path_identity(path)? == identity,
        "Notification shortcut changed"
    );
    // IShellLink may normalize a Win32 path while std canonicalize uses the
    // verbatim prefix. Compare canonical paths and actual file identities,
    // never reject a legitimate shortcut because of representation alone.
    let target = target.canonicalize()?;
    let target_file = native_file::open_regular(&target, false)?;
    let executable_file = native_file::open_regular(exe, false)?;
    let same_target = target.as_path() == exe
        && native_file::file_identity(&target_file)?
            == native_file::file_identity(&executable_file)?;
    Ok(args[0] == 0 && same_target && stored == app_id)
}
fn status(exe: &Path, shortcut: &Path, app_id: &str) -> Result<Permission> {
    match fs::symlink_metadata(shortcut) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Permission::NotDetermined);
        }
        Err(_) => bail!("Windows notification shortcut cannot be read"),
        Ok(_) => ensure!(
            shortcut_matches(shortcut, exe, app_id)?,
            "Existing Start menu shortcut does not belong to this application"
        ),
    }
    let notifier = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(app_id))
        .map_err(|_| anyhow::anyhow!("Windows notification service unavailable"))?;
    Ok(
        match notifier
            .Setting()
            .map_err(|_| anyhow::anyhow!("Windows notification permission unavailable"))?
        {
            NotificationSetting::Enabled => Permission::Authorized,
            NotificationSetting::DisabledForApplication
            | NotificationSetting::DisabledForUser
            | NotificationSetting::DisabledByGroupPolicy
            | NotificationSetting::DisabledByManifest => Permission::Denied,
            _ => Permission::Unknown,
        },
    )
}
fn register(exe: &Path, shortcut: &Path, app_id: &str) -> Result<()> {
    if fs::symlink_metadata(shortcut).is_ok() {
        ensure!(
            shortcut_matches(shortcut, exe, app_id)?,
            "Existing Start menu shortcut does not belong to this application"
        );
        return Ok(());
    }
    let parent = shortcut.parent().context("Start menu folder unavailable")?;
    let parent_identity = native_file::path_identity(parent)?;
    let temporary = parent.join(format!(".coincide-notification-{}.lnk", Uuid::new_v4()));
    // create_new refuses replacing another file; IPersistFile only writes this
    // owned placeholder. Failed setup removes only the same original file.
    // The shortcut keeps the Start menu folder's inherited ACL like any other
    // shortcut: an owner-only DACL would hide it from the system components
    // that resolve the AUMID registration.
    let placeholder = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    let identity = native_file::file_identity(&placeholder)?;
    drop(placeholder);
    let result = (|| -> Result<()> {
        let link: IShellLinkW = unsafe { CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER) }
            .context("Shell link unavailable")?;
        let target = exe.to_str().context("Invalid notification target")?;
        let target = wide(Path::new(&shell_link_target(target)?))?;
        unsafe { link.SetPath(PCWSTR(target.as_ptr())) }.context("Shortcut target rejected")?;
        let store: IPropertyStore = link.cast()?;
        let app_id_wide: Vec<_> = app_id.encode_utf16().chain(Some(0)).collect();
        let allocated = unsafe { SHStrDupW(PCWSTR(app_id_wide.as_ptr())) }?;
        // PROPVARIANT owns this CoTaskMem string and balances it on drop.
        let value = PROPVARIANT {
            Anonymous: PROPVARIANT_0 {
                Anonymous: std::mem::ManuallyDrop::new(PROPVARIANT_0_0 {
                    vt: VT_LPWSTR,
                    Anonymous: PROPVARIANT_0_0_0 { pwszVal: allocated },
                    ..Default::default()
                }),
            },
        };
        unsafe {
            store
                .SetValue(&APP_ID_KEY, &value)
                .context("Shortcut app identity rejected")?;
            store.Commit().context("Shortcut app identity rejected")?;
        }
        let persist: IPersistFile = link.cast()?;
        let temporary_wide = wide(&temporary)?;
        unsafe { persist.Save(PCWSTR(temporary_wide.as_ptr()), true) }
            .context("Shortcut save failed")?;
        ensure!(
            native_file::path_identity(&temporary)? == identity
                && native_file::path_identity(parent)? == parent_identity,
            "Notification shortcut source changed"
        );
        ensure!(
            shortcut_matches(&temporary, exe, app_id)
                .context("Notification shortcut verification failed")?,
            "Notification shortcut verification failed"
        );
        let destination = wide(shortcut)?;
        // MoveFileW fails if a destination appeared; never replaces an existing
        // shortcut, including one created after the original absence check.
        unsafe {
            MoveFileW(
                PCWSTR(temporary_wide.as_ptr()),
                PCWSTR(destination.as_ptr()),
            )
        }
        .context("Shortcut install failed")?;
        ensure!(
            native_file::path_identity(shortcut)? == identity
                && shortcut_matches(shortcut, exe, app_id)?,
            "Installed notification shortcut changed"
        );
        Ok(())
    })();
    if native_file::path_identity(&temporary).ok() == Some(identity) {
        let _ = fs::remove_file(&temporary);
    }
    // Step labels and OS error codes only; no paths or app identities.
    result.map_err(|error| {
        anyhow::anyhow!("Windows notification setup could not be verified: {error:#}")
    })
}
fn post(app_id: &str, payload: &Payload, suppress_popup: bool) -> Delivery {
    let prepared = (|| -> Result<_> {
        let xml = toast_xml(payload)?;
        let document = XmlDocument::new()?;
        document.LoadXml(&HSTRING::from(xml))?;
        let toast = ToastNotification::CreateToastNotification(&document)?;
        toast.SetGroup(&HSTRING::from(GROUP))?;
        toast.SetSuppressPopup(suppress_popup)?;
        // A fresh native receipt; clearing below validates the full launch ID,
        // group and actual history entry rather than trusting this short tag.
        toast.SetTag(&HSTRING::from(&Uuid::new_v4().simple().to_string()[..16]))?;
        let notifier = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(app_id))?;
        ensure!(
            notifier.Setting()? == NotificationSetting::Enabled,
            "Notifications disabled"
        );
        Ok((notifier, toast))
    })();
    let Ok((notifier, toast)) = prepared else {
        return Delivery::Unavailable;
    };
    match notifier.Show(&toast) {
        Ok(()) => Delivery::Accepted,
        // Once entered, an HRESULT alone is not proof the OS never accepted it.
        Err(_) => Delivery::Uncertain,
    }
}
fn clear(app_id: &str, thread: Uuid) -> Result<()> {
    let history = ToastNotificationManager::History()?;
    let entries = history.GetHistoryWithId(&HSTRING::from(app_id))?;
    let count = entries.Size()?;
    ensure!(
        count <= MAX_HISTORY,
        "Notification history exceeds bounded enumeration"
    );
    for i in 0..count {
        let entry = entries.GetAt(i)?;
        if entry.Group()?.to_string() != GROUP {
            continue;
        }
        let document = entry.Content()?;
        let root = document.DocumentElement()?;
        let id = root.GetAttribute(&HSTRING::from("launch"))?.to_string();
        if !owned_history_id(&id, thread) {
            continue;
        }
        let tag = entry.Tag()?;
        ensure!(
            !tag.is_empty() && tag.len() <= 16,
            "Invalid notification history receipt"
        );
        history.RemoveGroupedTagWithId(&tag, &HSTRING::from(GROUP), &HSTRING::from(app_id))?;
    }
    Ok(())
}
impl Backend for NativeBackend {
    // All COM/WinRT calls are synchronous, with no event handlers, async
    // operations or app callbacks registered. Apartment/objects return in scope.
    const MAY_RETAIN_NATIVE_CALLBACKS: bool = false;
    fn permission(&mut self) -> Result<Permission> {
        let _apartment = Apartment::new()?;
        status(&executable()?, &programs()?.join(SHORTCUT), APP_ID)
    }
    fn request_permission(&mut self) -> Result<Permission> {
        let _apartment = Apartment::new()?;
        let exe = executable()?;
        let shortcut = programs()?.join(SHORTCUT);
        register(&exe, &shortcut, APP_ID)?;
        status(&exe, &shortcut, APP_ID)
    }
    fn post(&mut self, payload: &Payload) -> Delivery {
        let Ok(_apartment) = Apartment::new() else {
            return Delivery::Unavailable;
        };
        // Recheck registration immediately before submitting to this fixed app.
        let allowed = (|| -> Result<Permission> {
            status(&executable()?, &programs()?.join(SHORTCUT), APP_ID)
        })();
        if allowed.ok() != Some(Permission::Authorized) {
            return Delivery::Unavailable;
        }
        post(APP_ID, payload, false)
    }

    fn clear_thread(&mut self, thread: Uuid) -> Result<()> {
        let _apartment = Apartment::new()?;
        // Clearing remains available when notifications are disabled in Settings.
        let exe = executable()?;
        ensure!(
            shortcut_matches(&programs()?.join(SHORTCUT), &exe, APP_ID)?,
            "Notification registration changed"
        );
        clear(APP_ID, thread)
            .map_err(|_| anyhow::anyhow!("Windows notification clearing could not be verified"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn history_has(app_id: &str, event: &str) -> Result<bool> {
        let entries =
            ToastNotificationManager::History()?.GetHistoryWithId(&HSTRING::from(app_id))?;
        let size = entries.Size()?;
        ensure!(
            size <= MAX_HISTORY,
            "Private notification history exceeds limit"
        );
        for i in 0..size {
            let toast = entries.GetAt(i)?;
            if toast.Group()?.to_string() == GROUP
                && toast
                    .Content()?
                    .DocumentElement()?
                    .GetAttribute(&HSTRING::from("launch"))?
                    .to_string()
                    == event
            {
                return Ok(true);
            }
        }
        Ok(false)
    }

    #[test]
    #[ignore = "Fresh Windows GitHub runner only: isolated AUMID and owned Start menu shortcut"]
    fn actual_owned_notification_registration_post_clear_and_absence() {
        assert_eq!(std::env::var("GITHUB_ACTIONS").as_deref(), Ok("true"));
        let runner = PathBuf::from(std::env::var_os("RUNNER_TEMP").expect("Fresh runner temp"));
        assert!(runner.is_absolute() && runner.is_dir());
        // Never change the application's AUMID, global process AUMID, existing
        // registration, registry, user notification preferences or other history.
        let _apartment = Apartment::new().unwrap();
        let exe = executable().unwrap();
        let nonce = Uuid::new_v4().simple().to_string();
        let app_id = format!("Coincide.NativeAcceptance.{nonce}");
        let shortcut = programs()
            .unwrap()
            .join(format!("Coincide Native Acceptance {nonce}.lnk"));
        assert!(!shortcut.exists());
        assert_eq!(
            status(&exe, &shortcut, &app_id).unwrap(),
            Permission::NotDetermined
        );
        register(&exe, &shortcut, &app_id).unwrap();
        let identity = native_file::path_identity(&shortcut).unwrap();
        assert!(shortcut_matches(&shortcut, &exe, &app_id).unwrap());
        register(&exe, &shortcut, &app_id).unwrap();
        assert_eq!(native_file::path_identity(&shortcut).unwrap(), identity);
        assert!(!shortcut_matches(&shortcut, &exe, "Foreign.Application").unwrap());
        assert!(register(&exe, &shortcut, "Foreign.Application").is_err());
        assert_eq!(native_file::path_identity(&shortcut).unwrap(), identity);
        assert_eq!(
            status(&exe, &shortcut, &app_id).unwrap(),
            Permission::Authorized
        );
        let thread = Uuid::new_v4();
        let payload = Payload {
            id: format!("coincide-rust.{thread}.{}.completed", Uuid::new_v4()),
            thread,
            title: "Coincide native notification acceptance".into(),
            body: Some("Synthetic data only. Native API acknowledgement; no banner claim.".into()),
        };
        // Actual WinRT Show, using the production implementation, with the
        // popup explicitly suppressed on the disposable runner.
        assert_eq!(post(&app_id, &payload, true), Delivery::Accepted);
        let deadline = Instant::now() + Duration::from_secs(3);
        while !history_has(&app_id, &payload.id).unwrap() {
            assert!(
                Instant::now() < deadline,
                "Actual OS notification history acknowledgement missing"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
        clear(&app_id, Uuid::new_v4()).unwrap();
        assert!(history_has(&app_id, &payload.id).unwrap());
        clear(&app_id, thread).unwrap();
        assert!(!history_has(&app_id, &payload.id).unwrap());
        assert!(shortcut_matches(&shortcut, &exe, &app_id).unwrap());
        assert_eq!(native_file::path_identity(&shortcut).unwrap(), identity);
        fs::remove_file(&shortcut).unwrap();
        assert!(!shortcut.exists());
        assert_eq!(
            status(&exe, &shortcut, &app_id).unwrap(),
            Permission::NotDetermined
        );
    }
}
