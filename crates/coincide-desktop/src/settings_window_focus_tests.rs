use gpui_kit::{
    AppContext, Context, FocusHandle, InputEvent, IntoElement, KeyDownEvent, KeyUpEvent, Keystroke,
    Render, TestAppContext, Window, WindowOptions, div, prelude::*,
};
use std::sync::atomic::Ordering;

struct FocusProbe {
    focus: FocusHandle,
}
impl Render for FocusProbe {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .track_focus(&self.focus)
            .child("Focus probe")
    }
}

#[gpui_kit::test]
#[ignore = "invoked by private_settings_close_focus_child with an isolated HOME"]
fn headless_settings_close_returns_focus_and_global_quit(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let quit = cx.update(crate::app_menu::install);
    // This existing regression checks ordinary immediate Quit with the opt-out;
    // the default-on hold/double-press paths have their own all-window fixture.
    cx.update(|cx| crate::quit_shortcut::configure(&serde_json::json!({"holdToQuit":false}), cx));
    let (main, main_view) = cx.update(|cx| {
        gpui_kit::open_window(WindowOptions::default(), cx, |_, cx| {
            cx.new(|cx| FocusProbe {
                focus: cx.focus_handle(),
            })
        })
        .unwrap()
    });
    let main_focus = cx.read(|cx| main_view.read(cx).focus.clone());
    let (settings, settings_view) = cx.update(|cx| {
        gpui_kit::open_window(WindowOptions::default(), cx, |_, cx| {
            cx.new(|cx| FocusProbe {
                focus: cx.focus_handle(),
            })
        })
        .unwrap()
    });
    cx.update_window(main, |_, window, cx| {
        window.refresh();
        window.draw(cx).clear(cx);
        window.blur(cx);
    })
    .unwrap();
    cx.update_window(settings, |_, window, cx| {
        window.refresh();
        window.draw(cx).clear(cx);
        let settings_focus = settings_view.read(cx).focus.clone();
        settings_focus.focus(window, cx);
        super::return_focus_to_main(main, main_focus.clone(), cx);
        window.remove_window();
    })
    .unwrap();
    cx.run_until_parked();
    assert!(cx.update_window(settings, |_, _, _| {}).is_err());
    cx.update_window(main, |_, window, cx| {
        window.refresh();
        window.draw(cx).clear(cx);
        assert!(
            main_focus.is_focused(window),
            "Closing Settings must restore the main focus tree"
        );
        let key = if cfg!(target_os = "macos") {
            "cmd-q"
        } else {
            "ctrl-q"
        };
        let keystroke = Keystroke::parse_with_os(key, cx.platform_info().os).unwrap();
        window.dispatch_event(
            KeyDownEvent {
                keystroke: keystroke.clone(),
                is_held: false,
                prefer_character_input: false,
            }
            .to_platform_input(),
            cx,
        );
        window.dispatch_event(KeyUpEvent { keystroke }.to_platform_input(), cx);
    })
    .unwrap();
    assert!(
        quit.load(Ordering::Acquire),
        "The ordinary global Quit binding must reach the application after Settings closes"
    );
    cx.update_window(main, |_, window, _| window.remove_window())
        .unwrap();
    cx.run_until_parked();
}

#[::core::prelude::v1::test]
fn private_settings_close_focus_child() {
    let fixture =
        std::env::temp_dir().join(format!("coincide-settings-focus-{}", uuid::Uuid::new_v4()));
    coincide_core::native_file::private_directory(&fixture).unwrap();
    let home = fixture.join("private-home");
    coincide_core::native_file::private_directory(&home).unwrap();
    let mut command = std::process::Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--ignored",
            "--exact",
            "settings_window::focus_tests::headless_settings_close_returns_focus_and_global_quit",
            "--nocapture",
            "--test-threads=1",
        ])
        .env_clear()
        .env("HOME", &home)
        .env("USERPROFILE", &home)
        .env("TMPDIR", &home)
        .env("TMP", &home)
        .env("TEMP", &home)
        .env("PATH", "")
        .env("LANG", "en_US.UTF-8")
        .current_dir(&home);
    #[cfg(windows)]
    for key in ["SystemRoot", "WINDIR"] {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    let output = command.output().unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "Private focus child failed\n{stdout}\n{stderr}"
    );
    assert!(
        stdout.contains("1 passed"),
        "The actual headless focus/keyboard case must run\n{stdout}\n{stderr}"
    );
    std::fs::remove_dir_all(&fixture).unwrap();
}
