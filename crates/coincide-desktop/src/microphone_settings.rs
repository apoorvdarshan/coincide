//! Explicit native capture controls. Compiled capability enables actions;
//! construction/rendering never request permission, record, transcribe or send.
use crate::{
    microphone::{
        CaptureBinding, CaptureError, CaptureEvent, CaptureProgress, CapturedAudio, Microphone,
        Permission,
    },
    transcription_settings::{ComposerBinding, TextReady},
};
use coincide_core::{
    agent::{WorkerCompletion, WorkerThreadStatus},
    dictation::local::{LocalError, LocalWhisper},
};
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
pub enum RecordingConfig {
    Local(LocalRecordingConfig),
    Hosted(coincide_core::dictation::voice_api::HostedConfig),
}
impl RecordingConfig {
    fn maximum_seconds(&self) -> usize {
        match self {
            Self::Local(config) => config.maximum_seconds,
            Self::Hosted(config) => config.maximum_seconds,
        }
    }
}
#[derive(Clone, PartialEq, Eq)]
struct Target {
    binding: Option<ComposerBinding>,
    settings_revision: u64,
    config: Option<RecordingConfig>,
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
    BeginDictation,
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
    progress: Option<CaptureProgress>,
    text_pending: bool,
}
struct Shared {
    enabled: AtomicBool,
    generation: AtomicU64,
    alive: AtomicBool,
    controller_constructed: AtomicBool,
}
trait Controller {
    fn progress(&self) -> Option<CaptureProgress> {
        None
    }
    fn set_binding(&mut self, binding: Option<CaptureBinding>);
    fn request_permission(&mut self) -> Result<(), CaptureError>;
    fn start(&mut self, seconds: usize) -> Result<Uuid, CaptureError>;
    fn stop(&mut self, session: Uuid) -> Result<(), CaptureError>;
    fn cancel(&mut self);
    fn poll(&mut self) -> Option<CaptureEvent>;
    fn accepts(&self, audio: &CapturedAudio, binding: &CaptureBinding) -> bool;
}
impl Controller for Microphone {
    fn progress(&self) -> Option<CaptureProgress> {
        Microphone::progress(self)
    }
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
#[derive(Debug)]
enum InferenceFailure {
    Failed,
    Cancelled,
    CleanupPending,
    Hosted(coincide_core::dictation::transcription::Error),
}
trait Inference {
    fn hosted(
        &mut self,
        _: &coincide_core::dictation::voice_api::HostedConfig,
        _: &[u8],
        _: &(dyn Fn() -> bool + Sync),
    ) -> Result<String, InferenceFailure> {
        Err(InferenceFailure::Failed)
    }
    fn transcribe(
        &mut self,
        configuration: &LocalRecordingConfig,
        wav: &[u8],
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<String, InferenceFailure>;
}
struct LocalInference;
impl Inference for LocalInference {
    fn hosted(
        &mut self,
        config: &coincide_core::dictation::voice_api::HostedConfig,
        wav: &[u8],
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<String, InferenceFailure> {
        config.transcribe(wav, cancelled).map_err(|error| {
            if error == coincide_core::dictation::transcription::Error::Cancelled {
                InferenceFailure::Cancelled
            } else {
                InferenceFailure::Hosted(error)
            }
        })
    }

    fn transcribe(
        &mut self,
        configuration: &LocalRecordingConfig,
        wav: &[u8],
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<String, InferenceFailure> {
        LocalWhisper::new(
            configuration.executable.clone(),
            configuration.model.clone(),
            configuration.language.clone(),
            configuration.threads,
            Duration::from_secs(120),
        )
        .map_err(|_| InferenceFailure::Failed)?
        .transcribe_local_cancellable(wav, cancelled)
        .map_err(|error| match error {
            LocalError::Cancelled => InferenceFailure::Cancelled,
            LocalError::CleanupPending => InferenceFailure::CleanupPending,
            _ => InferenceFailure::Failed,
        })
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
    dictation: bool,
    progress_bucket: Option<usize>,
    text_pending: bool,
}
impl Owner {
    fn current(&self) -> bool {
        self.shared.alive.load(Ordering::Acquire)
            && self.shared.enabled.load(Ordering::Acquire)
            && self.shared.generation.load(Ordering::Acquire) == self.generation
    }
    fn publish(&self, message: &'static str) {
        if self.current() {
            let _ = self.snapshots.send(Snapshot {
                generation: self.generation,
                phase: self.phase,
                permission: self.permission,
                message,
                progress: self.progress(),
                text_pending: self.text_pending,
            });
        }
    }
    fn progress(&self) -> Option<CaptureProgress> {
        if self.phase != Phase::Recording || !self.current() {
            return None;
        }
        self.controller.as_ref()?.progress().filter(|p| {
            Some(p.session) == self.session
                && p.captured_samples <= 16_000 * 60
                && p.level.is_finite()
                && (0.0..=1.0).contains(&p.level)
        })
    }
    fn reset(&mut self) {
        self.progress_bucket = None;
        self.text_pending = false;
        if let Some(controller) = self.controller.as_mut() {
            controller.cancel();
        }
        self.audio = None;
        self.session = None;
        self.dictation = false;
        self.target = None;
        self.phase = Phase::Idle;
    }
    fn command(&mut self, command: Command) {
        if !self.shared.alive.load(Ordering::Acquire)
            || !self.shared.enabled.load(Ordering::Acquire)
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
                // Construction can create native callback owners. cancel/Drop
                // exposes no callback-queue drain ACK, including on unwind.
                self.shared
                    .controller_constructed
                    .store(true, Ordering::Release);
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
            Action::BeginDictation if matches!(self.phase, Phase::Idle | Phase::Failed) => {
                // This closed native intent authorizes permission followed by
                // capture for this exact target. Manual Enable stays separate.
                if self
                    .target
                    .as_ref()
                    .is_none_or(|target| target.binding.is_none() || target.config.is_none())
                {
                    self.publish("Configure transcription and select a composer before dictating.");
                    return;
                }
                self.dictation = true;
                let target = self.target.clone().unwrap();
                self.command(Command {
                    generation: self.generation,
                    target,
                    action: Action::Enable,
                });
            }
            Action::Enable if self.phase == Phase::Idle || self.phase == Phase::Failed => {
                match self.controller.as_mut().unwrap().request_permission() {
                    Ok(()) => {
                        self.phase = Phase::Permission;
                        self.publish(if self.dictation {"Waiting for microphone authorization to start this dictation. Cancel discards this request."}else{"Waiting for explicit microphone authorization. Granting permission does not record."});
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
                    self.publish("Configure local transcription or load the selected Voice API key before recording.");
                    return;
                };
                if !matches!(self.permission, Permission::Authorized | Permission::Ready)
                    || target.binding.is_none()
                {
                    self.publish("Use Enable Microphone first and select a composer target.");
                    return;
                }
                self.audio = None;
                match self
                    .controller
                    .as_mut()
                    .unwrap()
                    .start(configuration.maximum_seconds())
                {
                    Ok(session) => {
                        self.session = Some(session);
                        self.phase = Phase::Recording;
                        self.publish(if self.dictation {"Listening. Stop transcribes this recording using the captured Voice settings."}else{"Recording locally. Stop ends capture; it does not transcribe or send."});
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
                    let continue_dictation = self.dictation && self.phase == Phase::Permission;
                    self.permission = permission;
                    self.permission_target = self.target.clone();
                    self.phase = Phase::Idle;
                    if continue_dictation
                        && matches!(permission, Permission::Authorized | Permission::Ready)
                    {
                        let target = self.target.clone().unwrap();
                        self.command(Command {
                            generation: self.generation,
                            target,
                            action: Action::Record,
                        });
                        continue;
                    }
                    self.dictation = false;
                    self.publish(match permission {
                        Permission::Authorized => "Microphone permission granted. Press Record to begin; nothing is recording.",
                        Permission::Ready => "Microphone is ready. Record opens the selected device; system privacy settings may still deny access. Nothing is recording.",
                        _ => "Microphone is not authorized. Nothing is recording.",
                    });
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
                        if self.dictation {
                            self.transcribe();
                            continue;
                        }
                        self.publish(if limited { "Recording reached its limit and stopped. Press Transcribe Recording to proceed." } else { "Recording stopped. Press Transcribe Recording to proceed; nothing was sent." });
                    } else {
                        self.reset();
                        self.publish("Recording discarded because its target changed.");
                    }
                }
                CaptureEvent::Failed(_) => {
                    self.text_pending = false;
                    self.audio = None;
                    self.session = None;
                    self.phase = Phase::Failed;
                    self.publish("Native capture failed. Nothing was transcribed or sent.");
                }
                CaptureEvent::Cancelled => {
                    self.text_pending = false;
                    self.audio = None;
                    self.session = None;
                    self.phase = Phase::Idle;
                    self.publish("Recording cancelled and discarded.");
                }
            }
        }
        if let Some(progress) = self.progress() {
            let bucket = progress.captured_samples / 1600;
            if self.progress_bucket != Some(bucket) {
                self.progress_bucket = Some(bucket);
                self.publish("Listening…");
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
        self.text_pending = false;
        self.phase = Phase::Transcribing;
        self.publish(if matches!(&configuration,RecordingConfig::Hosted(_)){"Transcribing with the selected Voice service. Audio is sent under your account and its data policies. Cancel revokes the result and requests network shutdown."}else{"Transcribing the stopped recording locally… Cancel discards the result; inference may finish cleanup in the background."});
        // Runs on the same dedicated owner, with capture already stopped. The
        // UI never waits. Shared generation revokes results during this call.
        let shared = self.shared.clone();
        let generation = self.generation;
        let cancelled = || {
            !shared.alive.load(Ordering::Acquire)
                || !shared.enabled.load(Ordering::Acquire)
                || shared.generation.load(Ordering::Acquire) != generation
        };
        let inference = self.inference.as_mut().unwrap();
        let result = match &configuration {
            RecordingConfig::Local(config) => inference.transcribe(config, &audio.wav, &cancelled),
            RecordingConfig::Hosted(config) => inference.hosted(config, &audio.wav, &cancelled),
        };
        if !self.current() {
            self.reset();
            return;
        }
        self.phase = Phase::Idle;
        match result {
            Ok(text) if !text.trim().is_empty() => {
                self.text_pending = self
                    .text
                    .send(TextReady {
                        generation: self.generation,
                        binding,
                        text,
                    })
                    .is_ok();
                self.publish("Transcript ready for the matching composer. Nothing was sent.");
            }
            Ok(_) => self.publish("No speech text was returned. Composer unchanged."),
            Err(InferenceFailure::Cancelled) => {
                self.phase = Phase::Idle;
                self.publish("Dictation cancelled; no text inserted.");
            }
            Err(InferenceFailure::CleanupPending) => {
                self.phase = Phase::Failed;
                self.publish("Transcription cleanup is uncertain. Private audio was retained; no transcript was inserted.");
            }
            Err(InferenceFailure::Hosted(error)) => {
                use coincide_core::dictation::transcription::Error;
                self.phase = Phase::Failed;
                self.publish(match error {Error::Unauthorized|Error::Forbidden=>"Voice service rejected this key or account. Update the separate Voice API key.",Error::RateLimited=>"Voice service rate limit reached. Nothing was inserted or sent.",Error::TooLarge=>"Voice service response exceeded the receive limit. Nothing was inserted or sent.",Error::Server|Error::Network=>"Voice service unavailable or request timed out. Nothing was inserted or sent.",_=>"Voice transcription was rejected or unreadable. Check the selected model and language."});
            }
            Err(InferenceFailure::Failed) => {
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
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CallbackShutdown {
    NeverConstructed,
    Unknown,
}
/// Rust owner join is distinct from native callback-queue cleanup acceptance.
/// Native release stays unknown while backend cleanup lacks an ACK; ordinary
/// process exit has its separate, narrower owner-join predicate.
#[derive(Clone, Debug)]
pub struct ShutdownStatus {
    pub requested: bool,
    pub worker: WorkerThreadStatus,
    pub native_callbacks: CallbackShutdown,
    pub spawn_error: Option<String>,
}
impl ShutdownStatus {
    /// Process exit only, after controller destruction and actual Rust join.
    /// Late permission/audio callbacks own only isolated native state, never
    /// Engine/Store authority. This does not certify native release for updater.
    pub fn ordinary_exit_ready(&self) -> bool {
        self.requested && self.worker == WorkerThreadStatus::Returned && self.spawn_error.is_none()
    }
}
struct Connection {
    shared: Arc<Shared>,
    commands: SyncSender<Command>,
    snapshots: Receiver<Snapshot>,
    completion: Option<WorkerCompletion>,
    spawn_error: Option<String>,
}
impl Connection {
    fn request_shutdown(&self) {
        self.shared.enabled.store(false, Ordering::Release);
        if self.shared.alive.swap(false, Ordering::AcqRel) {
            self.shared.generation.fetch_add(1, Ordering::AcqRel);
        }
        self.discard_snapshots();
    }
    fn discard_snapshots(&self) {
        for _ in self.snapshots.try_iter() {}
    }
    fn shutdown_status(&self) -> ShutdownStatus {
        let requested = !self.shared.alive.load(Ordering::Acquire);
        if requested {
            self.discard_snapshots();
        }
        let worker = self
            .completion
            .as_ref()
            .map_or(WorkerThreadStatus::Unclassified, WorkerCompletion::status);
        if requested {
            self.discard_snapshots();
        }
        ShutdownStatus {
            requested,
            worker,
            native_callbacks: if self.shared.controller_constructed.load(Ordering::Acquire) {
                CallbackShutdown::Unknown
            } else {
                CallbackShutdown::NeverConstructed
            },
            spawn_error: self.spawn_error.clone(),
        }
    }
}
fn spawn_owner(factory: Factory) -> (Connection, Receiver<TextReady>) {
    let shared = Arc::new(Shared {
        enabled: AtomicBool::new(false),
        generation: AtomicU64::new(0),
        alive: AtomicBool::new(true),
        controller_constructed: AtomicBool::new(false),
    });
    let (commands, receiver) = mpsc::sync_channel(8);
    let (snapshots, updates) = mpsc::channel();
    let (text, events) = mpsc::channel();
    let state = shared.clone();
    let worker = std::thread::Builder::new()
        .name("coincide-microphone-owner".into())
        .spawn(move || {
            // Factory is invoked lazily on THIS thread, only with a compiled backend and an
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
                dictation: false,
                progress_bucket: None,
                text_pending: false,
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
    let (completion, spawn_error) = match worker {
        Ok(worker) => (Some(WorkerCompletion::observe(worker)), None),
        Err(error) => {
            shared.enabled.store(false, Ordering::Release);
            shared.alive.store(false, Ordering::Release);
            (None, Some(error.to_string().chars().take(1024).collect()))
        }
    };
    (
        Connection {
            shared,
            commands,
            snapshots: updates,
            completion,
            spawn_error,
        },
        events,
    )
}
impl Drop for Connection {
    fn drop(&mut self) {
        self.request_shutdown();
    }
}

/// Parent supplies the existing local-model snapshot and compiled capability.
/// Neither a capability nor settings grant OS permission or start recording.
/// Only explicit native actions can request access, capture or transcribe.
pub struct MicrophoneSettings {
    connection: Connection,
    target: Target,
    generation: u64,
    backend_enabled: bool,
    phase: Phase,
    permission: Permission,
    status: String,
    listening_since: Option<std::time::Instant>,
    progress: Option<CaptureProgress>,
    text_pending: bool,
}
impl MicrophoneSettings {
    pub fn new() -> (Self, Receiver<TextReady>) {
        Self::with_factory(Box::new(|| {
            (Box::new(Microphone::new()), Box::new(LocalInference))
        }))
    }
    fn with_factory(factory: Factory) -> (Self, Receiver<TextReady>) {
        let (connection, events) = spawn_owner(factory);
        (Self { connection, target: Target { binding: None, settings_revision: 0, config: None }, generation: 0, backend_enabled: false, phase: Phase::Idle, permission: Permission::Unavailable, status: "This build has no native microphone backend. File transcription remains available.".into(), listening_since:None, progress:None, text_pending:false }, events)
    }
    #[cfg(test)]
    pub fn set_target(
        &mut self,
        binding: Option<ComposerBinding>,
        settings_revision: u64,
        configuration: Option<LocalRecordingConfig>,
        backend_enabled: bool,
        cx: &mut Context<Self>,
    ) {
        self.set_configuration_target(
            binding,
            settings_revision,
            configuration.map(RecordingConfig::Local),
            backend_enabled,
            cx,
        );
    }
    pub fn set_configuration_target(
        &mut self,
        binding: Option<ComposerBinding>,
        settings_revision: u64,
        configuration: Option<RecordingConfig>,
        backend_enabled: bool,
        cx: &mut Context<Self>,
    ) {
        if !self.connection.shared.alive.load(Ordering::Acquire) {
            return;
        }
        let target = Target {
            binding,
            settings_revision,
            config: configuration,
        };
        if self.target != target || self.backend_enabled != backend_enabled {
            self.connection
                .shared
                .enabled
                .store(false, Ordering::Release);
            self.generation = self
                .connection
                .shared
                .generation
                .fetch_add(1, Ordering::AcqRel)
                .wrapping_add(1);
            self.text_pending = false;
            self.target = target;
            self.backend_enabled = backend_enabled;
            self.phase = Phase::Idle;
            self.permission = Permission::Unavailable;
            self.connection
                .shared
                .enabled
                .store(backend_enabled, Ordering::Release);
            self.status = if backend_enabled { "Target/configuration changed. Previous recording/results are discarded. Use Enable Microphone before Record." } else { "This build has no native microphone backend. File transcription remains available." }.into();
            cx.notify();
        }
    }
    pub fn request_shutdown(&mut self) {
        self.connection.request_shutdown();
        self.text_pending = false;
        self.generation = self.connection.shared.generation.load(Ordering::Acquire);
        self.backend_enabled = false;
        self.target.binding = None;
        self.target.config = None;
        self.phase = Phase::Idle;
        self.permission = Permission::Unavailable;
    }
    pub fn shutdown_status(&mut self) -> ShutdownStatus {
        self.connection.shutdown_status()
    }
    pub fn cancel(&mut self, cx: &mut Context<Self>) {
        if !self.connection.shared.alive.load(Ordering::Acquire) {
            return;
        }
        self.generation = self
            .connection
            .shared
            .generation
            .fetch_add(1, Ordering::AcqRel)
            .wrapping_add(1);
        self.phase = Phase::Idle;
        self.permission = Permission::Unavailable;
        self.text_pending = false;
        self.status = "Cancellation requested; recording/results are discarded. An existing OS permission dialog may still need your response. Inference cleanup may finish in the background.".into();
        cx.notify();
    }
    pub fn configured_for_dictation(&self) -> bool {
        self.backend_enabled
            && self.connection.shared.alive.load(Ordering::Acquire)
            && self.target.binding.is_some()
            && self.target.config.is_some()
    }
    pub fn failed(&self) -> bool {
        self.phase == Phase::Failed
    }
    pub fn begin_dictation(&mut self, cx: &mut Context<Self>) -> u64 {
        self.action(Action::BeginDictation, cx);
        self.generation
    }
    pub fn intent_generation(&self) -> Option<u64> {
        (self.connection.shared.alive.load(Ordering::Acquire)
            && self.backend_enabled
            && (self.dictation_active() || self.text_pending))
            .then_some(self.generation)
    }
    pub fn stop_dictation(&mut self, cx: &mut Context<Self>) {
        if self.phase == Phase::Recording {
            self.action(Action::Stop, cx);
        } else if matches!(self.phase, Phase::Permission | Phase::Pending) {
            self.cancel(cx);
        }
    }
    pub fn dictation_active(&self) -> bool {
        matches!(
            self.phase,
            Phase::Pending
                | Phase::Permission
                | Phase::Recording
                | Phase::Stopping
                | Phase::Transcribing
        )
    }
    pub fn level(&self) -> Option<f32> {
        if self.phase == Phase::Recording {
            self.progress.map(|p| p.level)
        } else {
            None
        }
    }
    pub fn status_text(&self) -> String {
        if self.phase == Phase::Recording
            && let Some(progress) = self.progress
        {
            return format!(
                "Listening · {:.1}s",
                progress.captured_samples as f64 / 16_000.0
            );
        }
        if self.phase == Phase::Recording {
            format!(
                "Listening · {}s",
                self.listening_since
                    .map(|since| since.elapsed().as_secs())
                    .unwrap_or(0)
            )
        } else {
            self.status.clone()
        }
    }
    pub fn accepts_text(&self, event: &TextReady, live: &ComposerBinding) -> bool {
        self.backend_enabled
            && self.connection.shared.alive.load(Ordering::Acquire)
            && event.generation == self.generation
            && event.binding == *live
            && self.target.binding.as_ref() == Some(live)
    }
    pub fn poll(&mut self, cx: &mut Context<Self>) {
        if !self.connection.shared.alive.load(Ordering::Acquire) {
            self.connection.discard_snapshots();
            return;
        }
        while let Ok(snapshot) = self.connection.snapshots.try_recv() {
            if snapshot.generation == self.generation && self.backend_enabled {
                if snapshot.phase == Phase::Recording && self.phase != Phase::Recording {
                    self.listening_since = Some(std::time::Instant::now());
                }
                if snapshot.phase != Phase::Recording {
                    self.listening_since = None;
                }
                self.progress = snapshot.progress;
                self.text_pending = snapshot.text_pending;
                self.phase = snapshot.phase;
                self.permission = snapshot.permission;
                self.status = snapshot.message.into();
                cx.notify();
            }
        }
    }
    fn action(&mut self, action: Action, cx: &mut Context<Self>) {
        if !self.backend_enabled || !self.connection.shared.alive.load(Ordering::Acquire) {
            return;
        }
        // Beginning a new explicit request invalidates any older queued text.
        if matches!(
            action,
            Action::Enable | Action::Record | Action::BeginDictation
        ) {
            self.text_pending = false;
        }
        if matches!(
            action,
            Action::Enable | Action::Record | Action::BeginDictation
        ) {
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
        let gated = !self.backend_enabled;
        div().flex().flex_col().gap_2().p_4().child("Microphone → local transcription")
            .child("Enable permission, Record, Stop, then Transcribe Recording. Permission grants never start capture. Nothing is sent automatically.")
            .child(Button::new("microphone-enable").label("Enable Microphone").disabled(gated || !matches!(self.phase, Phase::Idle | Phase::Failed)).on_click(cx.listener(|this, _, _, cx| this.action(Action::Enable, cx))))
            .child(Button::new("microphone-record").label("Record").disabled(gated || !matches!(self.permission, Permission::Authorized | Permission::Ready) || !matches!(self.phase, Phase::Idle | Phase::Captured | Phase::Failed) || self.target.binding.is_none() || self.target.config.is_none()).on_click(cx.listener(|this, _, _, cx| this.action(Action::Record, cx))))
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
        ready_permission: bool,
        empty_inference: bool,
        fail_inference: bool,
        progress: Option<CaptureProgress>,
        threads: Vec<ThreadId>,
        closed: Option<Sender<()>>,
        drop_gate: Option<Receiver<()>>,
    }
    struct FakeController {
        trace: Arc<Mutex<Trace>>,
        binding: Option<CaptureBinding>,
        session: Option<Uuid>,
        events: VecDeque<CaptureEvent>,
    }
    impl Controller for FakeController {
        fn progress(&self) -> Option<CaptureProgress> {
            self.trace.lock().unwrap().progress
        }
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
                .push_back(CaptureEvent::PermissionChanged(if trace.ready_permission {
                    Permission::Ready
                } else {
                    Permission::Authorized
                }));
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
            if let Some(release) = trace.drop_gate.take() {
                let _ = release.recv();
            }
        }
    }
    struct FakeInference {
        trace: Arc<Mutex<Trace>>,
        revoke: Option<Arc<Shared>>,
    }
    impl Inference for FakeInference {
        fn hosted(
            &mut self,
            config: &coincide_core::dictation::voice_api::HostedConfig,
            wav: &[u8],
            cancelled: &(dyn Fn() -> bool + Sync),
        ) -> Result<String, InferenceFailure> {
            use coincide_core::dictation::transcription::{Error, Request, Response, Transport};
            struct FakeHttp;
            impl Transport for FakeHttp {
                fn send(&mut self, request: &Request) -> Result<Response, Error> {
                    assert_eq!(
                        request.endpoint(),
                        "https://api.openai.com/v1/audio/transcriptions"
                    );
                    assert_eq!(request.method(), "POST");
                    Ok(Response {
                        status: 200,
                        body: br#"{"text":"synthetic hosted worker transcript"}"#.to_vec(),
                    })
                }
            }
            self.trace.lock().unwrap().inference += 1;
            assert_eq!(config.model, "gpt-transcribe");
            config
                .transcribe_with_transport(wav, cancelled, FakeHttp)
                .map_err(InferenceFailure::Hosted)
        }
        fn transcribe(
            &mut self,
            config: &LocalRecordingConfig,
            wav: &[u8],
            cancelled: &(dyn Fn() -> bool + Sync),
        ) -> Result<String, InferenceFailure> {
            assert!(
                !cancelled(),
                "current native owner passes a live cancellation receipt"
            );
            assert_eq!(config.language, "en");
            assert!(wav.starts_with(b"RIFF"));
            let mut trace = self.trace.lock().unwrap();
            trace.inference += 1;
            trace.threads.push(thread::current().id());
            if let Some(shared) = &self.revoke {
                shared.generation.fetch_add(1, Ordering::AcqRel);
                assert!(
                    cancelled(),
                    "worker generation revocation must reach local process cancellation"
                );
            }
            if trace.fail_inference {
                return Err(InferenceFailure::Failed);
            }
            if trace.empty_inference {
                return Ok(String::new());
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
            config: Some(RecordingConfig::Local(LocalRecordingConfig {
                executable: PathBuf::from("/synthetic/whisper"),
                model: PathBuf::from("/synthetic/model"),
                language: "en".into(),
                threads: 2,
                maximum_seconds: 1,
            })),
        }
    }
    fn setup(
        accepted: bool,
        revoke_on_inference: bool,
    ) -> (Owner, Receiver<TextReady>, Arc<Mutex<Trace>>) {
        let shared = Arc::new(Shared {
            enabled: AtomicBool::new(accepted),
            generation: AtomicU64::new(1),
            alive: AtomicBool::new(true),
            controller_constructed: AtomicBool::new(false),
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
            dictation: false,
            progress_bucket: None,
            text_pending: false,
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
    fn hosted_dictation_runs_exact_private_snapshot_through_fake_transport_on_owned_path() {
        use coincide_core::dictation::{
            transcription::Provider,
            voice_api::HostedConfig,
            voice_secret::{Backend, Failure, VoiceSecrets},
        };
        struct FakeSecret;
        impl Backend for FakeSecret {
            fn read(&self, _: Provider) -> Result<zeroize::Zeroizing<String>, Failure> {
                Ok(zeroize::Zeroizing::new("synthetic-owned-voice-key".into()))
            }
            fn write(&self, _: Provider, _: &str) -> Result<(), Failure> {
                panic!("no OS save")
            }
            fn delete(&self, _: Provider) -> Result<(), Failure> {
                panic!("no OS delete")
            }
        }
        let credential = VoiceSecrets::with_backend(Arc::new(FakeSecret))
            .load(Provider::OpenAi)
            .unwrap();
        let (mut owner, events, trace) = setup(true, false);
        let mut target = target();
        target.config = Some(RecordingConfig::Hosted(HostedConfig::new(
            credential,
            "gpt-transcribe".into(),
            Some("en".into()),
        )));
        owner.command(Command {
            generation: 1,
            target: target.clone(),
            action: Action::BeginDictation,
        });
        owner.tick();
        assert_eq!(trace.lock().unwrap().starts, 1);
        owner.command(Command {
            generation: 1,
            target,
            action: Action::Stop,
        });
        owner.tick();
        let transcript = events.try_recv().unwrap();
        assert_eq!(transcript.text, "synthetic hosted worker transcript");
        assert_eq!(trace.lock().unwrap().inference, 1);
        assert!(owner.text_pending);
        assert!(events.try_recv().is_err());
    }
    #[::core::prelude::v1::test]
    fn empty_or_failed_actual_inference_produces_no_pending_send_receipt() {
        for failure in [false, true] {
            let (mut owner, events, trace) = setup(true, false);
            trace.lock().unwrap().empty_inference = !failure;
            trace.lock().unwrap().fail_inference = failure;
            action(&mut owner, Action::BeginDictation);
            action(&mut owner, Action::Stop);
            assert_eq!(trace.lock().unwrap().inference, 1);
            assert!(
                !owner.text_pending,
                "only a successfully queued nonempty transcript produces a delivery receipt"
            );
            assert!(events.try_recv().is_err());
            assert!(!matches!(
                owner.phase,
                Phase::Recording | Phase::Transcribing | Phase::Stopping
            ));
        }
    }
    #[::core::prelude::v1::test]
    fn native_progress_is_bound_to_actual_recording_session_and_generation() {
        let (mut owner, _, trace) = setup(true, false);
        action(&mut owner, Action::BeginDictation);
        let session = owner.session.unwrap();
        trace.lock().unwrap().progress = Some(CaptureProgress {
            session,
            captured_samples: 16_000,
            level: 0.5,
        });
        assert_eq!(owner.progress().unwrap().captured_samples, 16_000);
        trace.lock().unwrap().progress.as_mut().unwrap().session = Uuid::new_v4();
        assert!(
            owner.progress().is_none(),
            "another session must never animate this recording"
        );
        trace.lock().unwrap().progress = Some(CaptureProgress {
            session,
            captured_samples: 16_000,
            level: f32::NAN,
        });
        assert!(owner.progress().is_none());
        trace.lock().unwrap().progress = Some(CaptureProgress {
            session,
            captured_samples: 16_000,
            level: 0.5,
        });
        owner.shared.generation.store(2, Ordering::Release);
        assert!(
            owner.progress().is_none(),
            "revoked targets must not retain native progress"
        );
        owner.shared.generation.store(1, Ordering::Release);
        action(&mut owner, Action::Stop);
        assert!(
            owner.progress().is_none(),
            "finished audio is not a live meter"
        );
    }
    #[::core::prelude::v1::test]
    fn native_dictation_intent_continues_matching_permission_and_transcribes_stop_once() {
        let (mut owner, events, trace) = setup(true, false);
        action(&mut owner, Action::BeginDictation);
        assert_eq!(trace.lock().unwrap().requests, 1);
        assert_eq!(trace.lock().unwrap().starts, 1);
        assert_eq!(trace.lock().unwrap().inference, 0);
        assert!(owner.phase == Phase::Recording);
        action(&mut owner, Action::Stop);
        assert_eq!(trace.lock().unwrap().inference, 1);
        assert!(
            events.try_recv().unwrap().binding == target().binding.unwrap(),
            "dictation result keeps its exact captured composer binding"
        );
        action(&mut owner, Action::Transcribe);
        assert!(events.try_recv().is_err());
        assert_eq!(trace.lock().unwrap().inference, 1);
    }
    #[::core::prelude::v1::test]
    fn dictation_generation_revoke_prevents_automatic_inference() {
        let (mut owner, events, trace) = setup(true, false);
        action(&mut owner, Action::BeginDictation);
        owner.shared.generation.store(2, Ordering::Release);
        action(&mut owner, Action::Stop);
        assert_eq!(trace.lock().unwrap().inference, 0);
        assert!(events.try_recv().is_err());
        assert!(!owner.dictation);
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
    fn desktop_preparation_is_distinct_from_os_permission_and_never_starts_capture() {
        let (mut owner, events, trace) = setup(true, false);
        trace.lock().unwrap().ready_permission = true;
        action(&mut owner, Action::Record);
        assert_eq!(trace.lock().unwrap().starts, 0);
        action(&mut owner, Action::Enable);
        assert_eq!(owner.permission, Permission::Ready);
        assert_ne!(owner.permission, Permission::Authorized);
        assert_eq!(trace.lock().unwrap().starts, 0);
        action(&mut owner, Action::Record);
        assert_eq!(trace.lock().unwrap().starts, 1);
        action(&mut owner, Action::Stop);
        assert!(events.try_recv().is_err());
        action(&mut owner, Action::Transcribe);
        assert_eq!(
            events.try_recv().unwrap().text,
            "synthetic recorded transcript"
        );
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
        connection.shared.enabled.store(true, Ordering::Release);
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
    struct ShutdownTls {
        entered: Sender<()>,
        release: Receiver<()>,
    }
    impl Drop for ShutdownTls {
        fn drop(&mut self) {
            let _ = self.entered.send(());
            let _ = self.release.recv();
        }
    }
    thread_local! { static SHUTDOWN_TLS:std::cell::RefCell<Option<ShutdownTls>>=const { std::cell::RefCell::new(None) }; }
    fn wait_join(connection: &Connection) -> ShutdownStatus {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            let status = connection.shutdown_status();
            if status.worker != WorkerThreadStatus::Running {
                return status;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "fake microphone owner did not join"
            );
            thread::yield_now();
        }
    }
    fn queued(connection: &Connection, action: Action) {
        assert!(
            connection
                .commands
                .try_send(Command {
                    generation: 1,
                    target: target(),
                    action
                })
                .is_ok()
        );
    }
    fn until_snapshot(connection: &Connection, predicate: impl Fn(&Snapshot) -> bool) {
        loop {
            let snapshot = connection
                .snapshots
                .recv_timeout(Duration::from_secs(5))
                .unwrap();
            if predicate(&snapshot) {
                return;
            }
        }
    }
    fn enable(connection: &Connection) {
        connection.shared.generation.store(1, Ordering::Release);
        connection.shared.enabled.store(true, Ordering::Release);
        queued(connection, Action::Enable);
        until_snapshot(connection, |snapshot| {
            snapshot.permission == Permission::Authorized
        });
    }
    #[::core::prelude::v1::test]
    fn shutdown_without_native_acceptance_never_constructs_controller_and_is_irreversible() {
        let (connection, events) = spawn_owner(Box::new(|| {
            panic!("closed owner must not construct microphone")
        }));
        let mut panel = MicrophoneSettings {
            connection,
            target: target(),
            generation: 0,
            backend_enabled: true,
            phase: Phase::Idle,
            permission: Permission::Unavailable,
            status: String::new(),
            listening_since: None,
            progress: None,
            text_pending: false,
        };
        let binding = panel.target.binding.clone().unwrap();
        let stale = TextReady {
            generation: 0,
            binding: binding.clone(),
            text: "previously queued private text".into(),
        };
        assert!(panel.accepts_text(&stale, &binding));
        panel.request_shutdown();
        let generation = panel.generation;
        panel.request_shutdown();
        assert_eq!(panel.generation, generation);
        assert!(!panel.backend_enabled);
        assert!(!panel.accepts_text(&stale, &binding));
        assert!(panel.target.binding.is_none());
        assert!(panel.target.config.is_none());
        let status = wait_join(&panel.connection);
        assert!(status.requested);
        assert_eq!(status.worker, WorkerThreadStatus::Returned);
        assert_eq!(status.native_callbacks, CallbackShutdown::NeverConstructed);
        assert!(events.try_recv().is_err());
        assert!(!panel.connection.shared.enabled.load(Ordering::Acquire));
    }
    #[::core::prelude::v1::test]
    fn owner_shutdown_waits_for_controller_drop_and_actual_tls_join() {
        let trace = Arc::new(Mutex::new(Trace::default()));
        let (drop_tx, drop_rx) = mpsc::channel();
        let (drop_release_tx, drop_release_rx) = mpsc::channel();
        trace.lock().unwrap().closed = Some(drop_tx);
        trace.lock().unwrap().drop_gate = Some(drop_release_rx);
        let (tls_tx, tls_rx) = mpsc::channel();
        let (tls_release_tx, tls_release_rx) = mpsc::channel();
        let make = factory(trace, None);
        let (connection, events) = spawn_owner(Box::new(move || {
            SHUTDOWN_TLS.with(|slot| {
                *slot.borrow_mut() = Some(ShutdownTls {
                    entered: tls_tx,
                    release: tls_release_rx,
                })
            });
            make()
        }));
        enable(&connection);
        connection.request_shutdown();
        drop_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(
            connection.shutdown_status().worker,
            WorkerThreadStatus::Running
        );
        assert_eq!(
            connection.shutdown_status().native_callbacks,
            CallbackShutdown::Unknown
        );
        assert!(!connection.shutdown_status().ordinary_exit_ready());
        drop_release_tx.send(()).unwrap();
        tls_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(
            connection.shutdown_status().worker,
            WorkerThreadStatus::Running
        );
        tls_release_tx.send(()).unwrap();
        let status = wait_join(&connection);
        assert_eq!(status.worker, WorkerThreadStatus::Returned);
        assert!(status.ordinary_exit_ready());
        assert_eq!(
            status.native_callbacks,
            CallbackShutdown::Unknown,
            "Rust join cannot invent native callback cleanup ACK"
        );
        assert!(events.try_recv().is_err());
    }
    struct ShutdownInference {
        entered: Sender<()>,
        release: Receiver<()>,
        tls_entered: Sender<()>,
        tls_release: Option<Receiver<()>>,
    }
    impl Inference for ShutdownInference {
        fn transcribe(
            &mut self,
            _: &LocalRecordingConfig,
            _: &[u8],
            _: &(dyn Fn() -> bool + Sync),
        ) -> Result<String, InferenceFailure> {
            SHUTDOWN_TLS.with(|slot| {
                *slot.borrow_mut() = Some(ShutdownTls {
                    entered: self.tls_entered.clone(),
                    release: self.tls_release.take().unwrap(),
                })
            });
            self.entered.send(()).unwrap();
            self.release.recv().unwrap();
            Ok("synthetic private recording transcript".into())
        }
    }
    #[::core::prelude::v1::test]
    fn shutdown_during_fake_inference_discards_private_text_and_late_commands() {
        let trace = Arc::new(Mutex::new(Trace::default()));
        let check = trace.clone();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (tls_tx, tls_rx) = mpsc::channel();
        let (tls_release_tx, tls_release_rx) = mpsc::channel();
        let (connection, events) = spawn_owner(Box::new(move || {
            (
                Box::new(FakeController {
                    trace,
                    binding: None,
                    session: None,
                    events: VecDeque::new(),
                }),
                Box::new(ShutdownInference {
                    entered: entered_tx,
                    release: release_rx,
                    tls_entered: tls_tx,
                    tls_release: Some(tls_release_rx),
                }),
            )
        }));
        enable(&connection);
        queued(&connection, Action::Record);
        until_snapshot(&connection, |snapshot| snapshot.phase == Phase::Recording);
        queued(&connection, Action::Stop);
        until_snapshot(&connection, |snapshot| snapshot.phase == Phase::Captured);
        queued(&connection, Action::Transcribe);
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        connection.request_shutdown();
        // Even a queued command in the private mailbox cannot run after close.
        let _ = connection.commands.try_send(Command {
            generation: 1,
            target: target(),
            action: Action::Enable,
        });
        assert_eq!(
            connection.shutdown_status().worker,
            WorkerThreadStatus::Running
        );
        release_tx.send(()).unwrap();
        tls_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(events.try_recv().is_err());
        assert_eq!(
            connection.shutdown_status().worker,
            WorkerThreadStatus::Running
        );
        tls_release_tx.send(()).unwrap();
        assert_eq!(wait_join(&connection).worker, WorkerThreadStatus::Returned);
        assert!(events.try_recv().is_err());
        assert!(connection.snapshots.try_recv().is_err());
        assert_eq!(check.lock().unwrap().requests, 1);
        assert_eq!(check.lock().unwrap().starts, 1);
    }
    #[::core::prelude::v1::test]
    fn panicked_microphone_factory_is_not_successful_owner_cleanup() {
        let (connection, events) =
            spawn_owner(Box::new(|| panic!("synthetic microphone factory failure")));
        connection.shared.generation.store(1, Ordering::Release);
        connection.shared.enabled.store(true, Ordering::Release);
        queued(&connection, Action::Enable);
        let status = wait_join(&connection);
        assert_eq!(status.worker, WorkerThreadStatus::Panicked);
        assert_eq!(status.native_callbacks, CallbackShutdown::Unknown);
        assert!(events.try_recv().is_err());
    }
}

#[cfg(test)]
#[path = "microphone_ui_tests.rs"]
mod native_tests;
