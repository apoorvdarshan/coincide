use super::{Kind, Sink};
use anyhow::Result;
use webview2_com::{
    CoTaskMemPWSTR, Microsoft::Web::WebView2::Win32::*, ScriptDialogOpeningEventHandler,
};
use windows::core::{BOOL, PCWSTR, PWSTR};
use wry::WebViewExtWindows;

pub(super) struct Adapter {
    view: ICoreWebView2,
    token: i64,
    previous_default: BOOL,
}
impl Adapter {
    pub(super) fn install(view: &wry::WebView, sink: Sink) -> Result<Self> {
        let view = view.webview();
        unsafe {
            let settings = view.Settings()?;
            let mut previous_default = BOOL::default();
            settings.AreDefaultScriptDialogsEnabled(&mut previous_default)?;
            let mut token = 0;
            view.add_ScriptDialogOpening(
                &ScriptDialogOpeningEventHandler::create(Box::new(move |_, args| {
                    let Some(args) = args else { return Ok(()) };
                    let mut native_kind = COREWEBVIEW2_SCRIPT_DIALOG_KIND::default();
                    args.Kind(&mut native_kind)?;
                    let kind = match native_kind {
                        COREWEBVIEW2_SCRIPT_DIALOG_KIND_ALERT => Kind::Alert,
                        COREWEBVIEW2_SCRIPT_DIALOG_KIND_CONFIRM => Kind::Confirm,
                        COREWEBVIEW2_SCRIPT_DIALOG_KIND_PROMPT => Kind::Prompt,
                        COREWEBVIEW2_SCRIPT_DIALOG_KIND_BEFOREUNLOAD => Kind::BeforeUnload,
                        _ => return Ok(()),
                    };
                    let mut raw = PWSTR::null();
                    args.Message(&mut raw)?;
                    let message = CoTaskMemPWSTR::from(raw).to_string();
                    let text = if kind == Kind::Prompt {
                        let mut raw = PWSTR::null();
                        args.DefaultText(&mut raw)?;
                        Some(CoTaskMemPWSTR::from(raw).to_string())
                    } else {
                        None
                    };
                    let deferral = args.GetDeferral()?;
                    sink.open(kind, message, text, move |accept, text| {
                        // No Accept means cancel; Complete always releases the real
                        // WebView2 script continuation, including cancelled owners.
                        let action = (|| -> windows::core::Result<()> {
                            if accept {
                                if kind == Kind::Prompt {
                                    let wide: Vec<u16> = text
                                        .unwrap_or_default()
                                        .encode_utf16()
                                        .chain(Some(0))
                                        .collect();
                                    args.SetResultText(PCWSTR(wide.as_ptr()))?;
                                }
                                args.Accept()?;
                            }
                            Ok(())
                        })();
                        let completion = deferral.Complete();
                        action?;
                        completion?;
                        Ok(())
                    });
                    Ok(())
                })),
                &mut token,
            )?;
            if let Err(error) = settings.SetAreDefaultScriptDialogsEnabled(false) {
                let _ = view.remove_ScriptDialogOpening(token);
                return Err(error.into());
            }
            Ok(Self {
                view,
                token,
                previous_default,
            })
        }
    }
}
impl Drop for Adapter {
    fn drop(&mut self) {
        unsafe {
            let _ = self.view.remove_ScriptDialogOpening(self.token);
            if let Ok(settings) = self.view.Settings() {
                let _ = settings.SetAreDefaultScriptDialogsEnabled(self.previous_default.as_bool());
            }
        }
    }
}
