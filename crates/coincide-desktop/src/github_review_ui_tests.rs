//! Exercise the real panel with synthetic GitHub responses and a private store.
use super::*;
use ::core::prelude::v1::test;
use coincide_core::{api::Engine, store::Store};
use gpui_kit::{Modifiers, TestAppContext, VisualTestContext};
use std::sync::Mutex;

const CHILD: &str = "COINCIDE_HEADLESS_GITHUB_STATUS_CHILD";

struct Harness {
    panel: Entity<GitHubReviewPanel>,
    opened: Vec<(String, String, Modifiers)>,
    _links: Subscription,
}
impl Render for Harness {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().w(px(720.)).h(px(560.)).child(self.panel.clone())
    }
}

fn request() -> Request {
    Request {
        binding: Binding {
            thread: "thread-a".into(),
            root: std::env::current_dir()
                .unwrap()
                .to_string_lossy()
                .into_owned(),
            repository: "fixture/repo".into(),
            involvement: Involvement::All,
        },
        view: View::List("open".into()),
    }
}
fn pr(status: &str, conclusion: Option<&str>) -> Value {
    json!({"number":42,"title":"Synthetic PR","url":"https://github.com/fixture/repo/pull/42","state":"OPEN","isDraft":false,"headRefOid":"a".repeat(40),"headRefName":"feature","baseRefName":"main","statusCheckRollup":[{"name":"Build","status":status,"conclusion":conclusion,"detailsUrl":"https://github.com/fixture/repo/actions/runs/1"}]})
}
fn payload(request: &Request, pr: Value) -> Value {
    json!({"kind":"list","state":"open","involvement":"all","threadId":request.binding.thread,"expectedRoot":request.binding.root,"repository":"fixture/repo","pullRequests":[pr],"limit":LIMIT,"truncated":false})
}
fn draw(window: &mut Window, cx: &mut App) {
    window.refresh();
    window.draw(cx).clear(cx);
}

