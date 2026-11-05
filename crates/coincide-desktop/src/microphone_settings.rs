//! Native-only microphone controls. Parent's acceptance gate is false until
//! separately authorized live TCC/capture acceptance; it is not a user toggle.
use crate::{
    microphone::{
        CaptureBinding, CaptureError, CaptureEvent, CapturedAudio, Microphone, Permission,
    },
    transcription_settings::{ComposerBinding, TextReady},
};
use coincide_core::dictation::local::LocalWhisper;
use gpui_kit::{
    Context, IntoElement, ParentElement, Render, SharedString, Styled, Window,
    component::{Disableable, button::Button},
    div,
};
use std::{
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, Sender, SyncSender},
    },
    time::Duration,
};
use uuid::Uuid;

#[derive(Clone, PartialEq, Eq)]
pub struct LocalRecordingConfig {
    pub executable: PathBuf,
    pub model: PathBuf,
    pub language: String,
    pub threads: usize,
    pub maximum_seconds: usize,
}
#[derive(Clone, PartialEq, Eq)]
struct Target {
    binding: Option<ComposerBinding>,
    settings_revision: u64,
    config: Option<LocalRecordingConfig>,
}
impl Target {
    fn capture_binding(&self) -> Option<CaptureBinding> {
        self.binding.as_ref().map(|binding| CaptureBinding {
            thread_id: binding.thread_id.clone(),
            composer_revision: binding.composer_revision,
            settings_revision: self.settings_revision,
            selection: binding.selection.clone(),
        })
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Idle,
    Pending,
    Permission,
    Recording,
    Stopping,
    Captured,
    Transcribing,
    Failed,
}
#[derive(Clone, Copy)]
enum Action {
    Enable,
    Record,
    Stop,
    Transcribe,
}
struct Command {
    generation: u64,
    target: Target,
    action: Action,
}
struct Snapshot {
    generation: u64,
    phase: Phase,
    permission: Permission,
    message: &'static str,
}
struct Shared {
    accepted: AtomicBool,
    generation: AtomicU64,
    alive: AtomicBool,
}
trait Controller {
    fn set_binding(&mut self, binding: Option<CaptureBinding>);
    fn request_permission(&mut self) -> Result<(), CaptureError>;
    fn start(&mut self, seconds: usize) -> Result<Uuid, CaptureError>;
    fn stop(&mut self, session: Uuid) -> Result<(), CaptureError>;
    fn cancel(&mut self);
    fn poll(&mut self) -> Option<CaptureEvent>;
    fn accepts(&self, audio: &CapturedAudio, binding: &CaptureBinding) -> bool;
}
impl Controller for Microphone {
    fn set_binding(&mut self, binding: Option<CaptureBinding>) {
        Microphone::set_binding(self, binding);
    }
    fn request_permission(&mut self) -> Result<(), CaptureError> {
        Microphone::request_permission(self)
    }
    fn start(&mut self, seconds: usize) -> Result<Uuid, CaptureError> {
        Microphone::start(self, seconds)
    }
    fn stop(&mut self, session: Uuid) -> Result<(), CaptureError> {
        Microphone::stop(self, session)
    }
    fn cancel(&mut self) {
        Microphone::cancel(self);
    }
    fn poll(&mut self) -> Option<CaptureEvent> {
        Microphone::poll(self)
    }
    fn accepts(&self, audio: &CapturedAudio, binding: &CaptureBinding) -> bool {
        self.accepts_audio(audio, binding)
    }
}
trait Inference {
    fn transcribe(
        &mut self,
        configuration: &LocalRecordingConfig,
        wav: &[u8],
    ) -> Result<String, ()>;
}
struct LocalInference;
impl Inference for LocalInference {
    fn transcribe(
        &mut self,
        configuration: &LocalRecordingConfig,
        wav: &[u8],
    ) -> Result<String, ()> {
        LocalWhisper::new(
            configuration.executable.clone(),
            configuration.model.clone(),
            configuration.language.clone(),
            configuration.threads,
            Duration::from_secs(120),
        )
        .map_err(|_| ())?
        .transcribe_local(wav)
        .map_err(|_| ())
    }
}
type Factory = Box<dyn FnOnce() -> (Box<dyn Controller>, Box<dyn Inference>) + Send>;
struct Owner {
    factory: Option<Factory>,
    controller: Option<Box<dyn Controller>>,
    inference: Option<Box<dyn Inference>>,
    shared: Arc<Shared>,
    snapshots: Sender<Snapshot>,
    text: Sender<TextReady>,
    generation: u64,
    target: Option<Target>,
    phase: Phase,
    permission: Permission,
    permission_target: Option<Target>,
    session: Option<Uuid>,
    audio: Option<CapturedAudio>,
}
impl Owner {
    fn current(&self) -> bool {
        self.shared.alive.load(Ordering::Acquire)
            && self.shared.accepted.load(Ordering::Acquire)
            && self.shared.generation.load(Ordering::Acquire) == self.generation
    }
    fn publish(&self, message: &'static str) {
        if self.current() {
            let _ = self.snapshots.send(Snapshot {
                generation: self.generation,
                phase: self.phase,
                permission: self.permission,
                message,
            });
        }
    }
    fn reset(&mut self) {
        if let Some(controller) = self.controller.as_mut() {
            controller.cancel();
        }
        self.audio = None;
        self.session = None;
        self.target = None;
        self.phase = Phase::Idle;
    }
    fn command(&mut self, command: Command) {
        if !self.shared.alive.load(Ordering::Acquire)
            || !self.shared.accepted.load(Ordering::Acquire)
            || self.shared.generation.load(Ordering::Acquire) != command.generation
        {
            return;
        }
        if self.generation != command.generation || self.target.as_ref() != Some(&command.target) {
            let permission = if self.permission_target.as_ref() == Some(&command.target) {
                self.permission
            } else {
                Permission::Unavailable
            };
            self.reset();
            self.generation = command.generation;
            self.permission = permission;
            self.target = Some(command.target);
            if self.controller.is_none() {
                let Some(factory) = self.factory.take() else {
                    return;
                };
                let (controller, inference) = factory();
                self.controller = Some(controller);
                self.inference = Some(inference);
            }
            self.controller
                .as_mut()
                .unwrap()
                .set_binding(self.target.as_ref().and_then(Target::capture_binding));
        }
        if !self.current() {
            self.reset();
            return;
        }
        match command.action {
            Action::Enable if self.phase == Phase::Idle || self.phase == Phase::Failed => {
                match self.controller.as_mut().unwrap().request_permission() {
                    Ok(()) => {
                        self.phase = Phase::Permission;
                        self.publish("Waiting for explicit microphone authorization. Granting permission does not record.");
                    }
                    Err(_) => {
                        self.phase = Phase::Failed;
                        self.publish(
                            "Microphone permission is unavailable for this backend or bundle.",
                        );
                    }
                }
            }
            Action::Record
                if self.phase == Phase::Idle
                    || self.phase == Phase::Captured
                    || self.phase == Phase::Failed =>
            {
                let Some(target) = &self.target else {
                    return;
                };
                let Some(configuration) = &target.config else {
                    self.publish("Configure the local executable and model before recording.");
                    return;
                };
                if self.permission != Permission::Authorized || target.binding.is_none() {
                    self.publish("Use Enable Microphone first and select a composer target.");
                    return;
                }
                self.audio = None;
                match self
                    .controller
                    .as_mut()
                    .unwrap()
                    .start(configuration.maximum_seconds)
                {
                    Ok(session) => {
                        self.session = Some(session);
                        self.phase = Phase::Recording;
                        self.publish(
                            "Recording locally. Stop ends capture; it does not transcribe or send.",
                        );
                    }
                    Err(error) => {
                        self.phase = Phase::Failed;
                        self.publish(match error { CaptureError::Busy => "Another native owner is using the microphone.", _ => "Recording could not start. Check authorization, device and configured limits." });
                    }
                }
            }
            Action::Stop if self.phase == Phase::Recording => {
                if let Some(session) = self.session {
                    match self.controller.as_mut().unwrap().stop(session) {
                        Ok(()) => {
                            self.phase = Phase::Stopping;
                            self.publish("Stopping capture and draining conversion buffers…");
                        }
                        Err(_) => {
                            self.reset();
                            self.phase = Phase::Failed;
                            self.publish(
                                "Capture could not stop normally; cancellation was requested.",
                            );
                        }
                    }
                }
            }
            Action::Transcribe if self.phase == Phase::Captured => self.transcribe(),
            _ => {}
        }
    }
    fn tick(&mut self) {
        if !self.current() {
            if self.target.is_some() {
                self.reset();
            }
            return;
        }
        // Bounded drain prevents a broken backend starving cancellation commands.
        for _ in 0..8 {
            let event = self
                .controller
                .as_mut()
                .and_then(|controller| controller.poll());
            let Some(event) = event else {
                break;
            };
            match event {
                CaptureEvent::PermissionChanged(permission) => {
                    self.permission = permission;
                    self.permission_target = self.target.clone();
                    self.phase = Phase::Idle;
                    self.publish(if permission == Permission::Authorized { "Microphone permission granted. Press Record to begin; nothing is recording." } else { "Microphone is not authorized. Nothing is recording." });
                }
                CaptureEvent::Started(session) => {
                    if self.session != Some(session) {
                        self.reset();
                        self.phase = Phase::Failed;
                        self.publish("Unexpected capture session was discarded.");
                    }
                }
                CaptureEvent::Audio(audio) => {
                    let valid = self.session == Some(audio.session)
                        && self
                            .target
                            .as_ref()
                            .and_then(Target::capture_binding)
                            .is_some_and(|binding| {
                                self.controller.as_ref().unwrap().accepts(&audio, &binding)
                            });
                    if valid && self.current() {
                        let limited = audio.limit_reached;
                        self.audio = Some(audio);
                        self.session = None;
                        self.phase = Phase::Captured;
                        self.publish(if limited { "Recording reached its limit and stopped. Press Transcribe Recording to proceed." } else { "Recording stopped. Press Transcribe Recording to proceed; nothing was sent." });
                    } else {
                        self.reset();
                        self.publish("Recording discarded because its target changed.");
                    }
                }
                CaptureEvent::Failed(_) => {
                    self.audio = None;
                    self.session = None;
                    self.phase = Phase::Failed;
                    self.publish("Native capture failed. Nothing was transcribed or sent.");
                }
                CaptureEvent::Cancelled => {
                    self.audio = None;
                    self.session = None;
                    self.phase = Phase::Idle;
                    self.publish("Recording cancelled and discarded.");
                }
            }
        }
    }
    fn transcribe(&mut self) {
        let Some(target) = self.target.clone() else {
            return;
        };
        let (Some(binding), Some(configuration), Some(audio)) =
            (target.binding, target.config, self.audio.take())
        else {
            return;
        };
        let Some(capture_binding) = self.target.as_ref().and_then(Target::capture_binding) else {
            return;
        };
        if !self.current()
            || !self
                .controller
                .as_ref()
                .unwrap()
                .accepts(&audio, &capture_binding)
        {
            self.reset();
            return;
        }
        self.phase = Phase::Transcribing;
        self.publish("Transcribing the stopped recording locally… Cancel discards the result; inference may finish cleanup in the background.");
        // Runs on the same dedicated owner, with capture already stopped. The
        // UI never waits. Shared generation revokes results during this call.
        let result = self
            .inference
            .as_mut()
            .unwrap()
            .transcribe(&configuration, &audio.wav);
        if !self.current() {
            self.reset();
            return;
        }
        self.phase = Phase::Idle;
        match result {
            Ok(text) if !text.trim().is_empty() => {
                let _ = self.text.send(TextReady {
                    generation: self.generation,
                    binding,
                    text,
                });
                self.publish("Transcript ready for the matching composer. Nothing was sent.");
            }
            Ok(_) => self.publish("No speech text was returned. Composer unchanged."),
            Err(()) => {
                self.phase = Phase::Failed;
                self.publish("Local transcription failed. Check the selected CLI/model and recording format.");
            }
        }
    }
}
impl Drop for Owner {
    fn drop(&mut self) {
        self.reset();
    }
}
struct Connection {
    shared: Arc<Shared>,
    commands: SyncSender<Command>,
    snapshots: Receiver<Snapshot>,
}
fn spawn_owner(factory: Factory) -> (Connection, Receiver<TextReady>) {
    let shared = Arc::new(Shared {
        accepted: AtomicBool::new(false),
        generation: AtomicU64::new(0),
        alive: AtomicBool::new(true),
    });
    let (commands, receiver) = mpsc::sync_channel(8);
    let (snapshots, updates) = mpsc::channel();
    let (text, events) = mpsc::channel();
    let state = shared.clone();
    std::thread::spawn(move || {
        // Factory is invoked lazily on THIS thread, only after acceptance and an
        // explicit native action. Non-Send AVAudioEngine owner never crosses threads.
        let mut owner = Owner {
            factory: Some(factory),
            controller: None,
            inference: None,
            shared: state,
            snapshots,
            text,
            generation: 0,
            target: None,
            phase: Phase::Idle,
            permission: Permission::Unavailable,
            permission_target: None,
            session: None,
            audio: None,
        };
        while owner.shared.alive.load(Ordering::Acquire) {
            match receiver.recv_timeout(Duration::from_millis(10)) {
                Ok(command) => owner.command(command),
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
            owner.tick();
        }
    });
    (
        Connection {
            shared,
            commands,
            snapshots: updates,
        },
        events,
    )
}
impl Drop for Connection {
    fn drop(&mut self) {
        self.shared.accepted.store(false, Ordering::Release);
        self.shared.generation.fetch_add(1, Ordering::AcqRel);
        self.shared.alive.store(false, Ordering::Release);
    }
}

/// Parent supplies the existing local-model configuration snapshot. No settings
/// are discovered, persisted, or interpreted as approval. native_accepted must
/// remain FALSE until separately authorized real TCC/mic acceptance succeeds.
pub struct MicrophoneSettings {
    connection: Connection,
    target: Target,
    generation: u64,
    native_accepted: bool,
    phase: Phase,
    permission: Permission,
    status: String,
}
impl MicrophoneSettings {
    pub fn new() -> (Self, Receiver<TextReady>) {
        let (connection, events) = spawn_owner(Box::new(|| {
            (Box::new(Microphone::new()), Box::new(LocalInference))
        }));
        (Self { connection, target: Target { binding: None, settings_revision: 0, config: None }, generation: 0, native_accepted: false, phase: Phase::Idle, permission: Permission::Unavailable, status: "Native microphone acceptance is pending. Permission, recording and inference controls are disabled.".into() }, events)
    }
    pub fn set_target(
        &mut self,
        binding: Option<ComposerBinding>,
        settings_revision: u64,
        configuration: Option<LocalRecordingConfig>,
        native_accepted: bool,
        cx: &mut Context<Self>,
    ) {
        let target = Target {
            binding,
            settings_revision,
            config: configuration,
        };
        if self.target != target || self.native_accepted != native_accepted {
            self.connection
                .shared
                .accepted
                .store(false, Ordering::Release);
            self.generation = self
                .connection
                .shared
                .generation
                .fetch_add(1, Ordering::AcqRel)
                .wrapping_add(1);
            self.target = target;
            self.native_accepted = native_accepted;
            self.phase = Phase::Idle;
            self.permission = Permission::Unavailable;
            self.connection
                .shared
                .accepted
                .store(native_accepted, Ordering::Release);
            self.status = if native_accepted { "Target/configuration changed. Previous recording/results are discarded. Use Enable Microphone before Record." } else { "Native microphone acceptance is pending. Permission, recording and inference controls are disabled." }.into();
            cx.notify();
        }
    }
    pub fn cancel(&mut self, cx: &mut Context<Self>) {
        self.generation = self
            .connection
            .shared
            .generation
            .fetch_add(1, Ordering::AcqRel)
            .wrapping_add(1);
        self.phase = Phase::Idle;
        self.permission = Permission::Unavailable;
        self.status = "Cancellation requested; recording/results are discarded. An existing OS permission dialog may still need your response. Inference cleanup may finish in the background.".into();
        cx.notify();
    }
    pub fn accepts_text(&self, event: &TextReady, live: &ComposerBinding) -> bool {
        self.native_accepted
            && event.generation == self.generation
            && event.binding == *live
            && self.target.binding.as_ref() == Some(live)
    }
    pub fn poll(&mut self, cx: &mut Context<Self>) {
        while let Ok(snapshot) = self.connection.snapshots.try_recv() {
            if snapshot.generation == self.generation && self.native_accepted {
                self.phase = snapshot.phase;
                self.permission = snapshot.permission;
                self.status = snapshot.message.into();
                cx.notify();
            }
        }
    }
    fn action(&mut self, action: Action, cx: &mut Context<Self>) {
        if !self.native_accepted {
            return;
        }
        // Beginning a new explicit request invalidates any older queued text.
        if matches!(action, Action::Enable | Action::Record) {
            self.generation = self
                .connection
                .shared
                .generation
                .fetch_add(1, Ordering::AcqRel)
                .wrapping_add(1);
        }
        let command = Command {
            generation: self.generation,
            target: self.target.clone(),
            action,
        };
        if self.connection.commands.try_send(command).is_err() {
            self.phase = Phase::Idle;
            self.permission = Permission::Unavailable;
            self.status = "The native owner is busy. The request was not queued; use Enable Microphone after it finishes.".into();
        } else {
            self.phase = Phase::Pending;
            self.status = "Native request queued. Waiting for the owner thread; recording/inference has not been confirmed.".into();
        }
        cx.notify();
    }
}
impl Render for MicrophoneSettings {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let gated = !self.native_accepted;
        div().flex().flex_col().gap_2().p_4().child("Microphone → local transcription")
            .child("Enable permission, Record, Stop, then Transcribe Recording. Permission grants never start capture. Nothing is sent automatically.")
            .child(Button::new("microphone-enable").label("Enable Microphone").disabled(gated || !matches!(self.phase, Phase::Idle | Phase::Failed)).on_click(cx.listener(|this, _, _, cx| this.action(Action::Enable, cx))))
            .child(Button::new("microphone-record").label("Record").disabled(gated || self.permission != Permission::Authorized || !matches!(self.phase, Phase::Idle | Phase::Captured | Phase::Failed) || self.target.binding.is_none() || self.target.config.is_none()).on_click(cx.listener(|this, _, _, cx| this.action(Action::Record, cx))))
            .child(Button::new("microphone-stop").label("Stop").disabled(gated || self.phase != Phase::Recording).on_click(cx.listener(|this, _, _, cx| this.action(Action::Stop, cx))))
            .child(Button::new("microphone-cancel").label("Cancel").disabled(gated && self.phase == Phase::Idle).on_click(cx.listener(|this, _, _, cx| this.cancel(cx))))
            .child(Button::new("microphone-transcribe").label("Transcribe Recording").disabled(gated || self.phase != Phase::Captured).on_click(cx.listener(|this, _, _, cx| this.action(Action::Transcribe, cx))))
            .child(SharedString::from(self.status.clone()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        collections::VecDeque,
        sync::Mutex,
        thread::{self, ThreadId},
    };
    #[derive(Default)]
    struct Trace {
        created: usize,
        requests: usize,
        starts: usize,
        stops: usize,
        cancels: usize,
        inference: usize,
        threads: Vec<ThreadId>,
        closed: Option<Sender<()>>,
    }
    struct FakeController {
        trace: Arc<Mutex<Trace>>,
        binding: Option<CaptureBinding>,
        session: Option<Uuid>,
        events: VecDeque<CaptureEvent>,
    }
    impl Controller for FakeController {
        fn set_binding(&mut self, binding: Option<CaptureBinding>) {
            self.trace
                .lock()
                .unwrap()
                .threads
                .push(thread::current().id());
            self.binding = binding;
        }
        fn request_permission(&mut self) -> Result<(), CaptureError> {
            let mut trace = self.trace.lock().unwrap();
            trace.requests += 1;
            trace.threads.push(thread::current().id());
            self.events
                .push_back(CaptureEvent::PermissionChanged(Permission::Authorized));
            Ok(())
        }
        fn start(&mut self, _: usize) -> Result<Uuid, CaptureError> {
            let mut trace = self.trace.lock().unwrap();
            trace.starts += 1;
            trace.threads.push(thread::current().id());
            let id = Uuid::new_v4();
            self.session = Some(id);
            self.events.push_back(CaptureEvent::Started(id));
            Ok(id)
        }
        fn stop(&mut self, session: Uuid) -> Result<(), CaptureError> {
            assert_eq!(self.session, Some(session));
            let mut trace = self.trace.lock().unwrap();
            trace.stops += 1;
            trace.threads.push(thread::current().id());
            self.events.push_back(CaptureEvent::Audio(CapturedAudio {
                session,
                generation: 1,
                binding: self.binding.clone().unwrap(),
                wav: coincide_core::dictation::transcription::encode_wav(&[0.0, 0.5], 16_000)
                    .unwrap(),
                limit_reached: false,
            }));
            Ok(())
        }
        fn cancel(&mut self) {
            let mut trace = self.trace.lock().unwrap();
            trace.threads.push(thread::current().id());
            if self.session.take().is_some() {
                trace.cancels += 1;
            }
            self.events.clear();
        }
        fn poll(&mut self) -> Option<CaptureEvent> {
            self.trace
                .lock()
                .unwrap()
                .threads
                .push(thread::current().id());
            self.events.pop_front()
        }
        fn accepts(&self, audio: &CapturedAudio, binding: &CaptureBinding) -> bool {
            self.session == Some(audio.session)
                && self.binding.as_ref() == Some(binding)
                && audio.binding == *binding
        }
    }
    impl Drop for FakeController {
        fn drop(&mut self) {
            let mut trace = self.trace.lock().unwrap();
            trace.threads.push(thread::current().id());
            if let Some(closed) = trace.closed.take() {
                let _ = closed.send(());
            }
        }
    }
    struct FakeInference {
        trace: Arc<Mutex<Trace>>,
        revoke: Option<Arc<Shared>>,
    }
    impl Inference for FakeInference {
        fn transcribe(&mut self, config: &LocalRecordingConfig, wav: &[u8]) -> Result<String, ()> {
            assert_eq!(config.language, "en");
            assert!(wav.starts_with(b"RIFF"));
            let mut trace = self.trace.lock().unwrap();
            trace.inference += 1;
            trace.threads.push(thread::current().id());
            if let Some(shared) = &self.revoke {
                shared.generation.fetch_add(1, Ordering::AcqRel);
            }
            Ok("synthetic recorded transcript".into())
        }
    }
    fn factory(trace: Arc<Mutex<Trace>>, revoke: Option<Arc<Shared>>) -> Factory {
        Box::new(move || {
            {
                let mut trace = trace.lock().unwrap();
                trace.created += 1;
                trace.threads.push(thread::current().id());
            }
            (
                Box::new(FakeController {
                    trace: trace.clone(),
                    binding: None,
                    session: None,
                    events: VecDeque::new(),
                }),
                Box::new(FakeInference { trace, revoke }),
            )
        })
    }
    fn target() -> Target {
        Target {
            binding: Some(ComposerBinding {
                thread_id: "synthetic-thread".into(),
                composer_revision: 1,
                selection: 0..0,
            }),
            settings_revision: 1,
            config: Some(LocalRecordingConfig {
                executable: PathBuf::from("/synthetic/whisper"),
                model: PathBuf::from("/synthetic/model"),
                language: "en".into(),
                threads: 2,
                maximum_seconds: 1,
            }),
        }
    }
    fn setup(
        accepted: bool,
        revoke_on_inference: bool,
    ) -> (Owner, Receiver<TextReady>, Arc<Mutex<Trace>>) {
        let shared = Arc::new(Shared {
            accepted: AtomicBool::new(accepted),
            generation: AtomicU64::new(1),
            alive: AtomicBool::new(true),
        });
        let trace = Arc::new(Mutex::new(Trace::default()));
        let (text, events) = mpsc::channel();
        let (snapshots, _) = mpsc::channel();
        let owner = Owner {
            factory: Some(factory(
                trace.clone(),
                revoke_on_inference.then(|| shared.clone()),
            )),
            controller: None,
            inference: None,
            shared,
            snapshots,
            text,
            generation: 0,
            target: None,
            phase: Phase::Idle,
            permission: Permission::Unavailable,
            permission_target: None,
            session: None,
            audio: None,
        };
        (owner, events, trace)
    }
    fn action(owner: &mut Owner, action: Action) {
        owner.command(Command {
            generation: 1,
            target: target(),
            action,
        });
        owner.tick();
    }
    fn record_and_stop(owner: &mut Owner) {
        action(owner, Action::Enable);
        action(owner, Action::Record);
        action(owner, Action::Stop);
        assert!(owner.phase == Phase::Captured);
    }
    #[::core::prelude::v1::test]
    fn default_acceptance_gate_prevents_even_controller_construction() {
        let (mut owner, events, trace) = setup(false, false);
        for request in [
            Action::Enable,
            Action::Record,
            Action::Stop,
            Action::Transcribe,
        ] {
            action(&mut owner, request);
        }
        assert_eq!(trace.lock().unwrap().created, 0);
        assert!(events.try_recv().is_err());
    }
    #[::core::prelude::v1::test]
    fn permission_record_stop_and_inference_require_separate_actions() {
        let (mut owner, events, trace) = setup(true, false);
        action(&mut owner, Action::Enable);
        assert_eq!(trace.lock().unwrap().starts, 0);
        action(&mut owner, Action::Record);
        assert_eq!(trace.lock().unwrap().inference, 0);
        action(&mut owner, Action::Stop);
        assert!(owner.phase == Phase::Captured);
        assert!(events.try_recv().is_err());
        action(&mut owner, Action::Transcribe);
        let text = events.try_recv().unwrap();
        assert_eq!(text.text, "synthetic recorded transcript");
        assert_eq!(text.generation, 1);
        assert_eq!(text.binding.composer_revision, 1);
        assert_eq!(trace.lock().unwrap().inference, 1);
        assert!(events.try_recv().is_err());
    }
    #[::core::prelude::v1::test]
    fn target_generation_change_cancels_and_discards_stopped_audio() {
        let (mut owner, events, trace) = setup(true, false);
        record_and_stop(&mut owner);
        owner.shared.generation.store(2, Ordering::Release);
        owner.tick();
        assert!(owner.audio.is_none());
        assert_eq!(trace.lock().unwrap().cancels, 1);
        action(&mut owner, Action::Transcribe);
        assert_eq!(trace.lock().unwrap().inference, 0);
        assert!(events.try_recv().is_err());
    }
    #[::core::prelude::v1::test]
    fn cancellation_during_inference_never_emits_stale_text() {
        let (mut owner, events, trace) = setup(true, true);
        record_and_stop(&mut owner);
        action(&mut owner, Action::Transcribe);
        assert_eq!(trace.lock().unwrap().inference, 1);
        assert!(events.try_recv().is_err());
    }
    #[::core::prelude::v1::test]
    fn record_generation_handoff_retains_only_matching_permission_metadata() {
        let (mut owner, _events, trace) = setup(true, false);
        action(&mut owner, Action::Enable);
        owner.shared.generation.store(2, Ordering::Release);
        owner.tick(); // owner notices revocation before new Record arrives
        owner.command(Command {
            generation: 2,
            target: target(),
            action: Action::Record,
        });
        assert_eq!(trace.lock().unwrap().starts, 1);
        assert_eq!(trace.lock().unwrap().requests, 1);
    }
    #[::core::prelude::v1::test]
    fn controller_lifecycle_runs_only_on_dedicated_owner_thread() {
        let trace = Arc::new(Mutex::new(Trace::default()));
        let (closed, done) = mpsc::channel();
        trace.lock().unwrap().closed = Some(closed);
        let (connection, _events) = spawn_owner(factory(trace.clone(), None));
        let caller = thread::current().id();
        connection.shared.generation.store(1, Ordering::Release);
        connection.shared.accepted.store(true, Ordering::Release);
        connection
            .commands
            .try_send(Command {
                generation: 1,
                target: target(),
                action: Action::Enable,
            })
            .unwrap_or_else(|_| panic!("command queue closed"));
        loop {
            let snapshot = connection
                .snapshots
                .recv_timeout(Duration::from_secs(2))
                .unwrap();
            if snapshot.permission == Permission::Authorized {
                break;
            }
        }
        let threads = trace.lock().unwrap().threads.clone();
        assert!(!threads.is_empty());
        assert!(threads.iter().all(|id| *id != caller && *id == threads[0]));
        assert_eq!(trace.lock().unwrap().starts, 0);
        drop(connection); // asynchronous owner teardown; no UI join
        done.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(
            trace
                .lock()
                .unwrap()
                .threads
                .iter()
                .all(|id| *id == threads[0])
        );
    }
}
