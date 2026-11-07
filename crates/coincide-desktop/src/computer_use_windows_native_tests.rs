//! Explicit fresh-runner acceptance against one owned synthetic Win32 child.
//! Ordinary/default tests never create windows, query the desktop or capture.
use super::ThreadDpi;
use crate::computer_use::Runtime;
use ::windows::{
    Win32::{
        Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM},
        Graphics::{
            Dwm::{DWMWA_EXTENDED_FRAME_BOUNDS, DwmGetWindowAttribute},
            Gdi::{COLOR_WINDOW, GetSysColorBrush},
        },
        System::LibraryLoader::GetModuleHandleW,
        UI::{
            HiDpi::GetDpiForWindow,
            Input::KeyboardAndMouse::{GetFocus, SetFocus},
            WindowsAndMessaging::*,
        },
    },
    core::w,
};
use base64::Engine as _;
use coincide_core::{
    agent::WorkerThreadStatus,
    computer_use::{Failure, Request},
    native_file,
};
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::OnceLock,
    time::{Duration, Instant},
};
use uuid::Uuid;
static ROOT: OnceLock<PathBuf> = OnceLock::new();
fn fresh_runner() {
    assert_eq!(std::env::var("GITHUB_ACTIONS").as_deref(), Ok("true"));
    assert_eq!(
        std::env::var("COINCIDE_CU_NATIVE_CI").as_deref(),
        Ok("owned-window-v1")
    );
}
fn receipt(hwnd: HWND) {
    let Some(root) = ROOT.get() else {
        return;
    };
    let Ok(edit) = (unsafe { GetDlgItem(hwnd, 100) }) else {
        return;
    };
    let Ok(button) = (unsafe { GetDlgItem(hwnd, 101) }) else {
        return;
    };
    let mut text = [0u16; 256];
    let n = unsafe { GetWindowTextW(edit, &mut text) }.max(0) as usize;
    let mut bounds = RECT::default();
    let mut target = RECT::default();
    if unsafe {
        DwmGetWindowAttribute(
            hwnd,
            DWMWA_EXTENDED_FRAME_BOUNDS,
            (&mut bounds as *mut RECT).cast(),
            std::mem::size_of::<RECT>() as u32,
        )
    }
    .is_err()
        || unsafe { GetWindowRect(button, &mut target) }.is_err()
    {
        return;
    }
    let dpi = unsafe { GetDpiForWindow(hwnd) };
    if dpi == 0 {
        return;
    }
    let clicks = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) };
    let data = json!({"pid":std::process::id(),"hwnd":hwnd.0 as usize,"text":String::from_utf16_lossy(&text[..n]),"clicks":clicks,"focus":unsafe{GetDlgCtrlID(GetFocus())},"pointX":f64::from((target.left+target.right)/2-bounds.left)*96.0/f64::from(dpi),"pointY":f64::from((target.top+target.bottom)/2-bounds.top)*96.0/f64::from(dpi)});
    let temp = root.join("state-new.json");
    if std::fs::write(&temp, serde_json::to_vec(&data).unwrap()).is_ok() {
        let _ = std::fs::rename(temp, root.join("state.json"));
    }
}
unsafe extern "system" fn procedure(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_COMMAND => {
            if wparam.0 & 0xffff == 101 && wparam.0 >> 16 == BN_CLICKED as usize {
                let value = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) };
                unsafe { SetWindowLongPtrW(hwnd, GWLP_USERDATA, value + 1) };
            }
            receipt(hwnd);
            LRESULT(0)
        }
        value if value == WM_APP + 1 || value == WM_APP + 2 => {
            let id = if value == WM_APP + 1 { 102 } else { 100 };
            if let Ok(control) = unsafe { GetDlgItem(hwnd, id) } {
                unsafe { SetFocus(Some(control)) }.ok();
            }
            receipt(hwnd);
            LRESULT(0)
        }
        WM_TIMER | WM_CLOSE => {
            unsafe { DestroyWindow(hwnd) }.ok();
            LRESULT(0)
        }
        WM_DESTROY => {
            unsafe { PostQuitMessage(0) };
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}
#[test]
#[ignore = "fresh Windows runner fixture child only; never developer desktop"]
fn owned_native_window_fixture() {
    fresh_runner();
    let root =
        PathBuf::from(std::env::var_os("COINCIDE_CU_NATIVE_ROOT").expect("private fixture root"));
    assert!(
        root.is_absolute()
            && root
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("coincide-cu-owned-")
    );
    ROOT.set(root).unwrap();
    let _dpi = ThreadDpi::open().expect("owned fixture DPI");
    let instance = HINSTANCE(unsafe { GetModuleHandleW(None) }.unwrap().0);
    let class = WNDCLASSW {
        lpfnWndProc: Some(procedure),
        hInstance: instance,
        lpszClassName: w!("CoincideCuOwnedFixture"),
        hbrBackground: unsafe { GetSysColorBrush(COLOR_WINDOW) },
        ..Default::default()
    };
    assert_ne!(unsafe { RegisterClassW(&class) }, 0);
    let hwnd = unsafe {
        CreateWindowExW(
            WS_EX_APPWINDOW,
            w!("CoincideCuOwnedFixture"),
            w!("Owned Computer Use fixture"),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            160,
            120,
            520,
            300,
            None,
            None,
            Some(instance),
            None,
        )
    }
    .unwrap();
    let create = |class, text, style, x, y, width, height, id| {
        unsafe {
            CreateWindowExW(
                WINDOW_EX_STYLE(0),
                class,
                text,
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | style,
                x,
                y,
                width,
                height,
                Some(hwnd),
                Some(HMENU(id as *mut _)),
                Some(instance),
                None,
            )
        }
        .unwrap()
    };
    let edit = create(
        w!("EDIT"),
        w!("xy"),
        WS_BORDER | WINDOW_STYLE(ES_AUTOHSCROLL as u32),
        20,
        20,
        320,
        35,
        100usize,
    );
    create(
        w!("BUTTON"),
        w!("Owned action"),
        WINDOW_STYLE(BS_PUSHBUTTON as u32),
        20,
        75,
        180,
        40,
        101,
    );
    create(
        w!("EDIT"),
        w!("synthetic masked"),
        WS_BORDER | WINDOW_STYLE((ES_PASSWORD | ES_AUTOHSCROLL) as u32),
        20,
        135,
        320,
        35,
        102,
    );
    unsafe { SetTimer(Some(hwnd), 1, 60000, None) };
    unsafe { ShowWindow(hwnd, SW_SHOW) };
    unsafe { SetForegroundWindow(hwnd) };
    unsafe { SetFocus(Some(edit)) }.ok();
    receipt(hwnd);
    let mut message = MSG::default();
    loop {
        let result = unsafe { GetMessageW(&mut message, None, 0, 0) };
        assert_ne!(result.0, -1, "Owned fixture message loop failed");
        if result.0 == 0 {
            break;
        }
        unsafe {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
}
fn wait<T>(description: &str, mut operation: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(12);
    loop {
        if let Some(value) = operation() {
            return value;
        }
        assert!(Instant::now() < deadline, "Timed out: {description}");
        std::thread::sleep(Duration::from_millis(10));
    }
}
struct OwnedFixture {
    root: PathBuf,
    child: Option<Child>,
    window: Option<HWND>,
    runtime: Option<Runtime>,
    complete: bool,
}
impl OwnedFixture {
    fn state(&self) -> Option<Value> {
        serde_json::from_slice(&std::fs::read(self.root.join("state.json")).ok()?).ok()
    }
    fn post(&self, message: u32) {
        let hwnd = self.window.unwrap();
        let mut pid = 0;
        unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
        assert_eq!(Some(pid), self.child.as_ref().map(Child::id));
        unsafe { PostMessageW(Some(hwnd), message, WPARAM(0), LPARAM(0)) }.unwrap();
    }
    fn close_child(&mut self) {
        if self.child.is_some() {
            self.post(WM_CLOSE);
            assert!(self.child.as_mut().unwrap().wait().unwrap().success());
            self.child = None;
            self.window = None;
        }
    }
    fn drain(&mut self) {
        if let Some(runtime) = self.runtime.as_mut() {
            runtime.request_shutdown();
            wait("actual Computer Use worker join", || {
                let status = runtime.shutdown_status();
                (status.worker == WorkerThreadStatus::Returned
                    && status.pending_reservations == Some(0))
                .then_some(())
            });
        }
        self.runtime = None;
    }
}
impl Drop for OwnedFixture {
    fn drop(&mut self) {
        if let Some(runtime) = self.runtime.as_mut() {
            runtime.request_shutdown();
        }
        if self
            .child
            .as_mut()
            .is_some_and(|child| child.try_wait().ok().flatten().is_none())
        {
            if let (Some(child), Some(hwnd)) = (&self.child, self.window) {
                let mut pid = 0;
                unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
                if pid == child.id() {
                    unsafe { PostMessageW(Some(hwnd), WM_CLOSE, WPARAM(0), LPARAM(0)) }.ok();
                }
            }
        }
        if let Some(child) = self.child.as_mut() {
            let _ = child.wait();
        }
        if self.complete {
            let _ = std::fs::remove_dir_all(&self.root);
        } else {
            if let Ok(log) = std::fs::read_to_string(self.root.join("child.log")) {
                eprintln!(
                    "Owned synthetic CU child diagnostics: {}",
                    log.chars().take(4096).collect::<String>()
                );
            }
            eprintln!(
                "Owned synthetic CU fixture retained at {}",
                self.root.display()
            );
        }
    }
}
fn request(
    owner: &OwnedFixture,
    thread: Uuid,
    name: &str,
    arguments: Value,
) -> Result<Value, Failure> {
    let runtime = owner.runtime.as_ref().unwrap();
    let parsed = Request::parse(
        &serde_json::to_vec(&json!({"action":"call","name":name,"arguments":arguments})).unwrap(),
    )?;
    let id = runtime.handle().try_request(thread, parsed)?;
    wait("actual CU reply", || match runtime.try_reply() {
        Ok(reply) => {
            assert_eq!(reply.id, id);
            assert_eq!(reply.thread, thread);
            Some(reply.result)
        }
        Err(std::sync::mpsc::TryRecvError::Empty) => None,
        Err(_) => panic!("CU worker disconnected"),
    })
}
fn observe(owner: &OwnedFixture, thread: Uuid, pid: u32, window: u32, screenshot: bool) -> Value {
    request(
        owner,
        thread,
        "get_window_state",
        json!({"pid":pid,"window_id":window,"max_elements":64,"include_screenshot":screenshot}),
    )
    .expect("owned CU observation")
}
fn element(snapshot: &Value, role: &str) -> Value {
    snapshot["elements"]
        .as_array()
        .unwrap()
        .iter()
        .find(|node| {
            node["role"] == role
                && node["secure"] == false
                && (role != "button" || node["title"] == "Owned action")
        })
        .expect("owned typed element")["element_token"]
        .clone()
}
#[test]
#[ignore = "explicit fresh Windows runner owned-window acceptance only"]
fn actual_owned_window_actions_and_capture_drain() {
    fresh_runner();
    let root = std::env::temp_dir().join(format!("coincide-cu-owned-{}", Uuid::new_v4()));
    native_file::private_directory(&root).unwrap();
    let mut command = Command::new(std::env::current_exe().unwrap());
    command.env_clear();
    for key in ["PATH", "SystemRoot", "WINDIR", "SYSTEMDRIVE"] {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    for key in [
        "HOME",
        "USERPROFILE",
        "TMP",
        "TEMP",
        "APPDATA",
        "LOCALAPPDATA",
    ] {
        let path = root.join(key);
        native_file::private_directory(&path).unwrap();
        command.env(key, path);
    }
    command
        .env("GITHUB_ACTIONS", "true")
        .env("COINCIDE_CU_NATIVE_CI", "owned-window-v1")
        .env("COINCIDE_CU_NATIVE_ROOT", &root)
        .args([
            "--ignored",
            "--exact",
            "computer_use::windows::native_tests::owned_native_window_fixture",
            "--nocapture",
            "--test-threads=1",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let log = native_file::create_private_file(&root.join("child.log")).unwrap();
    command
        .stdout(Stdio::from(log.try_clone().unwrap()))
        .stderr(Stdio::from(log));
    let child = command.spawn().unwrap();
    let pid = child.id();
    let mut owner = OwnedFixture {
        root,
        child: Some(child),
        window: None,
        runtime: None,
        complete: false,
    };
    let ready = wait("owned Win32 child ready", || {
        assert!(
            owner.child.as_mut().unwrap().try_wait().unwrap().is_none(),
            "Owned window child exited early"
        );
        owner.state()
    });
    assert_eq!(ready["pid"].as_u64(), Some(u64::from(pid)));
    owner.window = Some(HWND(ready["hwnd"].as_u64().unwrap() as usize as *mut _));
    owner.runtime = Some(Runtime::spawn_native().unwrap());
    let thread = Uuid::new_v4();
    let handle = owner.runtime.as_ref().unwrap().handle();
    handle.native_enable(true).unwrap();
    handle.native_grant(thread).unwrap();
    let windows = request(&owner, thread, "list_windows", json!({"pid":pid})).unwrap();
    let window = windows
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["pid"].as_u64() == Some(u64::from(pid)))
        .expect("owned child listed")["window_id"]
        .as_u64()
        .unwrap() as u32;
    let snapshot = observe(&owner, thread, pid, window, false);
    let edit = element(&snapshot, "edit");
    request(
        &owner,
        thread,
        "set_value",
        json!({"element_token":edit,"text":"π🙂xy"}),
    )
    .unwrap();
    wait("actual ValuePattern mutation", || {
        owner.state().filter(|state| state["text"] == "π🙂xy")
    });
    let reset = observe(&owner, thread, pid, window, false);
    request(
        &owner,
        thread,
        "set_value",
        json!({"element_token":element(&reset,"edit"),"text":"xy"}),
    )
    .unwrap();
    wait("plain key fixture reset", || {
        owner.state().filter(|state| state["text"] == "xy")
    });
    for key in ["left", "left", "right", "backspace"] {
        let state = observe(&owner, thread, pid, window, false);
        request(
            &owner,
            thread,
            "press_key",
            json!({"element_token":element(&state,"edit"),"key":key}),
        )
        .unwrap();
    }
    wait("actual bounded key sequence", || {
        owner.state().filter(|state| state["text"] == "y")
    });
    let snapshot = observe(&owner, thread, pid, window, false);
    request(
        &owner,
        thread,
        "click",
        json!({"element_token":element(&snapshot,"button")}),
    )
    .unwrap();
    wait("actual InvokePattern effect", || {
        owner.state().filter(|state| state["clicks"] == 1)
    });
    let image = observe(&owner, thread, pid, window, true);
    assert_eq!(image["screenshot"]["encoding"], "png_base64");
    assert!(image["screenshot"]["data"].as_str().unwrap().len() > 100);
    let png = base64::engine::general_purpose::STANDARD
        .decode(image["screenshot"]["data"].as_str().unwrap())
        .unwrap();
    assert!(png.starts_with(b"\x89PNG\r\n\x1a\n"));
    let position = owner.state().unwrap();
    request(
        &owner,
        thread,
        "click_point",
        json!({"observation":image["observation"],"x":position["pointX"],"y":position["pointY"]}),
    )
    .unwrap();
    wait("actual screenshot-bound point effect", || {
        owner.state().filter(|state| state["clicks"] == 2)
    });
    owner.post(WM_APP + 1);
    wait("owned password focus", || {
        owner.state().filter(|state| state["focus"] == 102)
    });
    let snapshot = observe(&owner, thread, pid, window, false);
    let secure = snapshot["elements"]
        .as_array()
        .unwrap()
        .iter()
        .find(|node| node["secure"] == true)
        .unwrap();
    assert!(secure["value"].is_null());
    assert_eq!(secure["title"], "");
    assert!(matches!(
        request(
            &owner,
            thread,
            "set_value",
            json!({"element_token":secure["element_token"],"text":"refused"})
        ),
        Err(Failure::PermissionDenied)
    ));
    assert!(matches!(
        request(
            &owner,
            thread,
            "get_window_state",
            json!({"pid":pid,"window_id":window,"include_screenshot":true})
        ),
        Err(Failure::PermissionDenied)
    ));
    owner.post(WM_APP + 2);
    wait("owned plain focus", || {
        owner.state().filter(|state| state["focus"] == 100)
    });
    let snapshot = observe(&owner, thread, pid, window, false);
    handle.native_revoke(thread);
    assert!(matches!(
        request(
            &owner,
            thread,
            "set_value",
            json!({"element_token":element(&snapshot,"edit"),"text":"refused"})
        ),
        Err(Failure::NotGranted)
    ));
    assert_eq!(owner.state().unwrap()["text"], "y");
    owner.close_child();
    handle.native_grant(thread).unwrap();
    assert!(matches!(
        request(
            &owner,
            thread,
            "get_window_state",
            json!({"pid":pid,"window_id":window})
        ),
        Err(Failure::StaleObservation)
    ));
    owner.drain();
    owner.complete = true;
    println!(
        "Owned Windows CU actions, secure/refused input, exact-window capture, child exit and actual worker join confirmed"
    );
}
