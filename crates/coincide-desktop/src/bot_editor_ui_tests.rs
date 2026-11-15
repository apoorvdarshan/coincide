//! The actual sheet and keyboard handlers, using only a private synthetic store.
use super::{BotSettingsEvent, BotSettingsPanel, NEW};
use coincide_core::{
    api::{Engine, SharedEngine, call},
    store::Store,
};
use gpui_kit::{
    App, AppContext, Context, Entity, IntoElement, ParentElement, Render, Styled, Subscription,
    TestAppContext, VisualTestContext, Window, div,
};
use serde_json::{Value, json};
use std::{
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

const CHILD: &str = "COINCIDE_HEADLESS_BOT_EDITOR_CHILD";

struct Harness {
    panel: Entity<BotSettingsPanel>,
    _events: Subscription,
}
impl Render for Harness {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(self.panel.clone())
    }
}
fn draw(window: &mut Window, cx: &mut App) {
    window.refresh();
    window.draw(cx).clear(cx);
}
fn wait_for(
    panel: &Entity<BotSettingsPanel>,
    vcx: &mut VisualTestContext,
    done: impl Fn() -> bool,
) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !done() {
        vcx.update(|window, cx| panel.update(cx, |panel, cx| panel.poll(window, cx)));
        vcx.run_until_parked();
        assert!(
            Instant::now() < deadline,
            "bot sheet operation did not finish"
        );
        std::thread::yield_now();
    }
}

#[gpui_kit::test]
#[ignore = "launched by private-child wrapper"]
fn headless_bot_sheet_saves_folder_and_escape_discards_edits(cx: &mut TestAppContext) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    cx.update(gpui_kit::init);
    let root = std::env::current_dir().unwrap();
    let data = root.join("data");
    let folder = root.join("sample-work");
    coincide_core::native_file::private_directory(&data).unwrap();
    std::fs::create_dir(&folder).unwrap();
    let engine: SharedEngine = Arc::new(Mutex::new(Engine::new(
        Store::open(&data.join("state.sqlite")).unwrap(),
    )));
    let list = call(&engine, "bots.list", json!({})).unwrap();
    let baseline = list["baseline"].as_str().unwrap().to_owned();
    let events: Arc<Mutex<Vec<Value>>> = Arc::new(Mutex::new(Vec::new()));
    let (view, vcx) = cx.add_window_view(|window, cx| {
        let panel = cx.new(|cx| {
            BotSettingsPanel::new_sheet(engine.clone(), None, vec![], baseline, window, cx)
        });
        let recorded = events.clone();
        let subscription = cx.subscribe(&panel, move |_, _, event, _| {
            let value = match event {
                BotSettingsEvent::Saved {
                    bot,
                    created,
                    close_editor,
                    ..
                } => json!({"bot":bot,"created":created,"close":close_editor}),
                BotSettingsEvent::Closed => json!({"closed":true}),
                BotSettingsEvent::ConversationCreated { .. } => return,
            };
            recorded.lock().unwrap().push(value);
        });
        Harness {
            panel,
            _events: subscription,
        }
    });
    let panel = view.read_with(vcx, |view, _| view.panel.clone());
    vcx.update(|window, cx| {
        window.activate_window();
        panel.update(cx, |panel, cx| {
            assert_eq!(panel.selected.as_deref(), Some(NEW));
            assert!(
                !panel.busy,
                "cached bots open without waiting for the engine"
            );
            let editor = panel.editors.get_mut(NEW).unwrap();
            editor.folder = Some(folder.to_string_lossy().into_owned());
            editor
                .name
                .update(cx, |input, cx| input.set_value("Sample bot", window, cx));
            editor.name.update(cx, |input, cx| input.focus(window, cx));
        });
        draw(window, cx);
    });
    vcx.simulate_keystrokes(if cfg!(target_os = "macos") {
        "cmd-enter"
    } else {
        "ctrl-enter"
    });
    wait_for(&panel, vcx, || !events.lock().unwrap().is_empty());
    let saved = events.lock().unwrap()[0].clone();
    assert_eq!(saved["created"], true);
    assert_eq!(saved["close"], true);
    assert_eq!(saved["bot"]["name"], "Sample bot");
    assert_eq!(saved["bot"]["folder"], folder.to_string_lossy().as_ref());
    let bot_id = saved["bot"]["id"].as_str().unwrap().to_owned();
    vcx.update(|window, cx| {
        panel.update(cx, |panel, cx| {
            let editor = panel.editors.get_mut(&bot_id).unwrap();
            editor.name.update(cx, |input, cx| {
                input.set_value("Discarded edit", window, cx)
            });
            editor.name.update(cx, |input, cx| input.focus(window, cx));
        });
        draw(window, cx);
    });
    vcx.simulate_keystrokes("escape");
    assert!(
        events
            .lock()
            .unwrap()
            .iter()
            .any(|event| event["closed"] == true)
    );
    let persisted = call(&engine, "bots.read", json!({"botId":bot_id})).unwrap();
    assert_eq!(persisted["bot"]["name"], "Sample bot");
    assert_eq!(
        persisted["bot"]["folder"],
        folder.to_string_lossy().as_ref()
    );
}

#[::core::prelude::v1::test]
fn private_headless_bot_sheet_child() {
    let root = std::env::temp_dir().join(format!(
        "coincide-bot-sheet-fixture-{}",
        uuid::Uuid::new_v4()
    ));
    coincide_core::native_file::private_directory(&root).unwrap();
    for child in ["home", "tmp", "empty-path"] {
        coincide_core::native_file::private_directory(&root.join(child)).unwrap();
    }
    let mut command = std::process::Command::new(std::env::current_exe().unwrap());
    command.args(["--ignored", "bot_settings::sheet_ui_tests::headless_bot_sheet_saves_folder_and_escape_discards_edits", "--nocapture", "--test-threads=1"])
        .env_clear().env(CHILD, "1").env("HOME", root.join("home")).env("USERPROFILE", root.join("home"))
        .env("TMPDIR", root.join("tmp")).env("TMP", root.join("tmp")).env("TEMP", root.join("tmp"))
        .env("PATH", root.join("empty-path")).env("LANG", "en_US.UTF-8").current_dir(&root);
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
        "headless bot sheet fixture failed; retained {}\n{stdout}\n{stderr}",
        root.display()
    );
    std::fs::remove_dir_all(root).unwrap();
}
