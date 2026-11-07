//! Explicit native capture controls. Compiled capability enables actions;
//! construction/rendering never request permission, record, transcribe or send.
use crate::{
    microphone::{
        CaptureBinding, CaptureChunk, CaptureError, CaptureEvent, CaptureProgress, CapturedAudio,
        InputDevice, Microphone, Permission,
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
    prelude::FluentBuilder,
};
use std::{
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, Sender, SyncSender},
    },
    time::Duration,
};
use uuid::Uuid;

#[derive(Clone, PartialEq, Eq)]
pub struct LocalRecordingConfig {
    pub model_proof: Option<Arc<coincide_core::dictation::model_assets::VerifiedModel>>,
    pub executable: PathBuf,
    pub model: PathBuf,
    pub language: String,
    pub threads: usize,
    pub maximum_seconds: usize,
}
#[derive(Clone, PartialEq, Eq)]
pub enum RecordingConfig {
    Local(LocalRecordingConfig),
    Apple(crate::voice_speech::Configuration),
    Hosted(coincide_core::dictation::voice_api::HostedConfig),
}
impl RecordingConfig {
    fn maximum_seconds(&self) -> usize {
        match self {
            Self::Local(config) => config.maximum_seconds,
            Self::Apple(config) => config.maximum_seconds,
            Self::Hosted(config) => config.maximum_seconds,
        }
    }
}
#[derive(Clone, PartialEq, Eq)]
struct Target {
    binding: Option<ComposerBinding>,
    settings_revision: u64,
    input_device_uid: Option<String>,
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
    RefreshDevices,
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
    /// Apple Speech refused this app's speech-recognition access.
    speech_denied: bool,
    message: &'static str,
    progress: Option<CaptureProgress>,
    text_pending: bool,
}
struct DeviceReply {
    generation: u64,
    result: Result<Vec<InputDevice>, CaptureError>,
}
struct PartialPreview {
    generation: u64,
    binding: ComposerBinding,
    text: String,
}
struct Shared {
    preview: Mutex<Option<PartialPreview>>,
    enabled: AtomicBool,
    generation: AtomicU64,
    alive: AtomicBool,
    controller_constructed: AtomicBool,
}
trait Controller {
    fn read_chunk(
        &mut self,
        _: Uuid,
        _: usize,
        _: usize,
    ) -> Result<Option<CaptureChunk>, CaptureError> {
        Ok(None)
    }
    fn input_devices(&mut self) -> Result<Vec<InputDevice>, CaptureError> {
        Err(CaptureError::Unavailable)
    }
    fn start_on_device(&mut self, seconds: usize, uid: Option<&str>) -> Result<Uuid, CaptureError> {
        if uid.is_some() {
            Err(CaptureError::NoInput)
        } else {
            self.start(seconds)
        }
    }
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
    fn read_chunk(
        &mut self,
        session: Uuid,
        offset: usize,
        limit: usize,
    ) -> Result<Option<CaptureChunk>, CaptureError> {
        Microphone::read_chunk(self, session, offset, limit)
    }
    fn input_devices(&mut self) -> Result<Vec<InputDevice>, CaptureError> {
        Microphone::input_devices(self)
    }
    fn start_on_device(&mut self, seconds: usize, uid: Option<&str>) -> Result<Uuid, CaptureError> {
        if uid.is_none() {
            Microphone::start(self, seconds)
        } else {
            Microphone::start_on_device(self, seconds, uid)
        }
    }
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
    /// The system denied speech-recognition access.
    #[cfg_attr(
        not(all(target_os = "macos", feature = "native-microphone")),
        allow(dead_code)
    )]
    Denied,
    Cancelled,
    CleanupPending,
    Hosted(coincide_core::dictation::transcription::Error),
}
type ModelLease = Arc<coincide_core::dictation::model_assets::ModelReadLease>;
trait Inference {
    fn stream_apple(
        &mut self,
        _: usize,
        _: &[f32],
        _: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), InferenceFailure> {
        Err(InferenceFailure::Failed)
    }
    fn apple_partial(&mut self) -> Option<String> {
        None
    }
    fn prepare_apple(
        &mut self,
        _: &crate::voice_speech::Configuration,
        _: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), InferenceFailure> {
        Err(InferenceFailure::Failed)
    }
    fn apple(
        &mut self,
        _: &[u8],
        _: &(dyn Fn() -> bool + Sync),
    ) -> Result<String, InferenceFailure> {
        Err(InferenceFailure::Failed)
    }
    fn cancel_apple(&mut self) {}

