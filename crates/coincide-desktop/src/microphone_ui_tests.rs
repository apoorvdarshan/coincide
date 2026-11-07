//! Actual TestPlatform rendering and native worker entry points, exclusively
//! fake microphone/inference adapters and a private child environment.
use super::{
    CaptureBinding, CaptureChunk, CaptureError, CaptureEvent, CapturedAudio, Controller, Inference,
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
    fn read_chunk(
        &mut self,
        session: Uuid,
        offset: usize,
        _: usize,
    ) -> Result<Option<CaptureChunk>, CaptureError> {
        if self.session != Some(session) {
            return Err(CaptureError::InvalidBinding);
        }
        if offset >= 2 {
            return Ok(None);
        }
        Ok(Some(CaptureChunk {
            session,
            generation: 2,
            binding: self.binding.clone().unwrap(),
            offset,
            samples: vec![0.0, 0.5],
        }))
    }
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
#[derive(Default)]
struct FakeInference {
    streamed: usize,
}
impl Inference for FakeInference {
    fn prepare_apple(
        &mut self,
        config: &crate::voice_speech::Configuration,
        _: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), InferenceFailure> {
        assert_eq!(config.locale, "ja-JP");
        Ok(())
    }
    fn stream_apple(
        &mut self,
        offset: usize,
        samples: &[f32],
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), InferenceFailure> {
        assert!(!cancelled());
        assert_eq!(self.streamed, offset);
        self.streamed += samples.len();
        Ok(())
    }
    fn apple_partial(&mut self) -> Option<String> {
        (self.streamed > 0).then(|| "途中の synthetic café".into())
    }
    fn apple(
        &mut self,
        wav: &[u8],
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<String, InferenceFailure> {
        assert!(!cancelled());
        assert!(wav.starts_with(b"RIFF"));
        assert_eq!(self.streamed, 2);
        Ok("合成の最終文".into())
    }
    fn cancel_apple(&mut self) {
        self.streamed = 0;
    }
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
            Box::new(FakeInference::default()),
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
        let focus = input.read(cx).focus_handle(cx).clone();
        focus.focus(window, cx);
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
                    model_proof: None,
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
        assert!(input.read(cx).focus_handle(cx).is_focused(window));
        let (text, caret) = insert(&binding, &event, input.read(cx).value().as_ref()).unwrap();
        assert_eq!(text, "before synthetic café 👩🏽‍💻 after");
        input.update(cx, |input, cx| {
            input.replace_all(text, window, cx);
            input.set_selected_range(caret..caret, cx);
        });
        draw(window, cx);
        assert!(input.read(cx).focus_handle(cx).is_focused(window));
        assert_eq!(
            input.read(cx).value().as_ref(),
            "before synthetic café 👩🏽‍💻 after"
        );
    });
    let apple_binding = vcx.update(|window, cx| {
        let input = view.read(cx).input.clone();
        let panel = view.read(cx).panel.clone();
        let mut target = ComposerTarget::default();
        target.changed();
        target.changed();
        let binding = target
            .bind(
                Some("synthetic-thread"),
                input.read(cx).value().as_ref(),
                input.read(cx).selected_range(),
                false,
            )
            .unwrap();
        panel.update(cx, |panel, cx| {
            panel.set_configuration_target(
                Some(binding.clone()),
                2,
                Some(super::RecordingConfig::Apple(
                    crate::voice_speech::Configuration {
                        locale: "ja-JP".into(),
                        maximum_seconds: 1,
                    },
                )),
                None,
                true,
                cx,
            );
            panel.begin_dictation(cx);
        });
        draw(window, cx);
        binding
    });
    started_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("actual fake streaming capture started");
    let preview_deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let ready = vcx.update(|_, cx| {
            view.read(cx).panel.clone().update(cx, |panel, cx| {
                panel.poll(cx);
                panel.partial_preview() == Some("途中の synthetic café")
            })
        });
        if ready {
            break;
        }
        assert!(
            Instant::now() < preview_deadline,
            "actual fake worker must publish the matching partial receipt"
        );
        std::thread::yield_now();
    }
    vcx.update(|window, cx| {
        let panel = view.read(cx).panel.clone();
        let input = view.read(cx).input.clone();
        draw(window, cx);
        assert_eq!(
            input.read(cx).value().as_ref(),
            "before synthetic café 👩🏽‍💻 after",
            "preview never replaces the original draft or changes its undo history"
        );
        assert!(
            input.read(cx).focus_handle(cx).is_focused(window),
            "native partial preview cannot take composer focus"
        );
        assert!(
            events.try_recv().is_err(),
            "interim text must not be admitted as final text or automatic send"
        );
        panel.update(cx, |panel, cx| panel.stop_dictation(cx));
    });
    let event = events
        .recv_timeout(Duration::from_secs(5))
        .expect("actual fake streaming final transcript");
    vcx.update(|window, cx| {
        let panel = view.read(cx).panel.clone();
        let input = view.read(cx).input.clone();
        assert!(panel.read(cx).accepts_text(&event, &apple_binding));
        let (text, caret) =
            insert(&apple_binding, &event, input.read(cx).value().as_ref()).unwrap();
        assert_eq!(text, "before synthetic café 👩🏽‍💻 合成の最終文 after");
        input.update(cx, |input, cx| {
            input.replace_all(text, window, cx);
            input.set_selected_range(caret..caret, cx);
        });
        draw(window, cx);
        assert!(input.read(cx).focus_handle(cx).is_focused(window));
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
