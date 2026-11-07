//! Windows Computer Use. All COM/native objects are created lazily on the one
//! existing serialized CU worker; opaque Broker grants never become HWNDs.
use super::{windows_policy as policy, *};
use ::windows::{
    Graphics::Capture::GraphicsCaptureSession,
    Win32::{
        Foundation::{CloseHandle, FILETIME, HANDLE, HWND, LPARAM, RECT, WAIT_TIMEOUT},
        Graphics::Dwm::{DWMWA_EXTENDED_FRAME_BOUNDS, DwmGetWindowAttribute},
        System::{Com::*, Ole::*, StationsAndDesktops::*, Threading::*},
        UI::{Accessibility::*, HiDpi::*, Input::KeyboardAndMouse::*, WindowsAndMessaging::*},
    },
    core::{BSTR, Interface, PWSTR},
};
use base64::Engine as _;
use serde_json::json;
use std::{
    collections::{BTreeMap, BTreeSet},
    os::windows::io::AsRawHandle,
    rc::Rc,
};
use windows_capture::{
    capture::{Context as CaptureContext, GraphicsCaptureApiHandler},
    frame::Frame,
    graphics_capture_api::InternalCaptureControl,
    settings::*,
    window::Window,
};
type R<T> = Result<T, Failure>;
fn native<T>(value: ::windows::core::Result<T>) -> R<T> {
    value.map_err(|_| Failure::Native)
}
fn checked(permit: &Permit, deadline: Instant) -> R<()> {
    permit.check()?;
    if Instant::now() >= deadline {
        Err(Failure::TimedOut)
    } else {
        Ok(())
    }
}
struct ThreadDpi(DPI_AWARENESS_CONTEXT);
impl ThreadDpi {
    fn open() -> R<Self> {
        // Scope physical-coordinate APIs to this owned worker only. Never
        // change the app/process/system DPI configuration.
        let previous =
            unsafe { SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
        if previous.0.is_null() {
            return Err(Failure::Unsupported);
        }
        Ok(Self(previous))
    }
}
impl Drop for ThreadDpi {
    fn drop(&mut self) {
        unsafe { SetThreadDpiAwarenessContext(self.0) };
    }
}
struct Com;
impl Drop for Com {
    fn drop(&mut self) {
        unsafe { CoUninitialize() };
    }
}
struct Context {
    automation: IUIAutomation,
    // The COM references above are destroyed before this apartment guard.
    _com: Com,
}
impl Context {
    fn open() -> R<Self> {
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }
            .ok()
            .map_err(|_| Failure::Native)?;
        let guard = Com;
        let automation: IUIAutomation =
            native(unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) })?;
        let timed: IUIAutomation2 = native(automation.cast())?;
        native(unsafe { timed.SetConnectionTimeout(150) })?;
        native(unsafe { timed.SetTransactionTimeout(150) })?;
        Ok(Self {
            automation,
            _com: guard,
        })
    }
}
struct Process {
    handle: HANDLE,
    created: u64,
    pid: u32,
    name: String,
}
impl Drop for Process {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.handle) }.ok();
    }
}
impl Process {
    fn open(pid: u32) -> R<Self> {
        if pid == 0 || pid == std::process::id() {
            return Err(Failure::PermissionDenied);
        }
        let handle = native(unsafe {
            OpenProcess(
                PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
                false,
                pid,
            )
        })?;
        let mut owned = Self {
            handle,
            created: 0,
            pid,
            name: String::new(),
        };
        owned.created = owned.creation()?;
        let mut path = vec![0u16; 32768];
        let mut size = path.len() as u32;
        native(unsafe {
            QueryFullProcessImageNameW(
                handle,
                PROCESS_NAME_WIN32,
                PWSTR(path.as_mut_ptr()),
                &mut size,
            )
        })?;
        let path = String::from_utf16_lossy(&path[..size as usize]);
        if policy::restricted_executable(&path) {
            return Err(Failure::Unsupported);
        }
        owned.name = path.rsplit(['\\', '/']).next().unwrap_or("").to_owned();
        Ok(owned)
    }
    fn creation(&self) -> R<u64> {
        if unsafe { WaitForSingleObject(self.handle, 0) } != WAIT_TIMEOUT {
            return Err(Failure::StaleObservation);
        }
        let (mut birth, mut exit, mut kernel, mut user) = (
            FILETIME::default(),
            FILETIME::default(),
            FILETIME::default(),
            FILETIME::default(),
        );
        native(unsafe {
            GetProcessTimes(self.handle, &mut birth, &mut exit, &mut kernel, &mut user)
        })?;
        Ok((u64::from(birth.dwHighDateTime) << 32) | u64::from(birth.dwLowDateTime))
    }
}
#[derive(Clone)]
struct WindowBinding {
    id: u32,
    hwnd: HWND,
    process: Rc<Process>,
}
impl WindowBinding {
    fn identity(&self) -> policy::Identity {
        policy::Identity {
            hwnd: self.hwnd.0 as usize,
            pid: self.process.pid,
            created: self.process.created,
        }
    }
    fn verify(&self) -> R<()> {
        let mut pid = 0;
        let thread = unsafe { GetWindowThreadProcessId(self.hwnd, Some(&mut pid)) };
        let now = policy::Identity {
            hwnd: self.hwnd.0 as usize,
            pid,
            created: self.process.creation()?,
        };
        if thread == 0
            || !unsafe { IsWindow(Some(self.hwnd)) }.as_bool()
            || !self.identity().matches(now)
        {
            return Err(Failure::StaleObservation);
        }
        Ok(())
    }
    fn geometry(&self) -> R<([i32; 4], u32)> {
        self.verify()?;
        let mut rect = RECT::default();
        native(unsafe {
            DwmGetWindowAttribute(
                self.hwnd,
                DWMWA_EXTENDED_FRAME_BOUNDS,
                (&mut rect as *mut RECT).cast(),
                std::mem::size_of::<RECT>() as u32,
            )
        })?;
        let dpi = unsafe { GetDpiForWindow(self.hwnd) };
        let bounds = [rect.left, rect.top, rect.right, rect.bottom];
        if policy::point(bounds, dpi, 0.0, 0.0).is_none() {
            return Err(Failure::TooLarge);
        }
        Ok((bounds, dpi))
    }
}
struct ElementBinding {
    window: WindowBinding,
    root: IUIAutomationElement,
    element: IUIAutomationElement,
    runtime: Vec<i32>,
}
struct Observed {
    window: WindowBinding,
    bounds: [i32; 4],
    dpi: u32,
    screenshot: bool,
}
#[derive(Default)]
pub(super) struct NativeBackend {
    context: Option<Context>,
    windows: BTreeMap<u32, WindowBinding>,
    elements: BTreeMap<u64, ElementBinding>,
    observed: Option<Observed>,
    next_window: u32,
    next_element: u64,
}
// SAFETY: spawn_native moves the inert value once onto its serialized worker.
// No COM object or native handle is created before that move or shared outside it.
unsafe impl Send for NativeBackend {}
impl NativeBackend {
    fn context(&mut self) -> R<&Context> {
        if self.context.is_none() {
            self.context = Some(Context::open()?);
        }
        self.context.as_ref().ok_or(Failure::Native)
    }
    fn list(&mut self, permit: &Permit) -> R<Vec<WindowBinding>> {
        struct Enumeration {
            handles: Vec<HWND>,
            deadline: Instant,
        }
        unsafe extern "system" fn visit(hwnd: HWND, raw: LPARAM) -> ::windows::core::BOOL {
            // SAFETY: EnumWindows invokes synchronously with our live context.
            let state = unsafe { &mut *(raw.0 as *mut Enumeration) };
            if state.handles.len() >= 128 || Instant::now() >= state.deadline {
                return false.into();
            }
            if unsafe { IsWindowVisible(hwnd) }.as_bool()
                && unsafe { GetAncestor(hwnd, GA_ROOT) } == hwnd
            {
                state.handles.push(hwnd);
            }
            true.into()
        }
        permit.check()?;
        self.invalidate();
        self.windows.clear();
        let mut enumeration = Enumeration {
            handles: vec![],
            deadline: Instant::now() + Duration::from_secs(2),
        };
        // A false callback intentionally stops the bounded enumeration.
        unsafe {
            EnumWindows(
                Some(visit),
                LPARAM((&mut enumeration as *mut Enumeration) as isize),
            )
        }
        .ok();
        let mut result = vec![];
        for hwnd in enumeration.handles {
            checked(permit, enumeration.deadline)?;
            let mut pid = 0;
            unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
            let Ok(process) = Process::open(pid) else {
                continue;
            };
            self.next_window = self.next_window.checked_add(1).ok_or(Failure::TooLarge)?;
            let binding = WindowBinding {
                id: self.next_window,
                hwnd,
                process: Rc::new(process),
            };
            if binding.geometry().is_err() {
                continue;
            }
            self.windows.insert(binding.id, binding.clone());
            result.push(binding);
        }
        Ok(result)
    }
    fn window(&self, pid: i32, id: u32) -> R<WindowBinding> {
        let value = self
            .windows
            .get(&id)
            .filter(|w| w.process.pid == pid as u32)
            .ok_or(Failure::StaleObservation)?
            .clone();
        value.verify()?;
        Ok(value)
    }
    fn observe(
        &mut self,
        window: WindowBinding,
        limit: usize,
        screenshot: bool,
        permit: &Permit,
    ) -> R<NativeResult> {
        self.invalidate();
        let deadline = Instant::now() + Duration::from_secs(3);
        let automation = self.context()?.automation.clone();
        let (bounds, dpi) = window.geometry()?;
        checked(permit, deadline)?;
        let root = native(unsafe { automation.ElementFromHandle(window.hwnd) })?;
        let walker = native(unsafe { automation.ControlViewWalker() })?;
        let mut pending = vec![(root.clone(), 0usize)];
        let mut nodes = vec![];
        let mut visited = BTreeSet::new();
        while let Some((element, depth)) = pending.pop() {
            checked(permit, deadline)?;
            window.verify()?;
            if nodes.len() >= limit.min(MAX_NODES) {
                break;
            }
            let runtime = runtime_id(&element)?;
            if !visited.insert(runtime.clone()) {
                continue;
            }
            if native(unsafe { element.CurrentProcessId() })? != window.process.pid as i32 {
                return Err(Failure::StaleObservation);
            }
            let secure = unsafe { element.CurrentIsPassword() }.map_or(true, |v| v.as_bool());
            let focused = unsafe { element.CurrentHasKeyboardFocus() }.is_ok_and(|v| v.as_bool());
            checked(permit, deadline)?;
            let role = policy::role(native(unsafe { element.CurrentControlType() })?.0).to_owned();
            let title = if secure {
                String::new()
            } else {
                policy::bounded_text(&native(unsafe { element.CurrentName() })?.to_string(), 256)
            };
            checked(permit, deadline)?;
            let value = if secure {
                None
            } else {
                unsafe {
                    element.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
                }
                .ok()
                .and_then(|pattern| unsafe { pattern.CurrentValue() }.ok())
                .map(|v| policy::bounded_text(&v.to_string(), 1024))
            };
            self.next_element = self.next_element.checked_add(1).ok_or(Failure::TooLarge)?;
            let id = self.next_element;
            self.elements.insert(
                id,
                ElementBinding {
                    window: window.clone(),
                    root: root.clone(),
                    element: element.clone(),
                    runtime,
                },
            );
            nodes.push(Node {
                native_id: id,
                role,
                title,
                value,
                secure,
                focused,
            });
            if secure || depth >= 16 {
                continue;
            }
            checked(permit, deadline)?;
            if let Ok(mut child) = unsafe { walker.GetFirstChildElement(&element) } {
                // Work is bounded before every remote COM call; FindAll is never used.
                for _ in 0..MAX_NODES.saturating_sub(pending.len() + nodes.len()) {
                    checked(permit, deadline)?;
                    pending.push((child.clone(), depth + 1));
                    match unsafe { walker.GetNextSiblingElement(&child) } {
                        Ok(next) => child = next,
                        Err(_) => break,
                    }
                }
            }
        }
        let image = if screenshot {
            password_guard(&automation, &window, false, permit)?;
            let image = capture(&window, permit)?;
            if image.width as i64 != i64::from(bounds[2]) - i64::from(bounds[0])
                || image.height as i64 != i64::from(bounds[3]) - i64::from(bounds[1])
            {
                return Err(Failure::StaleObservation);
            }
            password_guard(&automation, &window, false, permit)?;
            Some(image)
        } else {
            None
        };
        checked(permit, deadline)?;
        if window.geometry()? != (bounds, dpi) {
            return Err(Failure::StaleObservation);
        }
        self.observed = Some(Observed {
            window,
            bounds,
            dpi,
            screenshot,
        });
        Ok(NativeResult::Snapshot(Snapshot {
            nodes,
            screenshot: image,
            width: f64::from(bounds[2] - bounds[0]) * 96.0 / f64::from(dpi),
            height: f64::from(bounds[3] - bounds[1]) * 96.0 / f64::from(dpi),
        }))
    }
    fn element(&self, id: u64, permit: &Permit) -> R<&ElementBinding> {
        permit.check()?;
        let binding = self.elements.get(&id).ok_or(Failure::StaleObservation)?;
        binding.window.verify()?;
        if runtime_id(&binding.element)? != binding.runtime
            || native(unsafe { binding.element.CurrentProcessId() })?
                != binding.window.process.pid as i32
        {
            return Err(Failure::StaleObservation);
        }
        if native(unsafe { binding.element.CurrentIsPassword() })?.as_bool() {
            return Err(Failure::PermissionDenied);
        }
        if !native(unsafe { binding.element.CurrentIsEnabled() })?.as_bool()
            || native(unsafe { binding.element.CurrentIsOffscreen() })?.as_bool()
        {
            return Err(Failure::PermissionDenied);
        }
        let automation = &self.context.as_ref().ok_or(Failure::Native)?.automation;
        let walker = native(unsafe { automation.ControlViewWalker() })?;
        let mut ancestor = binding.element.clone();
        let mut found = false;
        for _ in 0..=16 {
            permit.check()?;
            if native(unsafe { automation.CompareElements(&ancestor, &binding.root) })?.as_bool() {
                found = true;
                break;
            }
            ancestor = native(unsafe { walker.GetParentElement(&ancestor) })?;
        }
        if !found {
            return Err(Failure::StaleObservation);
        }
        password_guard(automation, &binding.window, true, permit)?;
        permit.check()?;
        Ok(binding)
    }
}
impl Backend for NativeBackend {
    fn permissions(&mut self) -> R<Permissions> {
        self.context()?;
        Ok(Permissions {
            accessibility: Permission::Granted,
            screen_capture: if GraphicsCaptureSession::IsSupported().unwrap_or(false) {
                Permission::Granted
            } else {
                Permission::Unsupported
            },
        })
    }
    fn request_permission(&mut self, _kind: PermissionKind) -> R<Permissions> {
        self.permissions()
    }
    fn invalidate(&mut self) {
        self.elements.clear();
        self.observed = None;
    }
    fn call(&mut self, call: NativeCall, permit: &Permit) -> R<NativeResult> {
        permit.check()?;
        desktop_guard()?;
        let _dpi = ThreadDpi::open()?;
        match call {
            NativeCall::ListApps => {
                let mut seen = BTreeSet::new();
                let rows = self
                    .list(permit)?
                    .into_iter()
                    .filter(|w| seen.insert(w.process.pid))
                    .map(|w| json!({"pid":w.process.pid,"name":w.process.name,"bundle_id":""}))
                    .collect::<Vec<_>>();
                Ok(NativeResult::Data(json!(rows)))
            }
            NativeCall::ListWindows(pid) => {
                let mut rows = vec![];
                for window in self
                    .list(permit)?
                    .into_iter()
                    .filter(|w| pid.is_none_or(|pid| pid as u32 == w.process.pid))
                {
                    permit.check()?;
                    let (bounds, dpi) = window.geometry()?;
                    let mut title = [0u16; 512];
                    let length = unsafe { GetWindowTextW(window.hwnd, &mut title) }.max(0) as usize;
                    rows.push(json!({"pid":window.process.pid,"window_id":window.id,"title":String::from_utf16_lossy(&title[..length]),"x":bounds[0],"y":bounds[1],"width":f64::from(bounds[2]-bounds[0])*96.0/f64::from(dpi),"height":f64::from(bounds[3]-bounds[1])*96.0/f64::from(dpi)}));
                }
                Ok(NativeResult::Data(json!(rows)))
            }
            NativeCall::Observe {
                pid,
                window,
                limit,
                screenshot,
            } => self.observe(self.window(pid, window)?, limit, screenshot, permit),
            NativeCall::Press { native: id } => {
                let element = &self.element(id, permit)?.element;
                // Pattern discovery never performs input. Choose exactly one
                // typed action; an error after dispatch is never retried as a
                // different pattern or a coordinate click.
                let action = if let Ok(pattern) = unsafe {
                    element.GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId)
                } {
                    ClickPattern::Invoke(pattern)
                } else if let Ok(pattern) = unsafe {
                    element.GetCurrentPatternAs::<IUIAutomationTogglePattern>(UIA_TogglePatternId)
                } {
                    ClickPattern::Toggle(pattern)
                } else if let Ok(pattern) = unsafe {
                    element.GetCurrentPatternAs::<IUIAutomationSelectionItemPattern>(
                        UIA_SelectionItemPatternId,
                    )
                } {
                    ClickPattern::Select(pattern)
                } else if let Ok(pattern) = unsafe {
                    element.GetCurrentPatternAs::<IUIAutomationExpandCollapsePattern>(
                        UIA_ExpandCollapsePatternId,
                    )
                } {
                    let state = native(unsafe { pattern.CurrentExpandCollapseState() })?;
                    if state != ExpandCollapseState_Collapsed
                        && state != ExpandCollapseState_Expanded
                    {
                        return Err(Failure::Unsupported);
                    }
                    ClickPattern::Expand(pattern, state)
                } else {
                    return Err(Failure::Unsupported);
                };
                self.element(id, permit)?;
                if let ClickPattern::Expand(pattern, state) = &action {
                    if native(unsafe { pattern.CurrentExpandCollapseState() })? != *state {
                        return Err(Failure::StaleObservation);
                    }
                }
                permit.check()?;
                desktop_guard()?;
                permit.check()?;
                action.dispatch()?;
                Ok(NativeResult::Done)
            }
            NativeCall::SetValue { native: id, text } => {
                let element = &self.element(id, permit)?.element;
                let pattern = native(unsafe {
                    element.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
                })?;
                if native(unsafe { pattern.CurrentIsReadOnly() })?.as_bool() {
                    return Err(Failure::PermissionDenied);
                }
                let text = BSTR::from(text.as_str());
                self.element(id, permit)?;
                permit.check()?;
                desktop_guard()?;
                permit.check()?;
                native(unsafe { pattern.SetValue(&text) })?;
                Ok(NativeResult::Done)
            }
            NativeCall::Key { native: id, key } => {
                let binding = self.element(id, permit)?;
                permit.check()?;
                native(unsafe { binding.element.SetFocus() })?;
                let automation = &self.context.as_ref().ok_or(Failure::Native)?.automation;
                let focused = native(unsafe { automation.GetFocusedElement() })?;
                if !native(unsafe { automation.CompareElements(&focused, &binding.element) })?
                    .as_bool()
                {
                    return Err(Failure::StaleObservation);
                }
                self.element(id, permit)?;
                no_modifiers()?;
                permit.check()?;
                desktop_guard()?;
                permit.check()?;
                send_key(key)?;
                Ok(NativeResult::Done)
            }
            NativeCall::Point { pid, window, x, y } => {
                let observed = self
                    .observed
                    .as_ref()
                    .filter(|o| {
                        o.screenshot && o.window.id == window && o.window.process.pid == pid as u32
                    })
                    .ok_or(Failure::StaleObservation)?;
                if observed.window.geometry()? != (observed.bounds, observed.dpi) {
                    return Err(Failure::StaleObservation);
                }
                let (px, py) = policy::point(observed.bounds, observed.dpi, x, y)
                    .ok_or(Failure::InvalidRequest)?;
                let automation = &self.context.as_ref().ok_or(Failure::Native)?.automation;
                password_guard(automation, &observed.window, true, permit)?;
                let hit = unsafe {
                    WindowFromPoint(::windows::Win32::Foundation::POINT { x: px, y: py })
                };
                if unsafe { GetAncestor(hit, GA_ROOT) } != observed.window.hwnd {
                    return Err(Failure::StaleObservation);
                }
                let hit_element = native(unsafe {
                    automation
                        .ElementFromPoint(::windows::Win32::Foundation::POINT { x: px, y: py })
                })?;
                if native(unsafe { hit_element.CurrentProcessId() })? != pid
                    || native(unsafe { hit_element.CurrentIsPassword() })?.as_bool()
                {
                    return Err(Failure::PermissionDenied);
                }
                no_modifiers()?;
                permit.check()?;
                desktop_guard()?;
                permit.check()?;
                send_point(px, py)?;
                Ok(NativeResult::Done)
            }
        }
    }
}
// Fields containing COM references must be dropped before Context's CoUninitialize.
impl Drop for NativeBackend {
    fn drop(&mut self) {
        self.invalidate();
        self.windows.clear();
        self.context.take();
    }
}
fn password_guard(
    automation: &IUIAutomation,
    window: &WindowBinding,
    activate: bool,
    permit: &Permit,
) -> R<()> {
    window.verify()?;
    permit.check()?;
    desktop_guard()?;
    if activate && unsafe { GetForegroundWindow() } != window.hwnd {
        permit.check()?;
        if !unsafe { SetForegroundWindow(window.hwnd) }.as_bool() {
            return Err(Failure::PermissionDenied);
        }
    }
    if unsafe { GetForegroundWindow() } != window.hwnd {
        return Err(Failure::StaleObservation);
    }
    let focused = native(unsafe { automation.GetFocusedElement() })?;
    if native(unsafe { focused.CurrentProcessId() })? != window.process.pid as i32
        || native(unsafe { focused.CurrentIsPassword() })?.as_bool()
    {
        return Err(Failure::PermissionDenied);
    }
    window.verify()?;
    permit.check()
}
fn desktop_guard() -> R<()> {
    struct Owned(Option<HDESK>);
    impl Owned {
        fn close(&mut self) -> R<()> {
            if let Some(handle) = self.0 {
                native(unsafe { CloseDesktop(handle) })?;
                self.0 = None;
            }
            Ok(())
        }
    }
    impl Drop for Owned {
        fn drop(&mut self) {
            let _ = self.close();
        }
    }
    fn name(desk: HDESK) -> R<Vec<u16>> {
        let mut value = [0u16; 512];
        let mut needed = 0;
        native(unsafe {
            GetUserObjectInformationW(
                HANDLE(desk.0),
                UOI_NAME,
                Some(value.as_mut_ptr().cast()),
                std::mem::size_of_val(&value) as u32,
                Some(&mut needed),
            )
        })?;
        if needed < 2 || needed as usize > std::mem::size_of_val(&value) || needed % 2 != 0 {
            return Err(Failure::Native);
        }
        let length = value.iter().position(|v| *v == 0).ok_or(Failure::Native)?;
        if length == 0 {
            return Err(Failure::PermissionDenied);
        }
        Ok(value[..length].to_vec())
    }
    // Never change a thread/input desktop. Opening only READOBJECTS fails on
    // the secure desktop; compare against this worker's borrowed desktop.
    let mut input = Owned(Some(
        unsafe { OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_READOBJECTS) }
            .map_err(|_| Failure::PermissionDenied)?,
    ));
    let current = native(unsafe { GetThreadDesktop(GetCurrentThreadId()) })?;
    let same = name(input.0.ok_or(Failure::Native)?)? == name(current)?;
    input.close()?;
    if same {
        Ok(())
    } else {
        Err(Failure::PermissionDenied)
    }
}
fn runtime_id(element: &IUIAutomationElement) -> R<Vec<i32>> {
    struct Array(*mut SAFEARRAY);
    impl Drop for Array {
        fn drop(&mut self) {
            unsafe { SafeArrayDestroy(self.0) }.ok();
        }
    }
    let array = Array(native(unsafe { element.GetRuntimeId() })?);
    if array.0.is_null()
        || unsafe { SafeArrayGetDim(array.0) } != 1
        || native(unsafe { SafeArrayGetVartype(array.0) })?.0 != 3
    {
        return Err(Failure::Native);
    }
    let lower = native(unsafe { SafeArrayGetLBound(array.0, 1) })?;
    let upper = native(unsafe { SafeArrayGetUBound(array.0, 1) })?;
    let length = i64::from(upper) - i64::from(lower) + 1;
    if !(1..=64).contains(&length) {
        return Err(Failure::TooLarge);
    }
    let mut data = std::ptr::null_mut();
    native(unsafe { SafeArrayAccessData(array.0, &mut data) })?;
    if data.is_null() {
        unsafe { SafeArrayUnaccessData(array.0) }.ok();
        return Err(Failure::Native);
    }
    // SAFETY: validated one-dimensional VT_I4 SAFEARRAY, non-null and <=64 entries.
    let value = unsafe { std::slice::from_raw_parts(data.cast::<i32>(), length as usize) }.to_vec();
    native(unsafe { SafeArrayUnaccessData(array.0) })?;
    Ok(value)
}
fn no_modifiers() -> R<()> {
    if [
        VK_CONTROL, VK_SHIFT, VK_MENU, VK_LWIN, VK_RWIN, VK_LBUTTON, VK_RBUTTON, VK_MBUTTON,
    ]
    .iter()
    .any(|key| unsafe { GetAsyncKeyState(key.0 as i32) } < 0)
    {
        Err(Failure::Busy)
    } else {
        Ok(())
    }
}
fn send_key(key: Key) -> R<()> {
    let key = match key {
        Key::Enter => VK_RETURN,
        Key::Escape => VK_ESCAPE,
        Key::Tab => VK_TAB,
        Key::Backspace => VK_BACK,
        Key::Left => VK_LEFT,
        Key::Right => VK_RIGHT,
        Key::Up => VK_UP,
        Key::Down => VK_DOWN,
    };
    if unsafe { GetAsyncKeyState(key.0 as i32) } < 0 {
        return Err(Failure::Busy);
    }
    let inputs = [
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: key,
                    ..Default::default()
                },
            },
        },
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: key,
                    dwFlags: KEYEVENTF_KEYUP,
                    ..Default::default()
                },
            },
        },
    ];
    let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
    if sent != inputs.len() as u32 {
        // Only undo a down-event that this batch actually inserted. Never
        // retry the action; Broker consumes its observation on this failure.
        if sent == 1 {
            unsafe { SendInput(&inputs[1..], std::mem::size_of::<INPUT>() as i32) };
        }
        return Err(Failure::PermissionDenied);
    }
    Ok(())
}
fn send_point(x: i32, y: i32) -> R<()> {
    let (left, top, width, height) = unsafe {
        (
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN),
            GetSystemMetrics(SM_CXVIRTUALSCREEN),
            GetSystemMetrics(SM_CYVIRTUALSCREEN),
        )
    };
    if width <= 1 || height <= 1 {
        return Err(Failure::Native);
    }
    let dx = ((i64::from(x) - i64::from(left)) * 65535 / i64::from(width - 1)) as i32;
    let dy = ((i64::from(y) - i64::from(top)) * 65535 / i64::from(height - 1)) as i32;
    if !(0..=65535).contains(&dx) || !(0..=65535).contains(&dy) {
        return Err(Failure::StaleObservation);
    }
    let inputs = [
        INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dx,
                    dy,
                    dwFlags: MOUSEEVENTF_MOVE
                        | MOUSEEVENTF_ABSOLUTE
                        | MOUSEEVENTF_VIRTUALDESK
                        | MOUSEEVENTF_LEFTDOWN,
                    ..Default::default()
                },
            },
        },
        INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dwFlags: MOUSEEVENTF_LEFTUP,
                    ..Default::default()
                },
            },
        },
    ];
    let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
    if sent != inputs.len() as u32 {
        // Only undo a down-event that this batch actually inserted. Never
        // retry the action; Broker consumes its observation on this failure.
        if sent == 1 {
            unsafe { SendInput(&inputs[1..], std::mem::size_of::<INPUT>() as i32) };
        }
        return Err(Failure::PermissionDenied);
    }
    Ok(())
}
enum ClickPattern {
    Invoke(IUIAutomationInvokePattern),
    Toggle(IUIAutomationTogglePattern),
    Select(IUIAutomationSelectionItemPattern),
    Expand(IUIAutomationExpandCollapsePattern, ExpandCollapseState),
}
impl ClickPattern {
    fn dispatch(self) -> R<()> {
        match self {
            Self::Invoke(pattern) => native(unsafe { pattern.Invoke() }),
            Self::Toggle(pattern) => native(unsafe { pattern.Toggle() }),
            Self::Select(pattern) => native(unsafe { pattern.Select() }),
            Self::Expand(pattern, ExpandCollapseState_Collapsed) => {
                native(unsafe { pattern.Expand() })
            }
            Self::Expand(pattern, _) => native(unsafe { pattern.Collapse() }),
        }
    }
}
struct FrameOwner {
    sender: SyncSender<anyhow::Result<(Vec<u8>, u32, u32)>>,
}
impl GraphicsCaptureApiHandler for FrameOwner {
    type Flags = SyncSender<anyhow::Result<(Vec<u8>, u32, u32)>>;
    type Error = anyhow::Error;
    fn new(context: CaptureContext<Self::Flags>) -> anyhow::Result<Self> {
        Ok(Self {
            sender: context.flags,
        })
    }
    fn on_frame_arrived(
        &mut self,
        frame: &mut Frame,
        control: InternalCaptureControl,
    ) -> anyhow::Result<()> {
        let result = (|| {
            let (width, height) = (frame.width(), frame.height());
            anyhow::ensure!(
                width > 0
                    && height > 0
                    && width <= 8192
                    && height <= 8192
                    && u64::from(width) * u64::from(height) <= 4_000_000,
                "Window exceeds Computer Use capture bounds"
            );
            let mut buffer = frame.buffer()?;
            let rgba = buffer.as_nopadding_buffer()?.to_vec();
            let png = coincide_core::appshots::encode_rgba(width, height, rgba)?;
            anyhow::ensure!(
                png.len() <= 2_500_000,
                "Window capture exceeds result bound"
            );
            Ok((png, width, height))
        })();
        let _ = self.sender.try_send(result);
        control.stop();
        Ok(())
    }
}
fn capture(window: &WindowBinding, permit: &Permit) -> R<Image> {
    window.verify()?;
    permit.check()?;
    let (tx, rx) = mpsc::sync_channel(1);
    let target = Window::from_raw_hwnd(window.hwnd.0);
    let settings = Settings::new(
        target,
        CursorCaptureSettings::WithoutCursor,
        DrawBorderSettings::WithBorder,
        SecondaryWindowSettings::Exclude,
        MinimumUpdateIntervalSettings::Default,
        DirtyRegionSettings::Default,
        ColorFormat::Rgba8,
        tx,
    );
    let control = FrameOwner::start_free_threaded(settings).map_err(|_| Failure::Native)?;
    let deadline = Instant::now() + Duration::from_secs(2);
    let result = loop {
        if let Err(error) = checked(permit, deadline) {
            break Err(error);
        }
        match rx.recv_timeout(Duration::from_millis(20)) {
            Ok(value) => break value.map_err(|_| Failure::Native),
            Err(mpsc::RecvTimeoutError::Disconnected) => break Err(Failure::Native),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
    };
    // Own the real join handle ourselves: upstream stop() can return early
    // on a PostThreadMessage failure and drop/detach its thread handle.
    control.halt_handle().store(true, Ordering::Release);
    let worker = control.into_thread_handle();
    let thread_id = unsafe { GetThreadId(HANDLE(worker.as_raw_handle())) };
    let returned = super::capture_owner::join_after_stop(worker, || {
        unsafe {
            PostThreadMessageW(
                thread_id,
                WM_QUIT,
                ::windows::Win32::Foundation::WPARAM(0),
                LPARAM(0),
            )
        }
        .or_else(|error| {
            // The one-frame callback may already have ended its message loop.
            // Missing queue is harmless only because the owned join below
            // still waits for the actual thread/TLS return and checks its result.
            if error.code() == ::windows::core::HRESULT::from_win32(1444) {
                Ok(())
            } else {
                Err(error)
            }
        })
        .map_err(|_| ())
    })
    .map_err(|_| Failure::Native)?;
    returned.map_err(|_| Failure::Native)?;
    permit.check()?;
    window.verify()?;
    let (png, width, height) = result?;
    Ok(Image {
        png_base64: base64::engine::general_purpose::STANDARD.encode(png),
        width,
        height,
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn constructor_is_inert_and_has_no_native_handles() {
        let backend = super::NativeBackend::default();
        assert!(backend.context.is_none());
        assert!(backend.windows.is_empty());
        assert!(backend.elements.is_empty());
        assert!(backend.observed.is_none());
    }
}
