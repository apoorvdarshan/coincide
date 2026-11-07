use super::{Delivered, Phase};
use anyhow::{Context, Result, ensure};
use coincide_core::browser_protocol::keys::{KeyPress, Named};
use serde_json::{Value, json};
use webview2_com::{
    CallDevToolsProtocolMethodCompletedHandler, Microsoft::Web::WebView2::Win32::ICoreWebView2,
};
use windows::core::HSTRING;
use wry::WebViewExtWindows;
pub(super) struct Adapter {
    view: ICoreWebView2,
}
impl Adapter {
    pub(super) fn install(view: &wry::WebView) -> Result<Self> {
        Ok(Self {
            view: view.webview(),
        })
    }
    pub(super) fn dispatch(
        &self,
        key: &KeyPress,
        phase: Phase,
        finished: impl FnOnce(Result<Delivered>) + 'static,
    ) -> Result<()> {
        let payload = payload(key, phase)?;
        let target = self.view.clone();
        let retained = target.clone();
        let handler =
            CallDevToolsProtocolMethodCompletedHandler::create(Box::new(move |code, result| {
                let _actual_target = &retained;
                let response = (|| -> Result<Delivered> {
                    ensure!(code.is_ok(), "Native browser key command failed");
                    ensure!(
                        result.len() <= 65536,
                        "Native browser key acknowledgment too large"
                    );
                    let value: Value = serde_json::from_str(&result)
                        .context("Invalid native key acknowledgment")?;
                    ensure!(
                        value.is_object() && value.get("error").is_none(),
                        "Native browser rejected key command"
                    );
                    Ok(Delivered::Event)
                })();
                finished(response);
                Ok(())
            }));
        // The method is fixed and the payload comes only from the admitted
        // typed key. No caller can supply a CDP method or arbitrary JSON/script.
        unsafe {
            target.CallDevToolsProtocolMethod(
                &HSTRING::from("Input.dispatchKeyEvent"),
                &HSTRING::from(payload.to_string()),
                &handler,
            )?;
        }
        Ok(())
    }
}
fn payload(key: &KeyPress, phase: Phase) -> Result<Value> {
    let (name, code, vk) = match key.named {
        Some(Named::Enter) => ("Enter".into(), "Enter".into(), 13),
        Some(Named::Tab) => ("Tab".into(), "Tab".into(), 9),
        Some(Named::Space) => (" ".into(), "Space".into(), 32),
        Some(Named::Backspace) => ("Backspace".into(), "Backspace".into(), 8),
        Some(Named::Escape) => ("Escape".into(), "Escape".into(), 27),
        Some(Named::Delete) => ("Delete".into(), "Delete".into(), 46),
        Some(Named::Home) => ("Home".into(), "Home".into(), 36),
        Some(Named::End) => ("End".into(), "End".into(), 35),
        Some(Named::PageUp) => ("PageUp".into(), "PageUp".into(), 33),
        Some(Named::PageDown) => ("PageDown".into(), "PageDown".into(), 34),
        Some(Named::Left) => ("ArrowLeft".into(), "ArrowLeft".into(), 37),
        Some(Named::Right) => ("ArrowRight".into(), "ArrowRight".into(), 39),
        Some(Named::Up) => ("ArrowUp".into(), "ArrowUp".into(), 38),
        Some(Named::Down) => ("ArrowDown".into(), "ArrowDown".into(), 40),
        None => {
            let (code, vk) = if key.physical.is_ascii_alphabetic() {
                (
                    format!("Key{}", key.physical.to_ascii_uppercase() as char),
                    u32::from(key.physical.to_ascii_uppercase()),
                )
            } else if key.physical.is_ascii_digit() {
                (
                    format!("Digit{}", key.physical as char),
                    u32::from(key.physical),
                )
            } else {
                let (code, vk) = match key.physical {
                    b';' => ("Semicolon", 0xba),
                    b'=' => ("Equal", 0xbb),
                    b',' => ("Comma", 0xbc),
                    b'-' => ("Minus", 0xbd),
                    b'.' => ("Period", 0xbe),
                    b'/' => ("Slash", 0xbf),
                    b'`' => ("Backquote", 0xc0),
                    b'[' => ("BracketLeft", 0xdb),
                    b'\\' => ("Backslash", 0xdc),
                    b']' => ("BracketRight", 0xdd),
                    b'\'' => ("Quote", 0xde),
                    _ => anyhow::bail!("Unsupported native key"),
                };
                (code.into(), vk)
            };
            (key.characters.clone(), code, vk)
        }
    };
    let text = if phase == Phase::Down {
        key.page_text()
    } else {
        ""
    };
    let modifiers = (if key.meta || key.control { 2 } else { 0 }) | (if key.shift { 8 } else { 0 });
    let mut value = json!({"type":if phase==Phase::Up {"keyUp"} else if text.is_empty() {"rawKeyDown"} else {"keyDown"},"key":name,"code":code,"windowsVirtualKeyCode":vk,"nativeVirtualKeyCode":vk,"modifiers":modifiers,"autoRepeat":false,"isKeypad":false});
    if !text.is_empty() {
        value["text"] = json!(text);
        value["unmodifiedText"] = json!(if key.named.is_some() {
            text
        } else {
            &key.ignoring_modifiers
        });
    }
    Ok(value)
}
