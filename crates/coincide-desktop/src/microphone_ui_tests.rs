//! Actual TestPlatform rendering and native worker entry points, exclusively
//! fake microphone/inference adapters and a private child environment.
use super::{
    CaptureBinding, CaptureError, CaptureEvent, CapturedAudio, Controller, Inference,
    InferenceFailure, LocalRecordingConfig, MicrophoneSettings, Permission,
};
use crate::transcription_composer::{ComposerTarget, insert};
use gpui_kit::{
    App, AppContext, Context, Entity, Focusable, IntoElement, ParentElement, Render, Styled,
    TestAppContext, Window,
    component::input::{Textarea, TextareaState},
    div, px,
};
use std::{
    collections::VecDeque,
    sync::mpsc::{self, Sender},
    time::{Duration, Instant},
};
use uuid::Uuid;
const CHILD: &str = "COINCIDE_HEADLESS_VOICE_CHILD";
struct FakeCapture {
    binding: Option<CaptureBinding>,
    session: Option<Uuid>,
    events: VecDeque<CaptureEvent>,
    started: Sender<()>,
}
impl Controller for FakeCapture {
    fn set_binding(&mut self, binding: Option<CaptureBinding>) {
        self.binding = binding;
    }
    fn request_permission(&mut self) -> Result<(), CaptureError> {
        self.events
            .push_back(CaptureEvent::PermissionChanged(Permission::Ready));
        Ok(())
    }
    fn start(&mut self, _: usize) -> Result<Uuid, CaptureError> {
        let id = Uuid::new_v4();
        self.session = Some(id);
        self.events.push_back(CaptureEvent::Started(id));
        Ok(id)
    }
    fn stop(&mut self, session: Uuid) -> Result<(), CaptureError> {
        assert_eq!(self.session, Some(session));
        self.events.push_back(CaptureEvent::Audio(CapturedAudio {
            session,
            generation: 2,
            binding: self.binding.clone().unwrap(),
            wav: coincide_core::dictation::transcription::encode_wav(&[0.0, 0.5], 16_000).unwrap(),
            limit_reached: false,
        }));
        Ok(())
    }
    fn cancel(&mut self) {
        self.session = None;
        self.events.clear();
    }
    fn poll(&mut self) -> Option<CaptureEvent> {
        let event = self.events.pop_front();
        if matches!(event, Some(CaptureEvent::Started(_))) {
            self.started.send(()).unwrap();
        }
        event
    }
    fn accepts(&self, audio: &CapturedAudio, binding: &CaptureBinding) -> bool {
        audio.generation == 2
            && self.session == Some(audio.session)
            && self.binding.as_ref() == Some(binding)
            && audio.binding == *binding
    }
}
struct FakeInference;
impl Inference for FakeInference {
    fn transcribe(
        &mut self,
        _: &LocalRecordingConfig,
        wav: &[u8],
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<String, InferenceFailure> {
        assert!(!cancelled());
        assert!(wav.starts_with(b"RIFF"));
        Ok("synthetic café 👩🏽‍💻".into())
    }
}
struct Harness {
    input: Entity<TextareaState>,
    panel: Entity<MicrophoneSettings>,
}
impl Render for Harness {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(Textarea::new(&self.input).h(px(100.)))
            .child(self.panel.clone())
    }
}
fn draw(window: &mut Window, cx: &mut App) {
    window.refresh();
    window.draw(cx).clear(cx);
}
#[gpui_kit::test]
#[ignore = "private-child wrapper only"]
fn headless_voice_worker_keeps_actual_unicode_editor_and_focus(cx: &mut TestAppContext) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    cx.update(gpui_kit::init);
    let (started_tx, started_rx) = mpsc::channel();
    let (panel, events) = MicrophoneSettings::with_factory(Box::new(move || {
        (
            Box::new(FakeCapture {
                binding: None,
                session: None,
                events: VecDeque::new(),
                started: started_tx,
            }),
            Box::new(FakeInference),
        )
    }));
    let (view, vcx) = cx.add_window_view(|window, cx| Harness {
        input: cx.new(|cx| TextareaState::new(window, cx)),
        panel: cx.new(|_| panel),
    });
    let binding = vcx.update(|window, cx| {
        window.activate_window();
        let input = view.read(cx).input.clone();
        input.update(cx, |input, cx| {
            input.set_value("before 🦀 after", window, cx);
            input.set_selected_range(7..11, cx);
        });
        input.read(cx).focus_handle().clone().focus(window, cx);
        draw(window, cx);
        let mut target = ComposerTarget::default();
        let binding = target
            .bind(
                Some("synthetic-thread"),
                input.read(cx).value().as_ref(),
                input.read(cx).selected_range(),
                false,
            )
            .unwrap();
        let panel = view.read(cx).panel.clone();
        panel.update(cx, |panel, cx| {
            panel.set_target(
                Some(binding.clone()),
                1,
                Some(LocalRecordingConfig {
                    executable: "/private/synthetic-whisper".into(),
                    model: "/private/synthetic-model".into(),
                    language: "en".into(),
                    threads: 1,
                    maximum_seconds: 1,
                }),
                true,
                cx,
            );
            panel.begin_dictation(cx);
        });
        binding
    });
    started_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("actual fake worker started");
    vcx.update(|window, cx| {
        let panel = view.read(cx).panel.clone();
        panel.update(cx, |panel, cx| {
            panel.poll(cx);
            assert!(panel.dictation_active());
            panel.stop_dictation(cx);
        });
        draw(window, cx);
    });
    let event = events
        .recv_timeout(Duration::from_secs(5))
        .expect("actual fake worker transcript");
    vcx.update(|window, cx| {
        let panel = view.read(cx).panel.clone();
        assert!(panel.read(cx).accepts_text(&event, &binding));
        let input = view.read(cx).input.clone();
        assert!(input.read(cx).focus_handle().is_focused(window));
        let (text, caret) = insert(&binding, &event, input.read(cx).value().as_ref()).unwrap();
        assert_eq!(text, "before synthetic café 👩🏽‍💻 after");
        input.update(cx, |input, cx| {
            input.replace_all(text, window, cx);
            input.set_selected_range(caret..caret, cx);
        });
        draw(window, cx);
        assert!(input.read(cx).focus_handle().is_focused(window));
        assert_eq!(
            input.read(cx).value().as_ref(),
            "before synthetic café 👩🏽‍💻 after"
        );
        panel.update(cx, |panel, _| panel.request_shutdown());
    });
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let joined = vcx.update(|_, cx| {
            view.read(cx)
                .panel
                .clone()
                .update(cx, |panel, _| panel.shutdown_status().ordinary_exit_ready())
        });
        if joined {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "fake capture worker must actually join"
        );
        std::thread::yield_now();
    }
}
#[::core::prelude::v1::test]
fn private_actual_voice_compositor_child() {
    use std::{fs, process::Command};
    let root = std::env::temp_dir().join(format!("coincide-voice-fixture-{}", Uuid::new_v4()));
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
            "microphone_settings::native_tests::headless_",
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
        "actual Voice compositor child failed; retained {}\n{stdout}\n{stderr}",
        root.display()
    );
    fs::remove_dir_all(root).unwrap();
}
