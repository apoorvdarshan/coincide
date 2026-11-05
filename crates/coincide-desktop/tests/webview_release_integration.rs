// Exercise the actual shared release implementation with GPUI Tasks, without
// constructing native windows or substituting receipt behavior.
extern crate gpui_kit as gpui;
#[path = "../../../vendor/gpui-webview/src/release.rs"]
mod release;
