//! Private TestPlatform only: fake OS secret store and fake service transport.
use super::{Action, Credential, Panel, Provider, Service, VoiceSecrets};
use coincide_core::{
    dictation::voice_secret::{Backend, Failure},
    native_ui_edits::NativeUiEditors,
};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::{
    App, AppContext, Context, Entity, IntoElement, ParentElement, Render, Styled, TestAppContext,
    VisualTestContext, Window, div,
};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
    mpsc::{self, Receiver, Sender},
};
use std::time::{Duration, Instant};
use zeroize::Zeroizing;
const CHILD: &str = "COINCIDE_HEADLESS_VOICE_KEYS_CHILD";
struct FakeStore {
    key: Mutex<Option<String>>,
    calls: AtomicUsize,
    entered: Sender<()>,
    release: Mutex<Option<Receiver<()>>>,
}
impl Backend for FakeStore {
    fn read(&self, _: Provider) -> Result<Zeroizing<String>, Failure> {
        self.calls.fetch_add(1, Ordering::AcqRel);
        self.key
            .lock()
            .unwrap()
            .clone()
            .map(Zeroizing::new)
            .ok_or(Failure::NotFound)
    }
    fn write(&self, _: Provider, key: &str) -> Result<(), Failure> {
        self.calls.fetch_add(1, Ordering::AcqRel);
        self.entered.send(()).unwrap();
        if let Some(wait) = self.release.lock().unwrap().take() {
            wait.recv_timeout(Duration::from_secs(5)).unwrap();
        }
        *self.key.lock().unwrap() = Some(key.into());
        Ok(())
    }
    fn delete(&self, _: Provider) -> Result<(), Failure> {
        self.calls.fetch_add(1, Ordering::AcqRel);
        *self.key.lock().unwrap() = None;
        Ok(())
    }
}
struct FakeService(Arc<AtomicUsize>);
impl Service for FakeService {
    fn test(&self, key: &Credential, cancelled: &(dyn Fn() -> bool + Sync)) -> Result<(), ()> {
        assert_eq!(key.provider(), Provider::OpenAi);
        assert!(!cancelled());
        self.0.fetch_add(1, Ordering::AcqRel);
        Ok(())
    }
}
struct Harness {
    panel: Entity<Panel>,
    shown: bool,
}
impl Render for Harness {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .when(self.shown, |pane| pane.child(self.panel.clone()))
    }
}
fn draw(window: &mut Window, cx: &mut App) {
    window.refresh();
    window.draw(cx).clear(cx);
}
fn returned(panel: &Entity<Panel>, vcx: &mut VisualTestContext) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if vcx.update(|_, cx| panel.update(cx, |panel, _| panel.workers.status().unjoined == 0)) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "actual fake Voice key worker did not join"
        );
        std::thread::yield_now();
    }
}
#[gpui_kit::test]
#[ignore = "private-child wrapper only"]
fn headless_voice_key_save_preserves_newer_input_and_owned_hidden_worker(cx: &mut TestAppContext) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    cx.update(gpui_kit::init);
    let (entered, wait) = mpsc::channel();
    let (release, gate) = mpsc::channel();
    let tested = Arc::new(AtomicUsize::new(0));
    let fake = Arc::new(FakeStore {
        key: Mutex::new(None),
        calls: AtomicUsize::new(0),
        entered,
        release: Mutex::new(Some(gate)),
    });
    let secrets = VoiceSecrets::with_backend(fake.clone());
    let service = Arc::new(FakeService(tested.clone()));
    let (view, vcx) = cx.add_window_view(|window, cx| Harness {
        panel: cx.new(|cx| {
            Panel::with_services(NativeUiEditors::default(), secrets, service, window, cx)
        }),
        shown: true,
    });
    let panel = vcx.update(|window, cx| {
        draw(window, cx);
        view.read(cx).panel.clone()
    });
    assert_eq!(
        fake.calls.load(Ordering::Acquire),
        0,
        "constructing/rendering must not query a personal OS vault"
    );
    vcx.update(|window, cx| {
        let input = panel.read(cx).editors[0].input.clone();
        input.update(cx, |input, cx| {
            input.replace_all("synthetic-saved-voice-key", window, cx)
        });
    });
    vcx.run_until_parked();
    vcx.update(|_, cx| {
        panel.update(cx, |panel, cx| {
            assert!(panel.blocks_close(cx));
            panel.save(Provider::OpenAi, cx);
        })
    });
    wait.recv_timeout(Duration::from_secs(5))
        .expect("actual fake save entered owned worker");
    vcx.update(|window, cx| {
        let input = panel.read(cx).editors[0].input.clone();
        input.update(cx, |input, cx| {
            input.replace_all("synthetic-newer-unsaved-key", window, cx)
        });
        view.update(cx, |view, _| view.shown = false);
        draw(window, cx);
        assert!(panel.read(cx).blocks_close(cx));
    });
    vcx.run_until_parked();
    release.send(()).unwrap();
    returned(&panel, vcx);
    vcx.update(|window, cx| {
        assert!(
            panel.read(cx).blocks_close(cx),
            "reply custody remains pending through actual native callback"
        );
        panel.update(cx, |panel, cx| panel.poll(window, cx));
        assert_eq!(
            panel.read(cx).editors[0].input.read(cx).value().as_ref(),
            "synthetic-newer-unsaved-key"
        );
        assert!(
            panel
                .read(cx)
                .configuration(Provider::OpenAi, "gpt-transcribe".into(), None, cx)
                .is_none()
        );
        panel.update(cx, |panel, cx| panel.discard(Provider::OpenAi, window, cx));
        assert!(
            panel
                .read(cx)
                .configuration(Provider::OpenAi, "gpt-transcribe".into(), None, cx)
                .is_some()
        );
        view.update(cx, |view, _| view.shown = true);
        draw(window, cx);
        panel.update(cx, |panel, cx| {
            panel.action(Provider::OpenAi, Action::Test, cx)
        });
    });
    returned(&panel, vcx);
    vcx.update(|window, cx| panel.update(cx, |panel, cx| panel.poll(window, cx)));
    assert_eq!(
        tested.load(Ordering::Acquire),
        1,
        "Test Key uses only injected fake service"
    );
    vcx.update(|_, cx| {
        panel.update(cx, |panel, cx| {
            panel.action(Provider::OpenAi, Action::Delete, cx)
        })
    });
    returned(&panel, vcx);
    vcx.update(|window, cx| {
        panel.update(cx, |panel, cx| panel.poll(window, cx));
        assert!(
            panel
                .read(cx)
                .configuration(Provider::OpenAi, "gpt-transcribe".into(), None, cx)
                .is_none()
        );
        panel.update(cx, |panel, _| panel.request_shutdown());
    });
    returned(&panel, vcx);
    assert!(fake.key.lock().unwrap().is_none());
}
#[::core::prelude::v1::test]
fn private_actual_voice_key_editor_child() {
    use std::{fs, process::Command};
    let root = std::env::temp_dir().join(format!(
        "coincide-voice-key-fixture-{}",
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
            "voice_credentials::native_tests::headless_",
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
        output.status.success() && stdout.contains("1 passed"),
        "actual Voice key editor child failed; retained {}\n{stdout}\n{stderr}",
        root.display()
    );
    fs::remove_dir_all(root).unwrap();
}
