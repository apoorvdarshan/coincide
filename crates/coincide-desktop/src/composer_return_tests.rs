//! Exercise Return through a real GPUI textarea with Settings in a second
//! window. This fixture never opens Coincide's engine or personal data.
use crate::{chat_inspector, settings_window};
use gpui_kit::{
    App, Context, Entity, Focusable, InputEvent as _, IntoElement, KeyDownEvent, KeyUpEvent,
    Keystroke, Render, Subscription, TestAppContext, VisualTestContext, Window, WindowOptions,
    component::input::{InputEvent, Textarea, TextareaState},
    div,
    prelude::*,
    px,
};

struct SettingsProbe;
impl Render for SettingsProbe {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().child("Synthetic Settings window")
    }
}

struct ComposerProbe {
    input: Entity<TextareaState>,
    settings_open: bool,
    separate_settings: bool,
    pending_settings: bool,
    selected: bool,
    send_on_return: bool,
    sends: Vec<String>,
    _subscription: Subscription,
}
impl ComposerProbe {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let input = cx.new(|cx| TextareaState::new(window, cx).submit_on_enter(true));
        let subscription = cx.subscribe(&input, |this: &mut Self, input, event, cx| {
            let route = chat_inspector::ChatRoute {
                selected: this.selected,
                settings: settings_window::settings_rendered_inline(
                    this.settings_open,
                    this.separate_settings,
                    this.pending_settings,
                ),
                ..Default::default()
            };
            if chat_inspector::composer_enter_sends(event, this.send_on_return, route) {
                this.sends.push(input.read(cx).value().to_string());
            }
        });
        Self {
            input,
            settings_open: true,
            separate_settings: true,
            pending_settings: false,
            selected: true,
            send_on_return: true,
            sends: Vec::new(),
            _subscription: subscription,
        }
    }
}
impl Render for ComposerProbe {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .child(Textarea::new(&self.input).w_full().h(px(100.)))
    }
}

fn press(cx: &mut VisualTestContext, key: &str) {
    cx.update(|window, cx| {
        let keystroke = Keystroke::parse_with_os(key, cx.platform_info().os).unwrap();
        window.refresh();
        window.draw(cx).clear(cx);
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
    });
    cx.run_until_parked();
}

#[gpui_kit::test]
#[ignore = "invoked in an isolated HOME by composer_return_with_separate_settings"]
fn headless_return_with_settings_window(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let (_settings, _) = cx.update(|cx| {
        gpui_kit::open_window(WindowOptions::default(), cx, |_, cx| {
            cx.new(|_| SettingsProbe)
        })
        .unwrap()
    });
    let (view, vcx) = cx.add_window_view(ComposerProbe::new);
    vcx.update(|window, cx| {
        window.activate_window();
        view.update(cx, |this, cx| {
            this.input.update(cx, |input, cx| {
                input.set_value("synthetic draft", window, cx);
                input.focus(window, cx);
            });
        });
        window.refresh();
        window.draw(cx).clear(cx);
    });
    vcx.run_until_parked();

    press(vcx, "enter");
    view.read_with(vcx, |this, _| assert_eq!(this.sends, ["synthetic draft"]));

    // A retained composer must not submit while inline Settings hides it.
    view.update(vcx, |this, _| this.separate_settings = false);
    press(vcx, "enter");
    view.read_with(vcx, |this, _| assert_eq!(this.sends.len(), 1));

    // Closing Settings restores ordinary submission.
    view.update(vcx, |this, _| this.settings_open = false);
    press(vcx, "enter");
    view.read_with(vcx, |this, _| assert_eq!(this.sends.len(), 2));

    // No selected conversation means the retained editor must not submit.
    view.update(vcx, |this, _| this.selected = false);
    press(vcx, "enter");
    view.read_with(vcx, |this, _| assert_eq!(this.sends.len(), 2));

    // Respect the preference to use Return for a newline instead.
    vcx.update(|window, cx| {
        view.update(cx, |this, cx| {
            this.selected = true;
            this.send_on_return = false;
            this.input.update(cx, |input, cx| {
                input.set_value("synthetic draft", window, cx);
                input.set_submit_on_enter(false, cx);
            });
        });
    });
    press(vcx, "enter");
    view.read_with(vcx, |this, cx| {
        assert_eq!(this.sends.len(), 2);
        assert!(this.input.read(cx).value().contains('\n'));
    });

    // Shift-Return is a newline when Return submits.
    vcx.update(|window, cx| {
        view.update(cx, |this, cx| {
            this.send_on_return = true;
            this.input.update(cx, |input, cx| {
                input.set_value("synthetic draft", window, cx);
                input.set_submit_on_enter(true, cx);
            });
        });
    });
    press(vcx, "shift-enter");
    view.read_with(vcx, |this, cx| {
        assert_eq!(this.sends.len(), 2);
        assert!(this.input.read(cx).value().contains('\n'));
    });
}

#[::core::prelude::v1::test]
fn composer_return_with_separate_settings() {
    let home = tempfile::tempdir().unwrap();
    let mut command = std::process::Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--ignored",
            "--exact",
            "composer_return_tests::headless_return_with_settings_window",
            "--nocapture",
            "--test-threads=1",
        ])
        .env_clear()
        .env("HOME", home.path())
        .env("USERPROFILE", home.path())
        .env("TMPDIR", home.path())
        .env("TMP", home.path())
        .env("TEMP", home.path())
        .env("PATH", "")
        .env("LANG", "en_US.UTF-8")
        .current_dir(home.path());
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
        "Composer Return test failed\n{stdout}\n{stderr}"
    );
    assert!(
        stdout.contains("1 passed"),
        "Composer Return test did not run\n{stdout}\n{stderr}"
    );
}
