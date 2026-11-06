use gpui_kit::{
    AppContext, Context, Entity, IntoElement, ParentElement, Render, Styled, TestAppContext,
    Window, WindowOptions, div,
};
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};
const CHILD: &str = "COINCIDE_MAIN_WINDOW_POLL_CHILD";
struct Owner {
    source: Arc<AtomicU64>,
    observed: u64,
}
impl Render for Owner {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .child(format!("revision {}", self.observed))
    }
}
struct Settings {
    owner: Entity<Owner>,
}
impl Render for Settings {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(self.owner.clone())
    }
}
#[gpui_kit::test]
#[ignore = "private-child wrapper only"]
fn shared_owner_keeps_polling_main_after_settings_closes(cx: &mut TestAppContext) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    cx.update(gpui_kit::init);
    let source = Arc::new(AtomicU64::new(1));
    let (main, owner) = cx.update(|cx| {
        gpui_kit::open_window(WindowOptions::default(), cx, |_, cx| {
            cx.new(|_| Owner {
                source: source.clone(),
                observed: 0,
            })
        })
        .unwrap()
    });
    let (settings, _) = cx.update(|cx| {
        gpui_kit::open_window(WindowOptions::default(), cx, |_, cx| {
            cx.new(|_| Settings {
                owner: owner.clone(),
            })
        })
        .unwrap()
    });
    cx.update_window(main, |_, window, cx| {
        window.refresh();
        window.draw(cx).clear(cx);
    })
    .unwrap();
    cx.update_window(settings, |_, window, cx| {
        window.refresh();
        window.draw(cx).clear(cx);
    })
    .unwrap();
    let weak = owner.downgrade();
    let latest = cx.update(|cx| {
        weak.update_in(cx, |_, window, _| window.window_handle())
            .unwrap()
    });
    assert_eq!(
        latest, settings,
        "fixture must actually migrate the shared owner's current window"
    );
    cx.update_window(settings, |_, window, _| window.remove_window())
        .unwrap();
    assert!(
        cx.update(|cx| weak.update_in(cx, |_, _, _| ())).is_err(),
        "old entity-window lookup must reproduce the stopped polling path"
    );
    source.store(42, Ordering::Release);
    cx.update(|cx| {
        super::update(main, &weak, cx, |owner, window, _| {
            assert_eq!(window.window_handle(), main);
            owner.observed = owner.source.load(Ordering::Acquire);
        })
    })
    .unwrap();
    assert_eq!(
        cx.read(|cx| owner.read(cx).observed),
        42,
        "main polling must still observe a new source revision after Settings closes"
    );
    cx.update_window(main, |_, window, _| window.activate_window())
        .unwrap();
    cx.run_until_parked();
    let quit = cx.update(crate::app_menu::install);
    cx.update(|cx| cx.dispatch_action(&crate::app_menu::Quit));
    cx.run_until_parked();
    assert!(
        cx.update(|cx| super::update(main, &weak, cx, |_, _, _| quit
            .swap(false, Ordering::AcqRel)))
            .unwrap(),
        "normal menu Quit must still reach the captured main poll after Settings closes"
    );
    cx.update_window(main, |_, window, _| window.remove_window())
        .unwrap();
    assert!(
        cx.update(|cx| super::update(main, &weak, cx, |_, _, _| ()))
            .is_err(),
        "a genuinely closed main window must terminate polling"
    );
}
#[::core::prelude::v1::test]
fn private_actual_main_window_poll_child() {
    let root = std::env::temp_dir().join(format!(
        "coincide-main-poll-fixture-{}",
        uuid::Uuid::new_v4()
    ));
    coincide_core::native_file::private_directory(&root).unwrap();
    for child in ["home", "tmp", "empty-path"] {
        coincide_core::native_file::private_directory(&root.join(child)).unwrap();
    }
    let mut command = std::process::Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--ignored",
            "main_window_poll::tests::shared_owner_keeps_polling_main_after_settings_closes",
            "--nocapture",
            "--test-threads=1",
        ])
        .env_clear()
        .env(CHILD, "1")
        .env("HOME", root.join("home"))
        .env("USERPROFILE", root.join("home"))
        .env("TMPDIR", root.join("tmp"))
        .env("TMP", root.join("tmp"))
        .env("TEMP", root.join("tmp"))
        .env("PATH", root.join("empty-path"))
        .current_dir(&root);
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
        output.status.success() && stdout.contains("1 passed"),
        "actual shared-owner main poll fixture failed; retained {}\n{stdout}\n{stderr}",
        root.display()
    );
    std::fs::remove_dir_all(root).unwrap();
}
