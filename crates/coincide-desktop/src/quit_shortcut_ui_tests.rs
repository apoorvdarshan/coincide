//! TestPlatform only: no Coincide constructor, platform quit, OS hook or user data.
use super::super::{Gate, configure};
use gpui_kit::{
    App, AppContext, Context, Entity, Focusable, InputEvent, IntoElement, KeyDownEvent, KeyUpEvent,
    Keystroke, ParentElement, Render, Styled, TestAppContext, Window, WindowOptions,
    component::input::{Textarea, TextareaState},
    div,
};
use serde_json::json;
use std::{sync::atomic::Ordering, time::Duration};
const CHILD: &str = "COINCIDE_HEADLESS_QUIT_SHORTCUT_CHILD";
struct Harness {
    input: Entity<TextareaState>,
}
impl Render for Harness {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(Textarea::new(&self.input))
    }
}
fn draw(window: &mut Window, cx: &mut App) {
    window.refresh();
    window.draw(cx).clear(cx);
}
fn down(window: &mut Window, cx: &mut App, repeat: bool) {
    let key = if cfg!(target_os = "macos") {
        "cmd-q"
    } else {
        "ctrl-q"
    };
    let keystroke = Keystroke::parse_with_os(key, cx.platform_info().os).unwrap();
    window.set_modifiers(keystroke.modifiers);
    window.dispatch_event(
        KeyDownEvent {
            keystroke,
            is_held: repeat,
            prefer_character_input: false,
        }
        .to_platform_input(),
        cx,
    );
    draw(window, cx);
}
fn up(window: &mut Window, cx: &mut App) {
    let key = if cfg!(target_os = "macos") {
        "cmd-q"
    } else {
        "ctrl-q"
    };
    let keystroke = Keystroke::parse_with_os(key, cx.platform_info().os).unwrap();
    window.dispatch_event(KeyUpEvent { keystroke }.to_platform_input(), cx);
    draw(window, cx);
}
#[gpui_kit::test]
#[ignore = "private-child wrapper only"]
fn headless_actual_prebinding_hold_repeat_release_and_menu_distinction(cx: &mut TestAppContext) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    cx.update(gpui_kit::init);
    let quit = cx.update(crate::app_menu::install);
    let (main, main_view) = cx.update(|cx| {
        gpui_kit::open_window(WindowOptions::default(), cx, |window, cx| {
            cx.new(|cx| Harness {
                input: cx.new(|cx| TextareaState::new(window, cx)),
            })
        })
        .unwrap()
    });
    let (settings, settings_view) = cx.update(|cx| {
        gpui_kit::open_window(WindowOptions::default(), cx, |window, cx| {
            cx.new(|cx| Harness {
                input: cx.new(|cx| TextareaState::new(window, cx)),
            })
        })
        .unwrap()
    });
    let input = cx.read(|cx| main_view.read(cx).input.clone());
    cx.update_window(main, |_, window, cx| {
        window.activate_window();
        input.read(cx).focus_handle(cx).focus(window, cx);
        draw(window, cx);
    })
    .unwrap();
    // TestPlatform posts the actual activation notification on its foreground
    // executor (platform/test/platform.rs set_active_window); deliver that
    // event before exercising the product's active-window admission guard.
    cx.run_until_parked();
    cx.update_window(main, |_, window, cx| {
        assert!(
            window.is_window_active(),
            "fixture must deliver actual platform activation first"
        );
        down(window, cx, false);
    })
    .unwrap();
    assert!(
        !quit.load(Ordering::Acquire),
        "default first key must be intercepted before existing global Quit binding"
    );
    assert!(cx.read(|cx| cx.global::<Gate>().decision.shows_hint()));
    cx.update_window(main, |_, window, cx| down(window, cx, true))
        .unwrap();
    assert!(
        !quit.load(Ordering::Acquire),
        "actual repeated key is not a second press"
    );
    cx.update_window(main, |_, window, cx| up(window, cx))
        .unwrap();
    cx.update_window(main, |_, window, cx| down(window, cx, false))
        .unwrap();
    assert!(
        quit.swap(false, Ordering::AcqRel),
        "release and actual nonrepeat within1.5s admits only one request"
    );
    cx.update_window(main, |_, window, cx| down(window, cx, true))
        .unwrap();
    assert!(
        !quit.load(Ordering::Acquire),
        "holding through an unsaved-editor decision never reissues Quit"
    );
    cx.update_window(main, |_, window, cx| up(window, cx))
        .unwrap();
    // New hold uses the real executor's virtual monotonic clock: no sleep/retry.
    cx.update_window(main, |_, window, cx| down(window, cx, false))
        .unwrap();
    cx.executor().advance_clock(Duration::from_secs(1));
    cx.update_window(main, |_, window, cx| draw(window, cx))
        .unwrap();
    assert!(
        quit.swap(false, Ordering::AcqRel),
        "hold threshold admits the same signal as normal Quit"
    );
    assert_eq!(cx.read(|cx| input.read(cx).value().to_string()), "");
    cx.update_window(main, |_, window, cx| {
        assert!(input.read(cx).focus_handle(cx).is_focused(window));
        up(window, cx);
    })
    .unwrap();
    // Every actual Root gets release handling and a presentation HUD.
    let settings_input = cx.read(|cx| settings_view.read(cx).input.clone());
    cx.update_window(settings, |_, window, cx| {
        window.activate_window();
        settings_input.read(cx).focus_handle(cx).focus(window, cx);
        draw(window, cx);
    })
    .unwrap();
    // TestPlatform posts the actual activation notification on its foreground
    // executor (platform/test/platform.rs set_active_window); deliver that
    // event before exercising the product's active-window admission guard.
    cx.run_until_parked();
    cx.update_window(settings, |_, window, cx| {
        assert!(
            window.is_window_active(),
            "fixture must deliver actual platform activation first"
        );
        down(window, cx, false);
    })
    .unwrap();
    assert!(!quit.load(Ordering::Acquire));
    assert!(cx.read(|cx| cx.global::<Gate>().decision.shows_hint()));
    cx.update_window(settings, |_, window, cx| up(window, cx))
        .unwrap();
    cx.update_window(settings, |_, window, cx| down(window, cx, false))
        .unwrap();
    assert!(quit.swap(false, Ordering::AcqRel));
    cx.update(|cx| configure(&json!({"holdToQuit":false}), cx));
    cx.update_window(settings, |_, window, cx| down(window, cx, false))
        .unwrap();
    assert!(
        quit.swap(false, Ordering::AcqRel),
        "explicit off keeps ordinary immediate binding"
    );
    cx.update(|cx| configure(&json!({"holdToQuit":true}), cx));
    // Native menu callbacks enter App outside a borrowed window. Dispatching
    // App::dispatch_action from update_window would try to borrow that active
    // window twice; Window::dispatch_action then defers its focused delivery.
    cx.update(|cx| cx.dispatch_action(&crate::app_menu::Quit));
    cx.run_until_parked();
    assert!(
        quit.swap(false, Ordering::AcqRel),
        "menu Quit bypasses keyboard hold but uses retained normal signal"
    );
    assert!(!cx.read(|cx| cx.global::<Gate>().decision.shows_hint()));
    cx.update_window(settings, |_, window, _| window.remove_window())
        .unwrap();
    cx.update_window(main, |_, window, _| window.remove_window())
        .unwrap();
}
#[gpui_kit::test]
#[ignore = "private-child wrapper only"]
fn headless_focus_modifier_and_disable_cancel_without_later_quit(cx: &mut TestAppContext) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    cx.update(gpui_kit::init);
    let quit = cx.update(crate::app_menu::install);
    let (first, _) = cx.update(|cx| {
        gpui_kit::open_window(WindowOptions::default(), cx, |window, cx| {
            cx.new(|cx| Harness {
                input: cx.new(|cx| TextareaState::new(window, cx)),
            })
        })
        .unwrap()
    });
    let (other, _) = cx.update(|cx| {
        gpui_kit::open_window(WindowOptions::default(), cx, |window, cx| {
            cx.new(|cx| Harness {
                input: cx.new(|cx| TextareaState::new(window, cx)),
            })
        })
        .unwrap()
    });
    cx.update_window(first, |_, window, cx| {
        window.activate_window();
        draw(window, cx);
    })
    .unwrap();
    // TestPlatform posts the actual activation notification on its foreground
    // executor (platform/test/platform.rs set_active_window); deliver that
    // event before exercising the product's active-window admission guard.
    cx.run_until_parked();
    cx.update_window(first, |_, window, cx| {
        assert!(
            window.is_window_active(),
            "fixture must deliver actual platform activation first"
        );
        down(window, cx, false);
    })
    .unwrap();
    assert!(cx.read(|cx| cx.global::<Gate>().decision.shows_hint()));
    cx.update_window(other, |_, window, cx| {
        window.activate_window();
        draw(window, cx);
    })
    .unwrap();
    cx.run_until_parked();
    assert!(
        !cx.read(|cx| cx.global::<Gate>().decision.shows_hint()),
        "changing actual active native window cancels its old hold"
    );
    cx.executor().advance_clock(Duration::from_secs(2));
    cx.update_window(first, |_, window, cx| draw(window, cx))
        .unwrap();
    assert!(!quit.load(Ordering::Acquire));
    cx.update_window(first, |_, window, cx| {
        window.activate_window();
        draw(window, cx);
    })
    .unwrap();
    // TestPlatform posts the actual activation notification on its foreground
    // executor (platform/test/platform.rs set_active_window); deliver that
    // event before exercising the product's active-window admission guard.
    cx.run_until_parked();
    cx.update_window(first, |_, window, cx| {
        assert!(
            window.is_window_active(),
            "fixture must deliver actual platform activation first"
        );
        down(window, cx, false);
    })
    .unwrap();
    cx.update_window(first, |_, window, cx| {
        window.dispatch_event(
            gpui_kit::ModifiersChangedEvent::default().to_platform_input(),
            cx,
        );
        draw(window, cx);
    })
    .unwrap();
    cx.executor().advance_clock(Duration::from_secs(2));
    cx.update_window(first, |_, window, cx| draw(window, cx))
        .unwrap();
    assert!(
        !quit.load(Ordering::Acquire),
        "primary release before threshold cancels the continuous hold"
    );
    assert!(
        !cx.read(|cx| cx.global::<Gate>().decision.shows_hint()),
        "double-press opportunity expires"
    );
    cx.update_window(first, |_, window, cx| down(window, cx, false))
        .unwrap();
    cx.update(|cx| configure(&json!({"holdToQuit":false}), cx));
    assert!(!cx.read(|cx| cx.global::<Gate>().decision.shows_hint()));
    cx.executor().advance_clock(Duration::from_secs(2));
    cx.update_window(first, |_, window, cx| draw(window, cx))
        .unwrap();
    assert!(
        !quit.load(Ordering::Acquire),
        "disabling a pending hint never admits Quit"
    );
    cx.update_window(other, |_, window, _| window.remove_window())
        .unwrap();
    cx.update_window(first, |_, window, _| window.remove_window())
        .unwrap();
}
#[::core::prelude::v1::test]
fn private_actual_quit_shortcut_child() {
    use std::{fs, process::Command};
    let root = std::env::temp_dir().join(format!(
        "coincide-quit-shortcut-fixture-{}",
        uuid::Uuid::new_v4()
    ));
    fs::create_dir(&root).unwrap();
    for name in ["home", "tmp", "empty-path"] {
        fs::create_dir(root.join(name)).unwrap();
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    }
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "quit_shortcut::tests::native::headless_",
            "--nocapture",
            "--test-threads=1",
        ])
        .env_clear()
        .env(CHILD, "1")
        .env("HOME", root.join("home"))
        .env("TMPDIR", root.join("tmp"))
        .env("PATH", root.join("empty-path"))
        .env("LANG", "en_US.UTF-8")
        .current_dir(&root)
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success() && stdout.contains("2 passed"),
        "actual GPUI quit child failed; fixture retained at {}\n{stdout}\n{stderr}",
        root.display()
    );
    fs::remove_dir_all(root).unwrap();
}
