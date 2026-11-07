//! Windows Graphics Capture targets one HWND; protected capture surfaces remain
//! under Windows' capture policy. UI Automation guards password focus and limits
//! text to the selected window. No PrintWindow/full-desktop fallback is used.
use super::*;
use std::{
    os::windows::io::AsRawHandle,
    sync::{
        Mutex,
        atomic::{AtomicBool, AtomicPtr, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};
use windows::Win32::{
    Foundation::{HANDLE, HWND, LPARAM, LRESULT, WPARAM},
    System::{Com::*, Threading::GetThreadId},
    UI::{Accessibility::*, Input::KeyboardAndMouse::*, WindowsAndMessaging::*},
};
use windows_capture::{
    capture::{Context, GraphicsCaptureApiHandler},
    frame::Frame,
    graphics_capture_api::InternalCaptureControl,
    settings::*,
    window::Window,
};
static HOOK: AtomicPtr<std::ffi::c_void> = AtomicPtr::new(std::ptr::null_mut());
static PENDING: AtomicBool = AtomicBool::new(false);
#[derive(Default)]
struct Keys {
    left: bool,
    right: bool,
    alt: bool,
    shift: bool,
    win: bool,
    blocked: bool,
    fired: bool,
    custom: Option<(u32, u8)>,
}
static KEYS: Mutex<Keys> = Mutex::new(Keys {
    left: false,
    right: false,
    alt: false,
    shift: false,
    win: false,
    blocked: false,
    fired: false,
    custom: None,
});
unsafe extern "system" fn key_hook(code: i32, w: WPARAM, l: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let event = unsafe { &*(l.0 as *const KBDLLHOOKSTRUCT) };
        if event.flags.0 & LLKHF_INJECTED.0 == 0 {
            if let Ok(mut state) = KEYS.lock() {
                let down = w.0 == WM_KEYDOWN as usize || w.0 == WM_SYSKEYDOWN as usize;
                let key = event.vkCode;
                match key {
                    0xa2 => state.left = down,
                    0xa3 => state.right = down,
                    0x11 => {
                        if event.flags.0 & 1 != 0 {
                            state.right = down
                        } else {
                            state.left = down
                        }
                    }
                    0x12 | 0xa4 | 0xa5 => state.alt = down,
                    0x10 | 0xa0 | 0xa1 => state.shift = down,
                    0x5b | 0x5c => state.win = down,
                    _ => {
                        if down {
                            state.blocked = true;
                        }
                    }
                }
                if let Some((wanted, mods)) = state.custom {
                    let current = (if state.left || state.right { 2 } else { 0 })
                        | (if state.alt { 4 } else { 0 })
                        | (if state.shift { 8 } else { 0 })
                        | (if state.win { 1 } else { 0 });
                    if down && key == wanted && current == mods && !state.fired {
                        PENDING.store(true, Ordering::Release);
                        state.fired = true;
                    }
                    if !down && key == wanted {
                        state.fired = false;
                    }
                } else {
                    if !state.left && !state.right {
                        state.fired = false;
                        state.blocked = false;
                    }
                    if state.left
                        && state.right
                        && !state.alt
                        && !state.shift
                        && !state.win
                        && !state.blocked
                        && !state.fired
                    {
                        PENDING.store(true, Ordering::Release);
                        state.fired = true;
                    }
                }
            }
        }
    }
    unsafe { CallNextHookEx(None, code, w, l) }
}
pub(super) fn configure(shortcut: Option<&str>) -> Result<()> {
    stop();
    let custom = shortcut
        .map(|raw| -> Result<_> {
            let mut mods = 0;
            let mut key = None;
            for part in raw.split('+') {
                match part {
                    "mod" => mods |= 2,
                    "ctrl" => mods |= 2,
                    "alt" => mods |= 4,
                    "shift" => mods |= 8,
                    p if p.len() == 1 && p.bytes().all(|b| b.is_ascii_alphanumeric()) => {
                        key = Some(u32::from(p.as_bytes()[0].to_ascii_uppercase()))
                    }
                    _ => bail!("Unsupported Appshots shortcut"),
                }
            }
            Ok((
                key.ok_or_else(|| anyhow::anyhow!("Record a shortcut"))?,
                mods,
            ))
        })
        .transpose()?;
    KEYS.lock()
        .map_err(|_| anyhow::anyhow!("Appshots input owner unavailable"))?
        .custom = custom;
    let hook = unsafe { SetWindowsHookExW(WH_KEYBOARD_LL, Some(key_hook), None, 0) }?;
    HOOK.store(hook.0, Ordering::Release);
    Ok(())
}
pub(super) fn stop() {
    let hook = HOOK.swap(std::ptr::null_mut(), Ordering::AcqRel);
    if !hook.is_null() {
        let _ = unsafe { UnhookWindowsHookEx(HHOOK(hook)) };
    }
    if let Ok(mut state) = KEYS.lock() {
        *state = Keys::default();
    }
    PENDING.store(false, Ordering::Release);
}
pub(super) fn triggered() -> bool {
    PENDING.swap(false, Ordering::AcqRel)
}
pub(super) fn permissions(_: u8) -> Permissions {
    Permissions{screen:true,accessibility:true,detail:"Windows Graphics Capture enforces protected-content policy and displays its capture border. Accessibility text depends on the app’s UI Automation support. Administrator and secure-desktop windows may be unavailable; no desktop capture fallback is used. Both primary keys means left and right Control. A custom shortcut cannot reserve an OS-owned shortcut.".into()}
}
struct Com;
impl Com {
    fn open() -> Result<Self> {
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.ok()?;
        Ok(Self)
    }
}
impl Drop for Com {
    fn drop(&mut self) {
        unsafe {
            CoUninitialize();
        }
    }
}
fn automation() -> Result<IUIAutomation> {
    Ok(unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) }?)
}
fn password_guard(automation: &IUIAutomation, pid: u32, hwnd: HWND) -> Result<()> {
    let foreground = unsafe { GetForegroundWindow() };
    anyhow::ensure!(
        !foreground.0.is_null(),
        "Secure desktop or no foreground window"
    );
    let mut front_pid = 0;
    unsafe {
        GetWindowThreadProcessId(foreground, Some(&mut front_pid));
    }
    anyhow::ensure!(
        front_pid == pid || front_pid == std::process::id(),
        "Frontmost app changed during capture"
    );
    let mut actual = 0;
    let thread = unsafe { GetWindowThreadProcessId(hwnd, Some(&mut actual)) };
    anyhow::ensure!(actual == pid && thread != 0, "Window owner changed");
    let mut info = GUITHREADINFO {
        cbSize: std::mem::size_of::<GUITHREADINFO>() as u32,
        ..Default::default()
    };
    unsafe { GetGUIThreadInfo(thread, &mut info) }?;
    let focused = if !info.hwndFocus.0.is_null() {
        unsafe { automation.ElementFromHandle(info.hwndFocus) }?
    } else {
        unsafe { automation.ElementFromHandle(hwnd) }?
    };
    anyhow::ensure!(
        unsafe { focused.CurrentProcessId() }? == pid as i32,
        "Window input owner changed"
    );
    anyhow::ensure!(
        !unsafe { focused.CurrentIsPassword() }?.as_bool(),
        "Skipped: the app is taking a password"
    );
    Ok(())
}
fn window_text(automation: &IUIAutomation, hwnd: HWND) -> Result<String> {
    let root = unsafe { automation.ElementFromHandle(hwnd) }?;
    let walker = unsafe { automation.ControlViewWalker() }?;
    let mut pending = vec![(root, 0)];
    let mut seen = 0;
    let mut text = String::new();
    while let Some((element, depth)) = pending.pop() {
        seen += 1;
        if seen > 1000 || text.len() >= 30000 {
            break;
        }
        if unsafe { element.CurrentIsPassword() }?.as_bool() {
            continue;
        }
        if let Ok(name) = unsafe { element.CurrentName() } {
            append(&mut text, &name.to_string());
        }
        if let Ok(value) =
            unsafe { element.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId) }
        {
            if let Ok(value) = unsafe { value.CurrentValue() } {
                append(&mut text, &value.to_string());
            }
        }
        if depth < 16 {
            if let Ok(mut child) = unsafe { walker.GetFirstChildElement(&element) } {
                for _ in 0..1000 {
                    pending.push((child.clone(), depth + 1));
                    if pending.len() > 1000 {
                        break;
                    }
                    match unsafe { walker.GetNextSiblingElement(&child) } {
                        Ok(next) => child = next,
                        Err(_) => break,
                    }
                }
            }
        }
    }
    Ok(text)
}
fn append(text: &mut String, value: &str) {
    let remaining = 30000usize.saturating_sub(text.len());
    let end = value
        .char_indices()
        .map(|(i, _)| i)
        .chain(Some(value.len()))
        .take_while(|i| *i <= remaining)
        .last()
        .unwrap_or(0);
    if end > 0 {
        text.push_str(&value[..end]);
        text.push('\n');
    }
}
struct OneFrame {
    sender: mpsc::SyncSender<Result<Vec<u8>>>,
}
impl GraphicsCaptureApiHandler for OneFrame {
    type Flags = mpsc::SyncSender<Result<Vec<u8>>>;
    type Error = anyhow::Error;
    fn new(context: Context<Self::Flags>) -> Result<Self> {
        Ok(Self {
            sender: context.flags,
        })
    }
    fn on_frame_arrived(
        &mut self,
        frame: &mut Frame,
        control: InternalCaptureControl,
    ) -> Result<()> {
        let result = (|| {
            let width = frame.width();
            let height = frame.height();
            anyhow::ensure!(
                width <= 8192
                    && height <= 8192
                    && u64::from(width) * u64::from(height) <= 16_000_000,
                "Window exceeds capture limits"
            );
            let mut buffer = frame.buffer()?;
            coincide_core::appshots::encode_rgba(
                width,
                height,
                buffer.as_nopadding_buffer()?.to_vec(),
            )
        })();
        let _ = self.sender.try_send(result);
        control.stop();
        Ok(())
    }
}
pub(super) fn capture(read_text: bool, allowed: &dyn Fn() -> bool) -> Result<Capture> {
    let _com = Com::open()?;
    anyhow::ensure!(allowed(), "Capture cancelled");
    let mut window = Window::foreground()?;
    if window.process_id()? == std::process::id() {
        window = Window::enumerate()?
            .into_iter()
            .find(|w| w.process_id().is_ok_and(|pid| pid != std::process::id()))
            .ok_or_else(|| anyhow::anyhow!("No other app window to capture"))?;
    }
    anyhow::ensure!(window.is_valid(), "No window to capture");
    let pid = window.process_id()?;
    let hwnd = HWND(window.as_raw_hwnd());
    let automation = automation()?;
    password_guard(&automation, pid, hwnd)?;
    let rect = window.rect()?;
    anyhow::ensure!(
        rect.right - rect.left >= 40 && rect.bottom - rect.top >= 40,
        "No eligible window to capture"
    );
    let text = if read_text {
        Some(window_text(&automation, hwnd)?)
    } else {
        None
    };
    let app = window.process_name()?;
    let title = Some(window.title()?);
    let (tx, rx) = mpsc::sync_channel(1);
    let settings = windows_capture::settings::Settings::new(
        window,
        CursorCaptureSettings::WithoutCursor,
        DrawBorderSettings::WithBorder,
        SecondaryWindowSettings::Exclude,
        MinimumUpdateIntervalSettings::Default,
        DirtyRegionSettings::Default,
        ColorFormat::Rgba8,
        tx,
    );
    let control = OneFrame::start_free_threaded(settings)
        .map_err(|e| anyhow::anyhow!("Window capture could not start: {e:?}"))?;
    let deadline = Instant::now() + Duration::from_secs(5);
    let result = loop {
        match rx.recv_timeout(Duration::from_millis(25)) {
            Ok(result) => break result,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                break Err(anyhow::anyhow!("Window capture closed"));
            }
            Err(_) => {
                if !allowed() || Instant::now() >= deadline {
                    break Err(anyhow::anyhow!("Capture cancelled or timed out"));
                }
            }
        }
    };
    // Upstream CaptureControl::stop can return before joining on a failed
    // message post. Keep the actual handle through every stop/error/TLS path.
    control.halt_handle().store(true, Ordering::Release);
    let worker = control.into_thread_handle();
    let thread_id = unsafe { GetThreadId(HANDLE(worker.as_raw_handle())) };
    let returned = crate::computer_use::capture_owner::join_after_stop(worker, || {
        unsafe { PostThreadMessageW(thread_id, WM_QUIT, WPARAM(0), LPARAM(0)) }
            .or_else(|error| {
                if error.code() == windows::core::HRESULT::from_win32(1444) {
                    Ok(())
                } else {
                    Err(error)
                }
            })
            .map_err(|_| ())
    })
    .map_err(|_| anyhow::anyhow!("Capture stop or actual worker join failed"))?;
    returned.map_err(|_| anyhow::anyhow!("Capture worker returned an error"))?;
    anyhow::ensure!(allowed(), "Capture cancelled");
    password_guard(&automation, pid, hwnd)?;
    Ok(Capture {
        png: result?,
        app,
        title,
        text,
        frame: None,
    })
}
pub(super) fn sound() {
    unsafe { windows::Win32::System::Diagnostics::Debug::MessageBeep(MB_OK) }.ok();
}
