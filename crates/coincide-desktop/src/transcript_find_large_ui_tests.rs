//! Exercise the native Find entity against a large synthetic conversation.
use super::{FindEvent, FindItem, FindSnapshot, TranscriptFind};
use gpui_kit::{
    App, AppContext, Context, Entity, IntoElement, ParentElement, Render, Styled, Subscription,
    TestAppContext, Window, div,
};
use std::{
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
const CHILD: &str = "COINCIDE_HEADLESS_LARGE_FIND_CHILD";
struct Harness {
    find: Entity<TranscriptFind>,
    _events: Subscription,
}
impl Render for Harness {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(self.find.clone())
    }
}
fn draw(window: &mut Window, cx: &mut App) {
    window.refresh();
    window.draw(cx).clear(cx);
}

#[gpui_kit::test]
#[ignore = "launched by private-child wrapper"]
fn headless_find_indexes_large_streaming_chat_and_reveals_results(cx: &mut TestAppContext) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    cx.update(gpui_kit::init);
    let events: Arc<Mutex<Vec<(String, u64)>>> = Arc::new(Mutex::new(Vec::new()));
    let (view, vcx) = cx.add_window_view(|window, cx| {
        let find = cx.new(|cx| TranscriptFind::new(window, cx));
        let recorded = events.clone();
        let subscription = cx.subscribe(&find, move |_, _, event, _| {
            if let FindEvent::Reveal {
                item_id,
                generation,
                ..
            } = event
            {
                recorded
                    .lock()
                    .unwrap()
                    .push((item_id.clone(), *generation));
            }
        });
        Harness {
            find,
            _events: subscription,
        }
    });
    let find = view.read_with(vcx, |view, _| view.find.clone());
    let mut items: Vec<_> = (0..25_515)
        .map(|index| FindItem {
            item_id: format!("item-{index}"),
            source: format!("ordinary message {index}").into(),
        })
        .collect();
    items[1].source = "first **needle** here".into();
    items[2].source = "[link](https://needle.invalid)".into();
    items[25_514].source = "older NEEDLE".into();
    vcx.update(|window, cx| {
        window.activate_window();
        find.update(cx, |find, cx| {
            find.open(
                FindSnapshot {
                    thread_id: "thread".into(),
                    generation: 1,
                    items: items.clone(),
                },
                window,
                cx,
            )
            .unwrap()
        });
        items[25_514].source = "streamed NEEDLE".into();
        items.push(FindItem {
            item_id: "new".into(),
            source: "new needle".into(),
        });
        find.update(cx, |find, cx| {
            find.replace_snapshot(
                FindSnapshot {
                    thread_id: "thread".into(),
                    generation: 2,
                    items,
                },
                cx,
            )
            .unwrap()
        });
        let input = find.read(cx).input.clone();
        input.update(cx, |input, cx| input.focus(window, cx));
        draw(window, cx);
    });
    vcx.simulate_input("needle");
    let deadline = Instant::now() + Duration::from_secs(25);
    loop {
        vcx.run_until_parked();
        vcx.update(|window, cx| {
            find.update(cx, |find, cx| {
                find.poll_large(cx);
                if find.dirty {
                    find.rescan(false, false, cx);
                }
            });
            draw(window, cx);
        });
        if find.read_with(vcx, |find, _| {
            find.search.matches.len() == 3 && find.search.selected().is_some()
        }) && !events.lock().unwrap().is_empty()
        {
            break;
        }
        if Instant::now() >= deadline {
            let status = find.read_with(vcx, |find, _| {
                (
                    find.opened,
                    find.search.query.clone(),
                    find.search.matches.len(),
                    find.large
                        .as_ref()
                        .map(|large| (large.pending(), large.searching())),
                    find.items.len(),
                    find.dirty,
                    find.error.clone(),
                )
            });
            panic!(
                "large Find indexing did not finish: {status:?}, events {:?}",
                events.lock().unwrap()
            );
        }
        std::thread::yield_now();
    }
    let ids = find.read_with(vcx, |find, _| {
        assert!(
            find.items.len() <= 1,
            "only the selected result has a native Markdown view"
        );
        find.search
            .matches
            .iter()
            .map(|matched| matched.item.clone())
            .collect::<Vec<_>>()
    });
    assert_eq!(ids, ["item-1", "item-25514", "new"]);
    assert_eq!(events.lock().unwrap()[0], ("item-1".into(), 2));
    vcx.update(|_, cx| find.update(cx, |find, cx| find.step_match(true, cx)));
    loop {
        vcx.run_until_parked();
        vcx.update(|window, cx| {
            find.update(cx, |find, cx| {
                if find.dirty {
                    find.rescan(false, false, cx);
                }
            });
            draw(window, cx);
        });
        if events
            .lock()
            .unwrap()
            .iter()
            .any(|event| event == &("item-25514".into(), 2))
        {
            break;
        }
        assert!(Instant::now() < deadline, "next match did not reveal");
        std::thread::yield_now();
    }
}

#[::core::prelude::v1::test]
fn private_headless_large_find_child() {
    let root = std::env::temp_dir().join(format!(
        "coincide-large-find-fixture-{}",
        uuid::Uuid::new_v4()
    ));
    coincide_core::native_file::private_directory(&root).unwrap();
    for child in ["home", "tmp", "empty-path"] {
        coincide_core::native_file::private_directory(&root.join(child)).unwrap();
    }
    let mut command = std::process::Command::new(std::env::current_exe().unwrap());
    command.args(["--ignored", "transcript_find::large_ui_tests::headless_find_indexes_large_streaming_chat_and_reveals_results", "--nocapture", "--test-threads=1"])
        .env_clear().env(CHILD,"1").env("HOME",root.join("home")).env("USERPROFILE",root.join("home"))
        .env("TMPDIR",root.join("tmp")).env("TMP",root.join("tmp")).env("TEMP",root.join("tmp"))
        .env("PATH",root.join("empty-path")).env("LANG","en_US.UTF-8").current_dir(&root);
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
        "large Find fixture failed; retained {}\n{stdout}\n{stderr}",
        root.display()
    );
    std::fs::remove_dir_all(root).unwrap();
}
