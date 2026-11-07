use super::*;
use webview2_com::{
    AcceleratorKeyPressedEventHandler, Microsoft::Web::WebView2::Win32::*, take_pwstr,
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
    token: i64,
}
impl Adapter {
    pub fn install(
        view: &wry::WebView,
        callbacks: &Callbacks,
        navigation: Arc<AtomicU64>,
        emit: impl Fn(Command, u64, Option<String>) -> bool + 'static,
    ) -> Result<Self> {
        let controller = view.controller();
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
        Ok(Self { controller, token })
    }
}
impl Drop for Adapter {
    fn drop(&mut self) {
        let _ = unsafe { self.controller.remove_AcceleratorKeyPressed(self.token) };
    }
}
