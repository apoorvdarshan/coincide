//! Native, explicit local-WAV transcription. Parent owns composer insertion;
//! this module never sends a message, captures audio, downloads or discovers tools.
use coincide_core::dictation::local::{LocalError, LocalWhisper};
use gpui_kit::{
    AppContext, Context, Entity, IntoElement, ParentElement, PathPromptOptions, Render,
    SharedString, Styled, Subscription, Window,
    component::{
        Disableable,
        button::Button,
        input::{Input, InputEvent, InputState},
    },
    div,
};
use std::{
    fs::{File, OpenOptions},
    io::Read,
    ops::Range,
    path::PathBuf,
    sync::{
        Arc,
        mpsc::{self, Receiver, Sender},
    },
    time::Duration,
};
use uuid::Uuid;
const MAX_WAV: u64 = 25_000_000;

/// Parent must increment composer_revision on every text/selection change,
/// including switching away and back. Selection offsets are Rust UTF-8 bytes.
#[derive(Clone, PartialEq, Eq)]
pub struct ComposerBinding {
    pub thread_id: String,
    pub composer_revision: u64,
    pub selection: Range<usize>,
}
/// Personal transcript: deliberately no Debug/Serialize or persistence.
/// Parent rechecks accepts_text against LIVE binding immediately before using
/// DictationSession::start/update for insertion. Never automatically send it.
pub struct TextReady {
    pub generation: u64,
    pub binding: ComposerBinding,
    pub text: String,
}
#[derive(Clone)]
struct Configuration {
    executable: PathBuf,
    model: PathBuf,
    wav: PathBuf,
    language: String,
    threads: usize,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Failure {
    Configuration,
    Audio,
    TooLarge,
    Unavailable,
    Timeout,
    Process,
    Output,
}
trait Backend: Send + Sync {
    fn transcribe(&self, configuration: Configuration) -> Result<String, Failure>;
}
struct LocalBackend;
impl Backend for LocalBackend {
    fn transcribe(&self, configuration: Configuration) -> Result<String, Failure> {
        let mut backend = LocalWhisper::new(
            configuration.executable,
            configuration.model,
            configuration.language,
            configuration.threads,
            Duration::from_secs(120),
        )
        .map_err(classify)?;
        let wav = read_wav(configuration.wav)?;
        backend.transcribe_local(&wav).map_err(classify)
    }
}
fn classify(error: LocalError) -> Failure {
    match error {
        LocalError::InvalidConfiguration => Failure::Configuration,
        LocalError::InvalidAudio => Failure::Audio,
        LocalError::TooLarge => Failure::TooLarge,
        LocalError::TimedOut => Failure::Timeout,
        LocalError::ProcessFailed => Failure::Process,
        LocalError::InvalidOutput => Failure::Output,
        LocalError::UnsupportedPlatform | LocalError::Unavailable => Failure::Unavailable,
    }
}
fn read_wav(path: PathBuf) -> Result<Vec<u8>, Failure> {
    if !path.is_absolute() {
        return Err(Failure::Configuration);
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // Linux O_NOFOLLOW | O_NONBLOCK: reject symlinks and do not hang on
        // a FIFO substituted after the native picker returns.
        options.custom_flags(0x20000 | 0x800);
    }
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // Darwin O_NOFOLLOW | O_NONBLOCK (different values from Linux).
        options.custom_flags(0x100 | 0x4);
    }
    let file: File = options.open(path).map_err(|_| Failure::Audio)?;
    let metadata = file.metadata().map_err(|_| Failure::Audio)?;
    if !metadata.is_file() {
        return Err(Failure::Audio);
    }
    if metadata.len() > MAX_WAV {
        return Err(Failure::TooLarge);
    }
    let mut wav = Vec::new();
    file.take(MAX_WAV + 1)
        .read_to_end(&mut wav)
        .map_err(|_| Failure::Audio)?;
    if wav.len() as u64 > MAX_WAV {
        return Err(Failure::TooLarge);
    }
    Ok(wav)
}
struct Finished {
    job: Uuid,
    generation: u64,
    binding: ComposerBinding,
    result: Result<String, Failure>,
}
struct Workflow {
    generation: u64,
    binding: Option<ComposerBinding>,
    running: Option<Uuid>,
    backend: Arc<dyn Backend>,
    sender: Sender<Finished>,
    results: Receiver<Finished>,
    text: Sender<TextReady>,
}
enum Completion {
    Ready,
    Empty,
    Stale,
    Failed(Failure),
}
impl Workflow {
    fn new(backend: Arc<dyn Backend>) -> (Self, Receiver<TextReady>) {
        let (sender, results) = mpsc::channel();
        let (text, events) = mpsc::channel();
        (
            Self {
                generation: 0,
                binding: None,
                running: None,
                backend,
                sender,
                results,
                text,
            },
            events,
        )
    }
    fn invalidate(&mut self) {
        self.generation = self.generation.wrapping_add(1);
    }
    fn set_binding(&mut self, binding: Option<ComposerBinding>) -> bool {
        if self.binding == binding {
            return false;
        }
        self.invalidate();
        self.binding = binding;
        true
    }
    fn start(&mut self, configuration: Configuration) -> bool {
        if self.running.is_some() {
            return false;
        }
        let Some(binding) = self.binding.clone() else {
            return false;
        };
        self.invalidate();
        let job = Uuid::new_v4();
        self.running = Some(job);
        let generation = self.generation;
        let backend = self.backend.clone();
        let sender = self.sender.clone();
        std::thread::spawn(move || {
            let result = backend.transcribe(configuration);
            let _ = sender.send(Finished {
                job,
                generation,
                binding,
                result,
            });
        });
        true
    }
    fn poll(&mut self) -> Option<Completion> {
        let result = self.results.try_recv().ok()?;
        if self.running != Some(result.job) {
            return Some(Completion::Stale);
        }
        self.running = None;
        if result.generation != self.generation || self.binding.as_ref() != Some(&result.binding) {
            return Some(Completion::Stale);
        }
        match result.result {
            Ok(text) if text.trim().is_empty() => Some(Completion::Empty),
            Ok(text) => {
                let _ = self.text.send(TextReady {
                    generation: result.generation,
                    binding: result.binding,
                    text,
                });
                Some(Completion::Ready)
            }
            Err(error) => Some(Completion::Failed(error)),
        }
    }
    fn accepts(&self, event: &TextReady, current: &ComposerBinding) -> bool {
        event.generation == self.generation
            && event.binding == *current
            && self.binding.as_ref() == Some(current)
    }
}
#[derive(Clone, Copy)]
enum FileKind {
    Executable,
    Model,
    Wav,
}
/// Constructor uses only session memory; no executable discovery or vault reads.
/// Parent registers this module, displays its entity, calls set_binding/poll on
/// the native UI tick, and receives TextReady from the constructor's receiver.
pub struct TranscriptionSettings {
    executable: Option<PathBuf>,
    model: Option<PathBuf>,
    wav: Option<PathBuf>,
    language: Entity<InputState>,
    threads: usize,
    workflow: Workflow,
    picker: bool,
    status: String,
    _language_changes: Subscription,
}
impl TranscriptionSettings {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> (Self, Receiver<TextReady>) {
        let language =
            cx.new(|cx| InputState::new(window, cx).placeholder("Language code, e.g. en or auto"));
        language.update(cx, |input, cx| input.set_value("en", window, cx));
        let changes = cx.subscribe(&language, |this, _, event, cx| {
            if matches!(event, InputEvent::Change) {
                this.workflow.invalidate();
                this.status =
                    "Language changed. Press Transcribe to run the selected files.".into();
                cx.notify();
            }
        });
        let (workflow, events) = Workflow::new(Arc::new(LocalBackend));
        (Self { executable: None, model: None, wav: None, language, threads: 2, workflow, picker: false,
            status: "Choose a whisper-cli executable, compatible model, and 16 kHz mono PCM WAV. Nothing runs until Transcribe.".into(), _language_changes: changes }, events)
    }
    pub fn set_binding(&mut self, binding: Option<ComposerBinding>, cx: &mut Context<Self>) {
        if self.workflow.set_binding(binding) {
            self.status = if self.workflow.running.is_some() {
                "Composer changed. The running result will be discarded."
            } else {
                "Composer target updated. Press Transcribe when ready."
            }
            .into();
            cx.notify();
        }
    }
    pub fn accepts_text(&self, event: &TextReady, current: &ComposerBinding) -> bool {
        self.workflow.accepts(event, current)
    }
    pub fn poll(&mut self, cx: &mut Context<Self>) {
        while let Some(completion) = self.workflow.poll() {
            self.status = match completion {
                Completion::Ready => "Transcript ready for the matching composer. Nothing was sent.",
                Completion::Empty => "No speech text was returned. Composer unchanged.",
                Completion::Stale => "Result discarded because the configuration or composer changed.",
                Completion::Failed(Failure::Configuration) => "Configuration is invalid. Check executable, model, language and threads.",
                Completion::Failed(Failure::Audio) => "Choose a valid 16 kHz mono 16-bit PCM WAV. Other rates/formats are not converted.",
                Completion::Failed(Failure::TooLarge) => "Audio or transcript exceeds the backend's size limit (WAV maximum 25 MB).",
                Completion::Failed(Failure::Unavailable) => "Local transcription is unavailable. Check platform, executable/model access, and temporary storage.",
                Completion::Failed(Failure::Timeout) => "Transcription exceeded 120 seconds. Process cleanup completed; composer unchanged.",
                Completion::Failed(Failure::Process) => "whisper-cli failed. Check model compatibility and installed runtime resources.",
                Completion::Failed(Failure::Output) => "whisper-cli did not produce a valid bounded JSON transcript.",
            }.into();
            cx.notify();
        }
    }
    fn choose(&mut self, kind: FileKind, cx: &mut Context<Self>) {
        if self.picker || self.workflow.running.is_some() {
            return;
        }
        self.workflow.invalidate();
        let generation = self.workflow.generation;
        self.picker = true;
        let prompt = match kind {
            FileKind::Executable => "Choose whisper-cli executable",
            FileKind::Model => "Choose local Whisper model",
            FileKind::Wav => "Choose 16 kHz mono PCM WAV",
        };
        let picker = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some(prompt.into()),
        });
        cx.spawn(async move |this, cx| {
            let paths: anyhow::Result<_> = async { Ok(picker.await??) }.await;
            let _ = this.update(cx, |this, cx| {
                this.picker = false;
                if this.workflow.generation != generation { this.status = "File choice discarded because the composer/settings changed.".into(); cx.notify(); return; }
                match paths {
                    Ok(Some(paths)) if paths.len() == 1 && paths[0].is_absolute() => {
                        let path = paths.into_iter().next();
                        match kind { FileKind::Executable => this.executable = path, FileKind::Model => this.model = path, FileKind::Wav => this.wav = path }
                        this.status = "File selected. Press Transcribe to run locally; configuration is not yet verified by inference.".into();
                    },
                    Ok(None) => this.status = "File selection cancelled. Nothing was transcribed.".into(),
                    _ => this.status = "Could not select a single local file.".into(),
                }
                cx.notify();
            });
        }).detach();
        cx.notify();
    }
    fn transcribe(&mut self, cx: &mut Context<Self>) {
        if self.picker || !cfg!(any(target_os = "macos", target_os = "linux")) {
            return;
        }
        let (Some(executable), Some(model), Some(wav)) = (
            self.executable.clone(),
            self.model.clone(),
            self.wav.clone(),
        ) else {
            self.status = "Choose all three files first.".into();
            cx.notify();
            return;
        };
        let configuration = Configuration {
            executable,
            model,
            wav,
            language: self.language.read(cx).value().to_string().trim().into(),
            threads: self.threads,
        };
        if self.workflow.start(configuration) {
            self.status =
                "Transcribing locally… Results apply only to the original composer revision."
                    .into();
            cx.notify();
        }
    }
}
fn file_label(path: &Option<PathBuf>, empty: &str) -> String {
    path.as_ref()
        .and_then(|p| p.file_name())
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| empty.into())
}
impl Render for TranscriptionSettings {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let busy = self.picker || self.workflow.running.is_some();
        let mut panel = div().flex().flex_col().gap_2().p_4().child("Local file transcription")
            .child("Requires a configured whisper.cpp CLI, compatible local model, and 16 kHz mono 16-bit PCM WAV. No microphone capture or automatic sending.");
        for (kind, id, label) in [
            (
                FileKind::Executable,
                "transcription-executable",
                format!(
                    "Executable: {}",
                    file_label(&self.executable, "Choose whisper-cli")
                ),
            ),
            (
                FileKind::Model,
                "transcription-model",
                format!("Model: {}", file_label(&self.model, "Choose model")),
            ),
            (
                FileKind::Wav,
                "transcription-wav",
                format!("Audio: {}", file_label(&self.wav, "Choose WAV")),
            ),
        ] {
            panel = panel.child(
                Button::new(id)
                    .label(label)
                    .disabled(busy)
                    .on_click(cx.listener(move |this, _, _, cx| this.choose(kind, cx))),
            );
        }
        panel = panel
            .child("Language code (en, another supported code, or auto)")
            .child(Input::new(&self.language).disabled(busy))
            .child(SharedString::from(format!("CPU threads: {}", self.threads)))
            .child(
                Button::new("transcription-threads-less")
                    .label("Fewer threads")
                    .disabled(busy || self.threads <= 1)
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.threads = this.threads.saturating_sub(1).max(1);
                        this.workflow.invalidate();
                        cx.notify();
                    })),
            )
            .child(
                Button::new("transcription-threads-more")
                    .label("More threads")
                    .disabled(busy || self.threads >= 64)
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.threads = (this.threads + 1).min(64);
                        this.workflow.invalidate();
                        cx.notify();
                    })),
            )
            .child(
                Button::new("transcription-run")
                    .label("Transcribe selected WAV")
                    .disabled(
                        busy || !cfg!(any(target_os = "macos", target_os = "linux"))
                            || self.workflow.binding.is_none()
                            || self.executable.is_none()
                            || self.model.is_none()
                            || self.wav.is_none(),
                    )
                    .on_click(cx.listener(|this, _, _, cx| this.transcribe(cx))),
            )
            .child(SharedString::from(self.status.clone()));
        if !cfg!(any(target_os = "macos", target_os = "linux")) {
            panel = panel.child("This file workflow supports macOS and Linux. Windows process support is not implemented.");
        }
        panel
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        sync::{
            Mutex,
            atomic::{AtomicUsize, Ordering},
        },
        time::Instant,
    };
    fn binding(revision: u64) -> ComposerBinding {
        ComposerBinding {
            thread_id: "synthetic-thread".into(),
            composer_revision: revision,
            selection: 0..0,
        }
    }
    fn configuration() -> Configuration {
        Configuration {
            executable: PathBuf::from("/synthetic/whisper cli"),
            model: PathBuf::from("/synthetic/model"),
            wav: PathBuf::from("/synthetic/audio.wav"),
            language: "en".into(),
            threads: 2,
        }
    }
    struct Fake {
        calls: AtomicUsize,
        gate: Mutex<Receiver<()>>,
        fail: bool,
    }
    impl Backend for Fake {
        fn transcribe(&self, config: Configuration) -> Result<String, Failure> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            assert_eq!(config.language, "en");
            assert_eq!(config.threads, 2);
            self.gate
                .lock()
                .unwrap()
                .recv_timeout(Duration::from_secs(2))
                .unwrap();
            if self.fail {
                Err(Failure::Process)
            } else {
                Ok("synthetic transcript".into())
            }
        }
    }
    fn setup(fail: bool) -> (Workflow, Receiver<TextReady>, Sender<()>, Arc<Fake>) {
        let (release, gate) = mpsc::channel();
        let backend = Arc::new(Fake {
            calls: AtomicUsize::new(0),
            gate: Mutex::new(gate),
            fail,
        });
        let (mut workflow, events) = Workflow::new(backend.clone());
        workflow.set_binding(Some(binding(1)));
        (workflow, events, release, backend)
    }
    fn completed(workflow: &mut Workflow) -> Completion {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            if let Some(result) = workflow.poll() {
                return result;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    #[::core::prelude::v1::test]
    fn worker_requires_explicit_start_and_emits_matching_text_once() {
        let (mut workflow, events, release, backend) = setup(false);
        assert_eq!(backend.calls.load(Ordering::SeqCst), 0);
        assert!(events.try_recv().is_err());
        assert!(workflow.start(configuration()));
        assert!(!workflow.start(configuration())); // exactly one background job
        release.send(()).unwrap();
        assert!(matches!(completed(&mut workflow), Completion::Ready));
        let event = events.try_recv().unwrap();
        assert!(workflow.accepts(&event, &binding(1)));
        assert_eq!(event.text, "synthetic transcript");
        assert!(events.try_recv().is_err());
        assert_eq!(backend.calls.load(Ordering::SeqCst), 1);
    }
    #[::core::prelude::v1::test]
    fn binding_and_configuration_changes_discard_running_results() {
        for composer_changed in [false, true] {
            let (mut workflow, events, release, _) = setup(false);
            assert!(workflow.start(configuration()));
            if composer_changed {
                workflow.set_binding(Some(binding(2)));
            } else {
                workflow.invalidate();
            }
            release.send(()).unwrap();
            assert!(matches!(completed(&mut workflow), Completion::Stale));
            assert!(events.try_recv().is_err());
            assert!(workflow.running.is_none());
        }
    }
    #[::core::prelude::v1::test]
    fn error_and_missing_binding_never_emit_text() {
        let (mut workflow, events, release, _) = setup(true);
        workflow.set_binding(None);
        assert!(!workflow.start(configuration()));
        workflow.set_binding(Some(binding(1)));
        assert!(workflow.start(configuration()));
        release.send(()).unwrap();
        assert!(matches!(
            completed(&mut workflow),
            Completion::Failed(Failure::Process)
        ));
        assert!(events.try_recv().is_err());
    }
    #[::core::prelude::v1::test]
    fn queued_event_must_be_rechecked_against_live_generation_and_binding() {
        let (mut workflow, events, release, _) = setup(false);
        assert!(workflow.start(configuration()));
        release.send(()).unwrap();
        assert!(matches!(completed(&mut workflow), Completion::Ready));
        let event = events.try_recv().unwrap();
        assert!(!workflow.accepts(&event, &binding(2)));
        workflow.invalidate();
        assert!(!workflow.accepts(&event, &binding(1)));
    }
}