    fn prepare_model(
        &mut self,
        _: &LocalRecordingConfig,
        _: &(dyn Fn() -> bool + Sync),
    ) -> Result<Option<ModelLease>, InferenceFailure> {
        Ok(None)
    }
    fn transcribe_with_model(
        &mut self,
        config: &LocalRecordingConfig,
        wav: &[u8],
        _: Option<&ModelLease>,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<String, InferenceFailure> {
        self.transcribe(config, wav, cancelled)
    }

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
#[derive(Default)]
struct LocalInference {
    apple: Option<crate::voice_speech::Session>,
    apple_uncertain: bool,
}
fn apple_failure(error: crate::voice_speech::Error) -> InferenceFailure {
    match error {
        #[cfg(all(target_os = "macos", feature = "native-microphone"))]
        crate::voice_speech::Error::Denied => InferenceFailure::Denied,
        crate::voice_speech::Error::Cancelled => InferenceFailure::Cancelled,
        crate::voice_speech::Error::CleanupPending => InferenceFailure::CleanupPending,
        _ => InferenceFailure::Failed,
    }
}

impl Inference for LocalInference {
    fn stream_apple(
        &mut self,
        offset: usize,
        samples: &[f32],
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), InferenceFailure> {
        let result = self
            .apple
            .as_mut()
            .ok_or(InferenceFailure::Failed)?
            .stream(offset, samples, cancelled);
        if let Err(error) = result {
            if error == crate::voice_speech::Error::CleanupPending {
                self.apple_uncertain = true;
            }
            self.cancel_apple();
            return Err(apple_failure(error));
        }
        Ok(())
    }
    fn apple_partial(&mut self) -> Option<String> {
        self.apple.as_mut()?.partial()
    }
    fn prepare_apple(
        &mut self,
        config: &crate::voice_speech::Configuration,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), InferenceFailure> {
        if self.apple_uncertain {
            return Err(InferenceFailure::CleanupPending);
        }
        if self.apple.is_some() {
            return Ok(());
        }
        match crate::voice_speech::Session::prepare(config, cancelled) {
            Ok(session) => {
                self.apple = Some(session);
                Ok(())
            }
            Err(error) => {
                if error == crate::voice_speech::Error::CleanupPending {
                    self.apple_uncertain = true;
                }
                Err(apple_failure(error))
            }
        }
    }
    fn apple(
        &mut self,
        wav: &[u8],
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<String, InferenceFailure> {
        let mut session = self.apple.take().ok_or(InferenceFailure::Failed)?;
        let mut result = session.transcribe(wav, cancelled);
        if !result
            .as_ref()
            .is_err_and(|error| *error == crate::voice_speech::Error::CleanupPending)
            && session.cancel() == Err(crate::voice_speech::Error::CleanupPending)
        {
            result = Err(crate::voice_speech::Error::CleanupPending);
        }
        if result
            .as_ref()
            .is_err_and(|error| *error == crate::voice_speech::Error::CleanupPending)
        {
            self.apple_uncertain = true;
        }
        result.map_err(apple_failure)
    }
    fn cancel_apple(&mut self) {
        if let Some(mut session) = self.apple.take() {
            if session.cancel() == Err(crate::voice_speech::Error::CleanupPending) {
                self.apple_uncertain = true;
            }
        }
    }

    fn prepare_model(
        &mut self,
        config: &LocalRecordingConfig,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<Option<ModelLease>, InferenceFailure> {
        if let Some(model) = &config.model_proof {
            if model.path() != config.model {
                return Err(InferenceFailure::Failed);
            }
            return model
                .acquire(cancelled)
                .map(Some)
                .map_err(|_| InferenceFailure::Failed);
        }
        coincide_core::dictation::model_assets::acquire_model_path(&config.model, cancelled)
            .map(Some)
            .map_err(|_| InferenceFailure::Failed)
    }
    fn transcribe_with_model(
        &mut self,
        config: &LocalRecordingConfig,
        wav: &[u8],
        lease: Option<&ModelLease>,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<String, InferenceFailure> {
        let lease = lease.ok_or(InferenceFailure::Failed)?;
        LocalWhisper::new(
            config.executable.clone(),
            config.model.clone(),
            config.language.clone(),
            config.threads,
            Duration::from_secs(120),
        )
        .map_err(|_| InferenceFailure::Failed)?
        .transcribe_local_with_lease(wav, lease, cancelled)
        .map_err(|error| match error {
            LocalError::Cancelled => InferenceFailure::Cancelled,
            LocalError::CleanupPending => InferenceFailure::CleanupPending,
            _ => InferenceFailure::Failed,
        })
    }

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
    devices: SyncSender<DeviceReply>,
    generation: u64,
    target: Option<Target>,
    phase: Phase,
    permission: Permission,
    permission_target: Option<Target>,
    speech_denied: bool,
    session: Option<Uuid>,
    audio: Option<CapturedAudio>,
    model_lease: Option<ModelLease>,
    stream_offset: usize,
    stream_generation: Option<u64>,
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
                speech_denied: self.speech_denied,
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
        self.model_lease = None;
        self.stream_offset = 0;
        self.stream_generation = None;
        self.shared
            .preview
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .take();
        if let Some(inference) = &mut self.inference {
            inference.cancel_apple();
        }
        self.session = None;
        self.dictation = false;
        self.target = None;
        self.phase = Phase::Idle;
    }
    fn prepare_model(&mut self) -> bool {
        if let Some(RecordingConfig::Apple(config)) = self
            .target
            .as_ref()
            .and_then(|target| target.config.as_ref())
        {
            let config = config.clone();
            let previous_phase = self.phase;
            self.phase = Phase::Pending;
            self.publish("Preparing on-device Apple Speech. Its language assets or system authorization may be required. Cancel revokes this exact request.");
            let shared = self.shared.clone();
            let generation = self.generation;
            let cancelled = || {
                !shared.alive.load(Ordering::Acquire)
                    || !shared.enabled.load(Ordering::Acquire)
                    || shared.generation.load(Ordering::Acquire) != generation
            };
            let result = self
                .inference
                .as_mut()
                .unwrap()
                .prepare_apple(&config, &cancelled);
            self.speech_denied = matches!(result, Err(InferenceFailure::Denied));
            if let Err(error) = result {
                self.phase = Phase::Failed;
                self.publish(match error {
                    InferenceFailure::CleanupPending => "Apple Speech cancellation has not returned. No recording started. Restart before another Apple request.",
                    // Swift DictationError.speechRecognitionDenied.
                    InferenceFailure::Denied => "Coincide isn’t allowed to use speech recognition. Turn it on in System Settings › Privacy & Security › Speech Recognition.",
                    _ => "On-device Apple Speech could not prepare for this language or authorization. Nothing was recorded. Local Whisper remains available.",
                });
                return false;
            }
            self.phase = previous_phase;
            return true;
        }
        if self.model_lease.is_some() {
            return true;
        }
        let Some(RecordingConfig::Local(config)) =
            self.target.as_ref().and_then(|t| t.config.as_ref())
        else {
            return true;
        };
        let shared = self.shared.clone();
        let generation = self.generation;
        let cancelled = || {
            !shared.alive.load(Ordering::Acquire)
                || !shared.enabled.load(Ordering::Acquire)
                || shared.generation.load(Ordering::Acquire) != generation
        };
        match self
            .inference
            .as_mut()
            .unwrap()
            .prepare_model(config, &cancelled)
        {
            Ok(lease) => {
                self.model_lease = lease;
                true
            }
            Err(_) => {
                self.phase = Phase::Failed;
                self.publish("The selected local model is unavailable or being removed. No recording started.");
                false
            }
        }
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
            Action::RefreshDevices
                if matches!(self.phase, Phase::Idle | Phase::Captured | Phase::Failed) =>
            {
                let result = self.controller.as_mut().unwrap().input_devices();
                if self.current() {
                    let _ = self.devices.try_send(DeviceReply {
                        generation: self.generation,
                        result,
                    });
                }
            }
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
                if !self.prepare_model() {
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
                        self.model_lease = None;
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
                if !self.prepare_model() {
                    return;
                }
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
                match self.controller.as_mut().unwrap().start_on_device(
                    configuration.maximum_seconds(),
                    target.input_device_uid.as_deref(),
                ) {
                    Ok(session) => {
                        self.session = Some(session);
                        self.phase = Phase::Recording;
                        self.publish(if self.dictation {"Listening. Stop transcribes this recording using the captured Voice settings."}else{"Recording locally. Stop ends capture; it does not transcribe or send."});
                    }
                    Err(error) => {
                        self.model_lease = None;
                        self.phase = Phase::Failed;
                        self.publish(match error { CaptureError::Busy => "Another native owner is using the microphone.", CaptureError::NoInput => "The requested microphone is unavailable or unsupported. No fallback input was opened.", _ => "Recording could not start. Check authorization, device and configured limits." });
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
    fn stream_capture(&mut self) -> bool {
        if !self.dictation
            || !matches!(self.phase, Phase::Recording | Phase::Stopping)
            || !matches!(
                self.target.as_ref().and_then(|t| t.config.as_ref()),
                Some(RecordingConfig::Apple(_))
            )
        {
            return true;
        }
        let Some(session) = self.session else {
            return true;
        };
        for _ in 0..8 {
            let chunk = match self.controller.as_mut().unwrap().read_chunk(
                session,
                self.stream_offset,
                4096,
            ) {
                Ok(Some(chunk)) => chunk,
                Ok(None) => break,
                Err(_) => return false,
            };
            if chunk.session != session
                || chunk.offset != self.stream_offset
                || chunk.samples.is_empty()
                || chunk.samples.len() > 4096
                || chunk.samples.iter().any(|s| !s.is_finite())
                || self
                    .target
                    .as_ref()
                    .and_then(Target::capture_binding)
                    .as_ref()
                    != Some(&chunk.binding)
                || self
                    .stream_generation
                    .is_some_and(|generation| generation != chunk.generation)
            {
                return false;
            }
            let maximum = self
                .target
                .as_ref()
                .and_then(|t| t.config.as_ref())
                .map(|config| config.maximum_seconds())
                .unwrap_or(0)
                .saturating_mul(16_000);
            if chunk
                .offset
                .checked_add(chunk.samples.len())
                .is_none_or(|end| end > maximum)
            {
                return false;
            }
            self.stream_generation = Some(chunk.generation);
            let shared = self.shared.clone();
            let generation = self.generation;
            let cancelled = || {
                !shared.alive.load(Ordering::Acquire)
                    || !shared.enabled.load(Ordering::Acquire)
                    || shared.generation.load(Ordering::Acquire) != generation
            };
            if self
                .inference
                .as_mut()
                .unwrap()
                .stream_apple(chunk.offset, &chunk.samples, &cancelled)
                .is_err()
            {
                return false;
            }
            self.stream_offset += chunk.samples.len();
        }
        if !self.current() {
            return false;
        }
        if let Some(text) = self.inference.as_mut().unwrap().apple_partial() {
            if text.len() > 1_048_576 {
                return false;
            }
            if let Some(binding) = self
                .target
                .as_ref()
                .and_then(|target| target.binding.clone())
            {
                *self
                    .shared
                    .preview
                    .lock()
                    .unwrap_or_else(|p| p.into_inner()) = Some(PartialPreview {
                    generation: self.generation,
                    binding,
                    text,
                });
            }
        }
        true
    }
    fn tick(&mut self) {
        if !self.current() {
            if self.target.is_some() {
                self.reset();
            }
            return;
        }
        if !self.stream_capture() {
            self.reset();
            self.phase = Phase::Failed;
            self.publish(
                "Dictation stream changed or failed. Partial preview discarded; no text inserted.",
            );
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
                    self.model_lease = None;
                    self.publish(match permission {
                        Permission::Authorized => "Microphone permission granted. Press Record to begin; nothing is recording.",
                        Permission::Ready => "Microphone is ready. Record opens the selected device; system privacy settings may still deny access. Nothing is recording.",
                        // Swift DictationError.microphoneDenied.
                        Permission::Denied | Permission::Restricted if cfg!(target_os = "macos") => "Coincide doesn’t have access to the microphone. Turn it on in System Settings › Privacy & Security › Microphone.",
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
                    let valid = self
                        .stream_generation
                        .is_none_or(|generation| generation == audio.generation)
                        && self.session == Some(audio.session)
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
                    self.model_lease = None;
                    self.text_pending = false;
                    self.audio = None;
                    self.session = None;
                    self.phase = Phase::Failed;
                    self.publish("Native capture failed. Nothing was transcribed or sent.");
                }
                CaptureEvent::Cancelled => {
                    self.model_lease = None;
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
            RecordingConfig::Local(config) => inference.transcribe_with_model(
                config,
                &audio.wav,
                self.model_lease.as_ref(),
                &cancelled,
            ),
            RecordingConfig::Hosted(config) => inference.hosted(config, &audio.wav, &cancelled),
            RecordingConfig::Apple(_) => inference.apple(&audio.wav, &cancelled),
        };
        if matches!(&result, Err(InferenceFailure::CleanupPending)) {
            if let Some(lease) = self.model_lease.take() {
                coincide_core::dictation::model_assets::retain_uncertain(lease);
            }
        }
        if !self.current() {
            self.reset();
            return;
        }
        self.phase = Phase::Idle;
        let model_lease = self.model_lease.take();
        match result {
            Ok(text) if !text.trim().is_empty() => {
                self.text_pending = self
                    .text
                    .send(TextReady {
                        generation: self.generation,
                        binding,
                        text,
                        _model_lease: model_lease,
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
            Err(InferenceFailure::Failed | InferenceFailure::Denied) => {
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
    devices: Receiver<DeviceReply>,
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
        if let Ok(mut preview) = self.shared.preview.try_lock() {
            preview.take();
        }
        for _ in self.snapshots.try_iter() {}
        for _ in self.devices.try_iter() {}
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
        preview: Mutex::new(None),
    });
    let (commands, receiver) = mpsc::sync_channel(8);
    let (snapshots, updates) = mpsc::channel();
    let (text, events) = mpsc::channel();
    let (device_sender, devices) = mpsc::sync_channel(1);
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
                devices: device_sender,
                generation: 0,
                target: None,
                phase: Phase::Idle,
                permission: Permission::Unavailable,
                permission_target: None,
                speech_denied: false,
                session: None,
                audio: None,
                model_lease: None,
                stream_offset: 0,
                stream_generation: None,
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
            devices,
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
    partial_preview: Option<String>,
    connection: Connection,
    target: Target,
    generation: u64,
    backend_enabled: bool,
    phase: Phase,
    permission: Permission,
    speech_denied: bool,
    status: String,
    listening_since: Option<std::time::Instant>,
    progress: Option<CaptureProgress>,
    text_pending: bool,
    device_catalog: Option<Vec<InputDevice>>,
    device_refreshing: bool,
    device_status: String,
}
impl MicrophoneSettings {
    pub fn new() -> (Self, Receiver<TextReady>) {
        Self::with_factory(Box::new(|| {
            (
                Box::new(Microphone::new()),
                Box::new(LocalInference::default()),
            )
        }))
    }
    fn with_factory(factory: Factory) -> (Self, Receiver<TextReady>) {
        let (connection, events) = spawn_owner(factory);
        (Self { partial_preview:None,connection, target: Target { binding: None, settings_revision: 0, input_device_uid:None, config: None }, generation: 0, backend_enabled: false, phase: Phase::Idle, permission: Permission::Unavailable, speech_denied: false, status: "This build has no native microphone backend. File transcription remains available.".into(), listening_since:None, progress:None, text_pending:false, device_catalog:None,device_refreshing:false,device_status:"Input devices have not been refreshed.".into() }, events)
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
            None,
            backend_enabled,
            cx,
        );
    }
    pub fn set_configuration_target(
        &mut self,
        binding: Option<ComposerBinding>,
        settings_revision: u64,
        configuration: Option<RecordingConfig>,
        input_device_uid: Option<String>,
        backend_enabled: bool,
        cx: &mut Context<Self>,
    ) {
        if !self.connection.shared.alive.load(Ordering::Acquire) {
            return;
        }
        let target = Target {
            binding,
            settings_revision,
            input_device_uid,
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
            self.partial_preview = None;
            self.device_refreshing = false;
            self.device_refreshing = false;
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
        self.partial_preview = None;
        self.text_pending = false;
        self.device_refreshing = false;
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
        self.partial_preview = None;
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
        self.device_refreshing = false;
        self.status = "Cancellation requested; recording/results are discarded. An existing OS permission dialog may still need your response. Inference cleanup may finish in the background.".into();
        cx.notify();
    }
    pub fn devices(&self) -> Option<&[InputDevice]> {
        self.device_catalog.as_deref()
    }
    pub fn device_status(&self) -> &str {
        &self.device_status
    }
    pub fn device_refreshing(&self) -> bool {
        self.device_refreshing
    }
    pub fn refresh_devices(&mut self, cx: &mut Context<Self>) {
        if !self.backend_enabled
            || self.device_refreshing
            || self.dictation_active()
            || !self.connection.shared.alive.load(Ordering::Acquire)
        {
            return;
        }
        let command = Command {
            generation: self.generation,
            target: self.target.clone(),
            action: Action::RefreshDevices,
        };
        if self.connection.commands.try_send(command).is_ok() {
            self.device_refreshing = true;
            self.device_status = "Refreshing input metadata on the owned worker…".into();
        } else {
            self.device_status = "The capture owner is busy. Device refresh was not queued.".into();
        }
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
    /// The privacy setting that stopped the last dictation, which the user
    /// can turn on in System Settings (Swift DictationError.opensSystemSettings).
    pub fn denial(&self) -> Option<crate::voice_system::Denial> {
        use crate::voice_system::Denial;
        if !cfg!(target_os = "macos") || self.dictation_active() {
            None
        } else if matches!(self.permission, Permission::Denied | Permission::Restricted) {
            Some(Denial::Microphone)
        } else if self.speech_denied {
            Some(Denial::SpeechRecognition)
        } else {
            None
        }
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
    pub fn partial_preview(&self) -> Option<&str> {
        self.dictation_active()
            .then_some(self.partial_preview.as_deref())
            .flatten()
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
        while let Ok(reply) = self.connection.devices.try_recv() {
            if reply.generation != self.generation || !self.backend_enabled {
                continue;
            }
            self.device_refreshing = false;
            match reply.result {Ok(devices)=>{self.device_catalog=Some(devices);self.device_status="Input metadata refreshed. Selecting a device does not record.".into();},Err(_)=>self.device_status="Input devices could not be refreshed. The saved choice was retained; no permission was requested.".into()}
            cx.notify();
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
                self.speech_denied = snapshot.speech_denied;
                self.status = snapshot.message.into();
                cx.notify();
            }
        }
        let preview = self
            .connection
            .shared
            .preview
            .try_lock()
            .ok()
            .and_then(|mut slot| slot.take());
        if let Some(preview) = preview {
            if preview.generation == self.generation
                && self.target.binding.as_ref() == Some(&preview.binding)
                && self.dictation_active()
            {
                self.partial_preview = Some(preview.text);
                cx.notify();
            }
        }
        if !self.dictation_active() {
            self.partial_preview = None;
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
            self.device_refreshing = false;
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
            .when_some(self.partial_preview(),|pane,text|pane.child(div().max_h(gpui_kit::px(64.0)).overflow_hidden().child("Dictation preview (final insertion after Stop)").child(text.to_owned())))
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
        apple_prepared: bool,
        apple_prepare_calls: usize,
        streaming: bool,
        wrong_chunk: bool,
        chunk_generation: Option<u64>,
        streamed_samples: usize,
        ready_permission: bool,
        device_queries: usize,
        selected_inputs: Vec<Option<String>>,
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
        fn read_chunk(
            &mut self,
            session: Uuid,
            offset: usize,
            _: usize,
        ) -> Result<Option<CaptureChunk>, CaptureError> {
            let trace = self.trace.lock().unwrap();
            if !trace.streaming || offset >= 2 {
                return Ok(None);
            }
            let mut binding = self.binding.clone().unwrap();
            if trace.wrong_chunk {
                binding.thread_id = "foreign-thread".into();
            }
            Ok(Some(CaptureChunk {
                session,
                generation: trace.chunk_generation.unwrap_or(1),
                binding,
                offset,
                samples: vec![0.0, 0.5],
            }))
        }
        fn input_devices(&mut self) -> Result<Vec<InputDevice>, CaptureError> {
            self.trace.lock().unwrap().device_queries += 1;
            Ok(vec![InputDevice {
                uid: "fixture-mic".into(),
                name: "Synthetic input".into(),
                is_default: true,
            }])
        }
        fn start_on_device(
            &mut self,
            seconds: usize,
            uid: Option<&str>,
        ) -> Result<Uuid, CaptureError> {
            self.trace
                .lock()
                .unwrap()
                .selected_inputs
                .push(uid.map(str::to_owned));
            if uid.is_some_and(|uid| uid != "fixture-mic") {
                Err(CaptureError::NoInput)
            } else {
                self.start(seconds)
            }
        }

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
            let mut trace = self
                .trace
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
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
            let mut trace = self
                .trace
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
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
        fn stream_apple(
            &mut self,
            offset: usize,
            samples: &[f32],
            cancelled: &(dyn Fn() -> bool + Sync),
        ) -> Result<(), InferenceFailure> {
            assert!(!cancelled());
            let mut trace = self.trace.lock().unwrap();
            assert!(trace.apple_prepared);
            assert_eq!(offset, trace.streamed_samples);
            trace.streamed_samples += samples.len();
            Ok(())
        }
        fn apple_partial(&mut self) -> Option<String> {
            let trace = self.trace.lock().unwrap();
            (trace.streaming && trace.streamed_samples > 0).then(|| "途中の合成音声".into())
        }
        fn prepare_apple(
            &mut self,
            config: &crate::voice_speech::Configuration,
            cancelled: &(dyn Fn() -> bool + Sync),
        ) -> Result<(), InferenceFailure> {
            assert_eq!(config.locale, "ja-JP");
            assert!(!cancelled());
            let mut trace = self.trace.lock().unwrap();
            if trace.apple_prepared {
                return Ok(());
            }
            assert_eq!(
                trace.requests, 0,
                "speech preparation precedes the admitted capture permission/start"
            );
            trace.apple_prepare_calls += 1;
            if trace.fail_inference {
                return Err(InferenceFailure::Failed);
            }
            trace.apple_prepared = true;
            Ok(())
        }
        fn apple(
            &mut self,
            wav: &[u8],
            cancelled: &(dyn Fn() -> bool + Sync),
        ) -> Result<String, InferenceFailure> {
            assert!(!cancelled());
            assert!(wav.starts_with(b"RIFF"));
            let mut trace = self.trace.lock().unwrap();
            assert!(trace.apple_prepared);
            trace.inference += 1;
            Ok("合成音声の文字起こし".into())
        }
        fn cancel_apple(&mut self) {
            self.trace
                .lock()
                .unwrap_or_else(|poison| poison.into_inner())
                .apple_prepared = false;
        }

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
            input_device_uid: None,
            config: Some(RecordingConfig::Local(LocalRecordingConfig {
                model_proof: None,
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
            preview: Mutex::new(None),
        });
        let trace = Arc::new(Mutex::new(Trace::default()));
        let (text, events) = mpsc::channel();
        let (snapshots, _) = mpsc::channel();
        let (devices, _) = mpsc::sync_channel(1);
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
            devices,
            generation: 0,
            target: None,
            phase: Phase::Idle,
            permission: Permission::Unavailable,
            permission_target: None,
            speech_denied: false,
            session: None,
            audio: None,
            model_lease: None,
            stream_offset: 0,
            stream_generation: None,
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
    fn explicit_device_refresh_is_metadata_only_and_never_requests_permission_or_records() {
        let (mut owner, events, trace) = setup(true, false);
        let (sender, results) = mpsc::sync_channel(1);
        owner.devices = sender;
        action(&mut owner, Action::RefreshDevices);
        let reply = results.try_recv().unwrap();
        assert_eq!(reply.generation, 1);
        let devices = reply.result.unwrap();
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].uid, "fixture-mic");
        let trace = trace.lock().unwrap();
        assert_eq!(trace.device_queries, 1);
        assert_eq!(trace.requests, 0);
        assert_eq!(trace.starts, 0);
        assert_eq!(trace.inference, 0);
        assert!(events.try_recv().is_err());
    }
    #[::core::prelude::v1::test]
    fn apple_engine_fake_prepares_before_capture_and_uses_exact_utf8_target() {
        let (mut owner, events, trace) = setup(true, false);
        let mut target = target();
        target.config = Some(RecordingConfig::Apple(crate::voice_speech::Configuration {
            locale: "ja-JP".into(),
            maximum_seconds: 1,
        }));
        owner.command(Command {
            generation: 1,
            target: target.clone(),
            action: Action::BeginDictation,
        });
        owner.tick();
        assert_eq!(trace.lock().unwrap().starts, 1);
        assert!(events.try_recv().is_err());
        owner.command(Command {
            generation: 1,
            target: target.clone(),
            action: Action::Stop,
        });
        owner.tick();
        let event = events.try_recv().unwrap();
        assert_eq!(event.text, "合成音声の文字起こし");
        assert!(target.binding == Some(event.binding));
        let trace = trace.lock().unwrap();
        assert_eq!(trace.apple_prepare_calls, 1);
        assert_eq!(trace.requests, 1);
        assert_eq!(trace.inference, 1);
    }
    #[::core::prelude::v1::test]
    fn apple_stream_preview_is_bounded_and_never_a_composer_or_send_receipt() {
        let (mut owner, events, trace) = setup(true, false);
        trace.lock().unwrap().streaming = true;
        let mut target = target();
        target.config = Some(RecordingConfig::Apple(crate::voice_speech::Configuration {
            locale: "ja-JP".into(),
            maximum_seconds: 1,
        }));
        owner.command(Command {
            generation: 1,
            target: target.clone(),
            action: Action::BeginDictation,
        });
        owner.tick();
        assert!(
            matches!(owner.phase, Phase::Recording),
            "first turn admits the capture before any streamed read"
        );
        owner.tick(); // actual next owner turn reads the published prefix

        assert_eq!(trace.lock().unwrap().streamed_samples, 2);
        assert!(
            events.try_recv().is_err(),
            "partial preview never mints final text/send authority"
        );
        let preview = owner.shared.preview.lock().unwrap().take().unwrap();
        assert_eq!(preview.text, "途中の合成音声");
        assert!(target.binding.as_ref() == Some(&preview.binding));
        assert_eq!(preview.generation, 1);
        owner.tick();
        assert_eq!(
            trace.lock().unwrap().streamed_samples,
            2,
            "published audio is not replayed"
        );
        owner.shared.generation.fetch_add(1, Ordering::AcqRel);
        owner.tick();
        assert!(owner.shared.preview.lock().unwrap().is_none());
        assert!(events.try_recv().is_err());
    }
    #[::core::prelude::v1::test]
    fn final_audio_must_have_the_actual_generation_of_its_streamed_prefix() {
        let (mut owner, events, trace) = setup(true, false);
        {
            let mut trace = trace.lock().unwrap();
            trace.streaming = true;
            trace.chunk_generation = Some(2);
        }
        let mut target = target();
        target.config = Some(RecordingConfig::Apple(crate::voice_speech::Configuration {
            locale: "ja-JP".into(),
            maximum_seconds: 1,
        }));
        owner.command(Command {
            generation: 1,
            target: target.clone(),
            action: Action::BeginDictation,
        });
        owner.tick();
        assert!(
            matches!(owner.phase, Phase::Recording),
            "first turn admits the capture before any streamed read"
        );
        owner.tick(); // actual next owner turn reads the published prefix

        assert_eq!(trace.lock().unwrap().streamed_samples, 2);
        owner.command(Command {
            generation: 1,
            target,
            action: Action::Stop,
        });
        owner.tick();
        assert_eq!(
            trace.lock().unwrap().inference,
            0,
            "a mismatched final source must never finalize the earlier stream"
        );
        assert!(events.try_recv().is_err());
        assert!(owner.shared.preview.lock().unwrap().is_none());
    }
    #[::core::prelude::v1::test]
    fn foreign_chunk_is_rejected_before_speech_and_cancels_the_actual_owner() {
        let (mut owner, events, trace) = setup(true, false);
        {
            let mut trace = trace.lock().unwrap();
            trace.streaming = true;
            trace.wrong_chunk = true;
        }
        let mut target = target();
        target.config = Some(RecordingConfig::Apple(crate::voice_speech::Configuration {
            locale: "ja-JP".into(),
            maximum_seconds: 1,
        }));
        owner.command(Command {
            generation: 1,
            target,
            action: Action::BeginDictation,
        });
        owner.tick();
        assert!(
            matches!(owner.phase, Phase::Recording),
            "first turn admits the capture before any streamed read"
        );
        owner.tick(); // actual next owner turn reads the published prefix

        let trace = trace.lock().unwrap();
        assert_eq!(trace.streamed_samples, 0);
        assert_eq!(trace.cancels, 1);
        assert!(owner.shared.preview.lock().unwrap().is_none());
        assert!(events.try_recv().is_err());
    }
    #[::core::prelude::v1::test]
    fn failed_apple_preparation_never_opens_microphone_or_emits_text() {
        let (mut owner, events, trace) = setup(true, false);
        trace.lock().unwrap().fail_inference = true;
        let mut target = target();
        target.config = Some(RecordingConfig::Apple(crate::voice_speech::Configuration {
            locale: "ja-JP".into(),
            maximum_seconds: 1,
        }));
        owner.command(Command {
            generation: 1,
            target,
            action: Action::BeginDictation,
        });
        owner.tick();
        let trace = trace.lock().unwrap();
        assert_eq!(trace.apple_prepare_calls, 1);
        assert_eq!(trace.requests, 0);
        assert_eq!(trace.starts, 0);
        assert_eq!(trace.inference, 0);
        assert!(events.try_recv().is_err());
    }
    #[::core::prelude::v1::test]
    fn missing_selected_input_never_falls_back_and_exact_selection_is_forwarded() {
        for (uid, expected_starts) in [("removed-mic", 0), ("fixture-mic", 1)] {
            let (mut owner, events, trace) = setup(true, false);
            let mut target = target();
            target.input_device_uid = Some(uid.into());
            owner.command(Command {
                generation: 1,
                target,
                action: Action::BeginDictation,
            });
            owner.tick();
            let trace = trace.lock().unwrap();
            assert_eq!(trace.selected_inputs, vec![Some(uid.into())]);
            assert_eq!(trace.starts, expected_starts);
            assert_eq!(trace.inference, 0);
            assert!(events.try_recv().is_err());
            assert_eq!(
                owner.target.as_ref().unwrap().input_device_uid.as_deref(),
                Some(uid)
            );
        }
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
            partial_preview: None,
            connection,
            target: target(),
            generation: 0,
            backend_enabled: true,
            phase: Phase::Idle,
            permission: Permission::Unavailable,
            speech_denied: false,
            status: String::new(),
            listening_since: None,
            progress: None,
            text_pending: false,
            device_catalog: None,
            device_refreshing: false,
            device_status: String::new(),
        };
        let binding = panel.target.binding.clone().unwrap();
        let stale = TextReady {
            _model_lease: None,
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
