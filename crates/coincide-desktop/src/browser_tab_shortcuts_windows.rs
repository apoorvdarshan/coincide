use super::*;
use webview2_com::{
    AcceleratorKeyPressedEventHandler, FocusChangedEventHandler,
    Microsoft::Web::WebView2::Win32::*, take_pwstr,
};
use windows::{
    Win32::UI::Input::KeyboardAndMouse::{
        GetKeyState, VK_CONTROL, VK_LWIN, VK_MENU, VK_RWIN, VK_SHIFT,
    },
    core::{BOOL, PWSTR},
};
use wry::WebViewExtWindows;
pub(super) struct Adapter {
    controller: ICoreWebView2Controller,
    token: Option<i64>,
    got: Option<i64>,
    lost: Option<i64>,
    focus: Arc<std::sync::atomic::AtomicBool>,
}
impl Adapter {
    pub fn focused(&self, _: &wry::WebView) -> bool {
        self.focus.load(Ordering::Acquire)
    }
    pub fn install(
        view: &wry::WebView,
        callbacks: &Callbacks,
        navigation: Arc<AtomicU64>,
        emit: impl Fn(Command, u64, Option<String>) -> bool + 'static,
    ) -> Result<Self> {
        let controller = view.controller();
        let focus = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let mut adapter = Self {
            controller: controller.clone(),
            token: None,
            got: None,
            lost: None,
            focus: focus.clone(),
        };
        for got in [true, false] {
            let focus = focus.clone();
            let lease = callbacks.lifetimes().block();
            let handler = FocusChangedEventHandler::create(Box::new(move |_, _| {
                let _held = &lease;
                focus.store(got, Ordering::Release);
                Ok(())
            }));
            let mut token = 0;
            if got {
                unsafe { controller.add_GotFocus(&handler, &mut token)? };
                adapter.got = Some(token);
            } else {
                unsafe { controller.add_LostFocus(&handler, &mut token)? };
                adapter.lost = Some(token);
            }
        }
        let native = view.webview();
        let block = callbacks.lifetimes().block();
        let handler =
            AcceleratorKeyPressedEventHandler::create(Box::new(move |controller, args| {
                let _held = &block;
                let epoch = navigation.load(Ordering::Acquire);
                let (Some(controller), Some(args)) = (controller, args) else {
                    return Ok(());
                };
                let mut visible = BOOL::default();
                unsafe { controller.IsVisible(&mut visible)? };
                if !visible.as_bool() {
                    return Ok(());
                }
                let mut kind = COREWEBVIEW2_KEY_EVENT_KIND::default();
                unsafe { args.KeyEventKind(&mut kind)? };
                if kind != COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN
                    && kind != COREWEBVIEW2_KEY_EVENT_KIND_SYSTEM_KEY_DOWN
                {
                    return Ok(());
                }
                let mut key = 0;
                unsafe { args.VirtualKey(&mut key)? };
                let key = match key {
                    0x54 => "t",
                    0x57 => "w",
                    0xdb => "[",
                    0xdd => "]",
                    _ => return Ok(()),
                };
                let down = |key| unsafe { GetKeyState(key) as u16 & 0x8000 != 0 };
                let Some(command) = shortcuts::recognize(
                    key,
                    down(VK_CONTROL.0.into()),
                    down(VK_LWIN.0.into()) || down(VK_RWIN.0.into()),
                    down(VK_MENU.0.into()),
                    down(VK_SHIFT.0.into()),
                ) else {
                    return Ok(());
                };
                let mut raw = PWSTR::null();
                let url = unsafe { native.Source(&mut raw) }
                    .ok()
                    .map(|_| take_pwstr(raw))
                    .filter(|url| url.len() <= 16384);
                if emit(command, epoch, url) {
                    unsafe { args.SetHandled(true)? };
                }
                Ok(())
            }));
        let mut token = 0;
        unsafe { controller.add_AcceleratorKeyPressed(&handler, &mut token)? };
        adapter.token = Some(token);
        Ok(adapter)
    }
}
impl Drop for Adapter {
    fn drop(&mut self) {
        if let Some(token) = self.token.take() {
            let _ = unsafe { self.controller.remove_AcceleratorKeyPressed(token) };
        }
        if let Some(token) = self.got.take() {
            let _ = unsafe { self.controller.remove_GotFocus(token) };
        }
        if let Some(token) = self.lost.take() {
            let _ = unsafe { self.controller.remove_LostFocus(token) };
        }
    }
}