#[gpui_kit::test]
#[ignore = "launched by private-child wrapper"]
fn headless_checks_expand_open_and_follow_background_results(cx: &mut TestAppContext) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    cx.update(gpui_kit::init);
    let engine: SharedEngine = Arc::new(Mutex::new(Engine::new(
        Store::open(&std::env::current_dir().unwrap().join("state.sqlite")).unwrap(),
    )));
    let (view, cx): (Entity<Harness>, &mut VisualTestContext) = cx.add_window_view(|window, cx| {
        let panel = cx.new(|cx| GitHubReviewPanel::new(engine.clone(), window, cx));
        let links = cx.subscribe(&panel, |this: &mut Harness, _, event: &OpenCheckLink, _| {
            this.opened
                .push((event.thread.clone(), event.url.clone(), event.modifiers));
        });
        Harness {
            panel,
            opened: Vec::new(),
            _links: links,
        }
    });
    let panel = view.read_with(cx, |view, _| view.panel.clone());
    let request = request();
    let mut pending = pr("IN_PROGRESS", None);
    pending["statusCheckRollup"]
        .as_array_mut()
        .unwrap()
        .push(json!({
        "name":"Unsafe", "status":"COMPLETED", "conclusion":"SUCCESS",
            "detailsUrl":"javascript:alert(1)"
        }));
    cx.update(|window, cx| {
        panel.update(cx, |panel, _| {
            panel.scope = Some((request.binding.thread.clone(), request.binding.root.clone()));
            panel.active = Some((7, request.clone()));
            panel.visible = true;
            panel.live_attempt = Some(Instant::now());
            panel.list = vec![pending.clone()];
            panel.cursor = Some(0);
        });
        draw(window, cx);
        draw(window, cx);
    });
    let badge = cx
        .debug_bounds("github-pr-checks-42")
        .expect("status is rendered");
    cx.simulate_mouse_move(badge.center(), None, Modifiers::default());
    cx.simulate_click(badge.center(), Modifiers::default());
    cx.update(draw);
    assert!(panel.read_with(cx, |panel, _| panel.selected.is_none()));
    assert!(panel.read_with(cx, |panel, _| panel.expanded_checks.is_some()));
    let check = cx
        .debug_bounds("github-check-42-0")
        .expect("checks expand in the panel");
    cx.simulate_mouse_move(check.center(), None, Modifiers::default());
    cx.simulate_click(check.center(), Modifiers::default());
    assert_eq!(
        view.read_with(cx, |view, _| view.opened.clone()),
        vec![(
            "thread-a".into(),
            "https://github.com/fixture/repo/actions/runs/1".into(),
            Modifiers::default()
        )]
    );
    let mut modified = Modifiers::default();
    if cfg!(target_os = "macos") {
        modified.platform = true;
    } else {
        modified.control = true;
    }
    cx.simulate_click(check.center(), modified);
    assert_eq!(view.read_with(cx, |view, _| view.opened[1].2), modified);
    let unsafe_check = cx.debug_bounds("github-check-42-1").unwrap();
    cx.simulate_click(unsafe_check.center(), Modifiers::default());
    assert_eq!(view.read_with(cx, |view, _| view.opened.len()), 2);

    // A completion from a different thread cannot update the current panel.
    let mut wrong = request.clone();
    wrong.binding.thread = "thread-b".into();
    cx.update(|_, cx| {
        panel.update(cx, |panel, cx| {
            panel
                .live_tx
                .send((
                    7,
                    wrong.clone(),
                    Ok(payload(&wrong, pr("COMPLETED", Some("SUCCESS")))),
                ))
                .unwrap();
            panel.poll_live(cx);
        })
    });
    assert_eq!(
        panel.read_with(cx, |panel, _| {
            panel.list[0]["statusCheckRollup"][0]["status"].clone()
        }),
        "IN_PROGRESS"
    );

    // A live result updates checks without losing the expanded list or cursor.
    cx.update(|window, cx| {
        panel.update(cx, |panel, cx| {
            panel
                .live_tx
                .send((
                    7,
                    request.clone(),
                    Ok(payload(&request, pr("COMPLETED", Some("SUCCESS")))),
                ))
                .unwrap();
            panel.poll_live(cx);
        });
        draw(window, cx);
    });
    assert_eq!(
        panel.read_with(cx, |panel, _| {
            panel.list[0]["statusCheckRollup"][0]["conclusion"].clone()
        }),
        "SUCCESS"
    );
    assert!(
        panel.read_with(cx, |panel, _| panel.expanded_checks.is_some()
            && panel.cursor == Some(0))
    );
    assert!(cx.debug_bounds("github-check-42-0").is_some());
    cx.update(|_, cx| {
        panel.update(cx, |panel, cx| {
            panel
                .live_tx
                .send((7, request.clone(), Err(anyhow::anyhow!("offline"))))
                .unwrap();
            panel.poll_live(cx);
            assert!(panel.live_failed);
            assert_eq!(
                panel.list[0]["statusCheckRollup"][0]["conclusion"],
                "SUCCESS"
            );
            panel.request_shutdown(cx);
            assert!(panel.shutdown_status(cx).read.closed);
        })
    });
}

#[::core::prelude::v1::test]
fn private_headless_github_checks_child() {
    let root =
        std::env::temp_dir().join(format!("coincide-github-checks-{}", uuid::Uuid::new_v4()));
    coincide_core::native_file::private_directory(&root).unwrap();
    for child in ["home", "tmp", "empty-path"] {
        coincide_core::native_file::private_directory(&root.join(child)).unwrap();
    }
    let mut command = std::process::Command::new(std::env::current_exe().unwrap());
    command.args(["--ignored", "github_review::native_tests::headless_checks_expand_open_and_follow_background_results", "--nocapture", "--test-threads=1"])
        .env_clear().env(CHILD, "1").env("HOME", root.join("home"))
        .env("USERPROFILE", root.join("home")).env("TMPDIR", root.join("tmp"))
        .env("TMP", root.join("tmp")).env("TEMP", root.join("tmp"))
        .env("PATH", root.join("empty-path")).env("LANG", "en_US.UTF-8")
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
        "GitHub panel child failed at {}\n{stdout}\n{stderr}",
        root.display()
    );
    std::fs::remove_dir_all(root).unwrap();
}
