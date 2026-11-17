use super::*;
use coincide_core::attachments::{MAX_SOURCE_BYTES, stage_clipboard_image};
use std::path::PathBuf;

enum IncomingImage {
    Path(PathBuf),
    Clipboard(Arc<Image>),
}
struct ImportedReference {
    card: Value,
}

#[derive(Clone, Copy)]
enum AttachmentPickerKind {
    Mixed,
    Files,
    Folders,
}
impl AttachmentPickerKind {
    fn options(self) -> PathPromptOptions {
        PathPromptOptions {
            files: matches!(self, Self::Mixed | Self::Files),
            directories: matches!(self, Self::Mixed | Self::Folders),
            multiple: true,
            prompt: Some("Attach".into()),
        }
    }

    fn from_choice(choice: usize) -> Option<Self> {
        match choice {
            0 => Some(Self::Files),
            1 => Some(Self::Folders),
            _ => None,
        }
    }
}
pub(super) fn path_looks_like_image(path: &std::path::Path) -> bool {
    path.extension()
        .and_then(|value| value.to_str())
        .is_some_and(|value| {
            matches!(
                value.to_ascii_lowercase().as_str(),
                "png" | "jpg" | "jpeg" | "gif" | "webp"
            )
        })
}

#[derive(Clone)]
pub(super) enum ImportPreview {
    Path(PathBuf),
    Clipboard(Arc<Image>),
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::composer_follow_up_mount::PendingSend;

    #[::core::prelude::v1::test]
    fn native_picker_choices_cover_platforms_without_mixed_selection() {
        let mixed = AttachmentPickerKind::Mixed.options();
        assert!(mixed.files && mixed.directories && mixed.multiple);
        let files = AttachmentPickerKind::from_choice(0).unwrap().options();
        assert!(files.files && !files.directories && files.multiple);
        let folders = AttachmentPickerKind::from_choice(1).unwrap().options();
        assert!(!folders.files && folders.directories && folders.multiple);
        assert!(AttachmentPickerKind::from_choice(2).is_none());
    }

    #[::core::prelude::v1::test]
    fn mixed_selected_items_have_independent_previews_and_cancellation() {
        let mut imports = ImageImports::default();
        let mut jobs = Vec::new();
        for path in ["/tmp/photo.png", "/tmp/report.pdf", "/tmp/project"] {
            let job = imports.reserve("chat").unwrap();
            imports
                .ready(job, vec![IncomingImage::Path(PathBuf::from(path))])
                .unwrap();
            jobs.push(job);
        }
        assert_eq!(imports.visible_count("chat"), 3);
        assert_eq!(imports.previews("chat").len(), 3);
        imports.cancel(jobs[1]);
        assert_eq!(imports.visible_count("chat"), 2);
        assert_eq!(
            imports
                .take_ready()
                .iter()
                .map(|item| item.0)
                .collect::<Vec<_>>(),
            vec![jobs[0], jobs[2]]
        );
        assert!(path_looks_like_image(std::path::Path::new("photo.PNG")));
        assert!(!path_looks_like_image(std::path::Path::new("report.pdf")));
    }

    #[::core::prelude::v1::test]
    fn selected_file_joins_only_the_send_that_claimed_its_import() {
        let thread = json!({"id":"chat","selection":{"provider":"codex"},"draftContext":[]});
        let mut first = PendingSend::new(&thread, "first".into(), false);
        let mut second = PendingSend::new(&thread, "second".into(), false);
        first.add_imports(vec![1]);
        second.add_imports(vec![2]);
        let card = json!({"id":"file-1","kind":"file","path":"/tmp/report.pdf"});
        assert!(!second.complete_attachment_import(1, &[], std::slice::from_ref(&card), false));
        assert!(first.complete_attachment_import(1, &[], std::slice::from_ref(&card), false));
        assert_eq!(first.captured["draftContext"], json!([card]));
        assert_eq!(second.captured["draftContext"], json!([]));
        assert!(!first.waiting_for_import && second.waiting_for_import);
    }

    #[::core::prelude::v1::test]
    fn pastes_are_claimed_by_the_send_that_owned_them_even_when_they_finish_out_of_order() {
        let mut imports = ImageImports::default();
        let thread = json!({"id":"chat","selection":{"provider":"codex"}});
        let first_job = imports.reserve("chat").unwrap();
        let mut first = PendingSend::new(&thread, "first".into(), false);
        first.add_imports(imports.claim("chat"));
        let second_job = imports.reserve("chat").unwrap();
        let mut second = PendingSend::new(&thread, "second".into(), false);
        second.add_imports(imports.claim("chat"));
        let first_image = json!({"id":"first-image"});
        let second_image = json!({"id":"second-image"});
        assert!(!first.complete_import(second_job, std::slice::from_ref(&second_image), false));
        assert!(second.complete_import(second_job, std::slice::from_ref(&second_image), false));
        assert!(first.waiting_for_import);
        assert!(first.complete_import(first_job, std::slice::from_ref(&first_image), false));
        assert_eq!(first.captured["rustDraftImages"], json!([first_image]));
        assert_eq!(second.captured["rustDraftImages"], json!([second_image]));
        assert!(!first.waiting_for_import && !second.waiting_for_import);
    }

    #[::core::prelude::v1::test]
    fn extra_pastes_wait_for_an_import_slot_without_being_dropped() {
        let mut imports = ImageImports::default();
        let mut jobs = Vec::new();
        for _ in 0..6 {
            let job = imports.reserve("chat").unwrap();
            imports
                .ready(
                    job,
                    vec![IncomingImage::Clipboard(Arc::new(Image::from_bytes(
                        ImageFormat::Png,
                        vec![1],
                    )))],
                )
                .unwrap();
            jobs.push(job);
        }
        assert_eq!(
            imports
                .take_ready()
                .iter()
                .map(|entry| entry.0)
                .collect::<Vec<_>>(),
            jobs[..4]
        );
        assert!(imports.take_ready().is_empty());
        imports.finish(jobs[0]);
        assert_eq!(
            imports
                .take_ready()
                .iter()
                .map(|entry| entry.0)
                .collect::<Vec<_>>(),
            vec![jobs[4]]
        );
        assert!(imports.contains("chat"));
    }

    #[::core::prelude::v1::test]
    fn cancelled_running_paste_disappears_but_a_send_waits_for_cleanup() {
        let mut imports = ImageImports::default();
        let job = imports.reserve("chat").unwrap();
        imports
            .ready(
                job,
                vec![IncomingImage::Clipboard(Arc::new(Image::from_bytes(
                    ImageFormat::Png,
                    vec![1],
                )))],
            )
            .unwrap();
        assert_eq!(imports.previews("chat").len(), 1);
        assert_eq!(imports.take_ready().len(), 1);
        imports.cancel(job);
        assert!(imports.previews("chat").is_empty());
        assert!(imports.cancelled(job));
        assert!(imports.contains("chat"));
        let mut pending = PendingSend::new(
            &json!({"id":"chat","selection":{"provider":"codex"}}),
            "text".into(),
            false,
        );
        pending.add_imports(imports.claim("chat"));
        assert!(pending.waiting_for_import);
        assert!(pending.complete_import(job, &[], false));
        imports.finish(job);
        assert!(!pending.waiting_for_import);
        assert!(
            pending.captured["rustDraftImages"]
                .as_array()
                .is_none_or(Vec::is_empty)
        );
    }

    #[::core::prelude::v1::test]
    fn removed_image_blocks_a_send_until_its_removal_finishes() {
        let mut imports = ImageImports::default();
        let job = imports.reserve_removal("chat").unwrap();
        let mut pending = PendingSend::new(
            &json!({"id":"chat","selection":{"provider":"codex"},"rustDraftImages":[]}),
            "text".into(),
            false,
        );
        pending.add_imports(imports.claim("chat"));
        assert!(pending.waiting_for_import);
        assert!(pending.complete_import(job, &[], false));
        assert!(!pending.waiting_for_import);
    }

    #[::core::prelude::v1::test]
    fn reply_preview_is_immediate_and_a_cancel_stays_hidden_after_storage_refresh() {
        let mut imports = ImageImports::default();
        let reference = json!({"id":uuid::Uuid::new_v4(),"kind":"quote","text":"selected"});
        let job = imports
            .reserve_reference("chat", reference.clone())
            .unwrap();
        let saved = json!([reference]);
        assert_eq!(imports.context_preview("chat", &Value::Null), saved);
        assert_eq!(
            imports.context_preview("other-chat", &Value::Null),
            Value::Null
        );
        assert_eq!(imports.context_preview("chat", &saved), saved);
        assert_eq!(imports.reference_job("chat", &reference), Some(job));
        imports.cancel(job);
        assert_eq!(imports.context_preview("chat", &saved), json!([]));
        assert!(imports.contains("chat"));
        imports.finish(job);
        assert!(!imports.contains("chat"));
    }

    #[::core::prelude::v1::test]
    fn reply_reference_joins_the_send_that_was_pressed_while_it_was_saving() {
        let mut imports = ImageImports::default();
        let reference = json!({"id":uuid::Uuid::new_v4(),"kind":"quote","text":"selected"});
        let job = imports
            .reserve_reference("chat", reference.clone())
            .unwrap();
        let mut pending = PendingSend::new(
            &json!({"id":"chat","selection":{"provider":"codex"}}),
            "answer".into(),
            false,
        );
        pending.add_imports(imports.claim("chat"));
        assert!(pending.waiting_for_import);
        assert!(pending.complete_attachment_import(job, &[], &[reference.clone()], false));
        assert!(!pending.waiting_for_import);
        assert_eq!(pending.captured["draftContext"], json!([reference]));
        assert_eq!(pending.draft, "answer");
    }

    #[::core::prelude::v1::test]
    fn failed_import_does_not_send_a_partial_message_and_can_claim_a_retry() {
        let thread = json!({"id":"chat","selection":{"provider":"codex"}});
        let mut pending = PendingSend::new(&thread, "message".into(), false);
        pending.add_imports(vec![1, 2]);
        assert!(pending.complete_import(1, &[json!({"id":"saved"})], true));
        assert!(pending.import_failed && pending.waiting_for_import);
        assert!(pending.complete_import(2, &[], false));
        assert!(pending.import_failed && !pending.waiting_for_import);
        pending.import_failed = false;
        pending.add_imports(vec![3]);
        assert!(pending.complete_import(3, &[json!({"id":"retry"})], false));
        assert_eq!(
            pending.captured["rustDraftImages"],
            json!([{"id":"saved"},{"id":"retry"}])
        );
    }
}

enum ImportState {
    Reserved,
    Ready(Vec<IncomingImage>),
    Running,
}
struct ImportJob {
    id: u64,
    thread: String,
    claimed: bool,
    bytes: usize,
    preview: Option<ImportPreview>,
    reference: Option<Value>,
    cancelled: bool,
    state: ImportState,
}
/// Own every paste independently, including ones received while another image
/// is being converted. A send claims only jobs that existed when it was pressed.
#[derive(Default)]
pub(super) struct ImageImports {
    next: u64,
    jobs: Vec<ImportJob>,
}
impl ImageImports {
    pub fn contains(&self, thread: &str) -> bool {
        self.jobs.iter().any(|job| job.thread == thread)
    }
    fn reserve(&mut self, thread: &str) -> Option<u64> {
        if self.jobs.len() >= 32 {
            return None;
        }
        self.next = self.next.wrapping_add(1);
        let id = self.next;
        self.jobs.push(ImportJob {
            id,
            thread: thread.into(),
            claimed: false,
            bytes: 0,
            preview: None,
            reference: None,
            cancelled: false,
            state: ImportState::Reserved,
        });
        Some(id)
    }
    pub fn claim(&mut self, thread: &str) -> Vec<u64> {
        self.jobs
            .iter_mut()
            .filter(|job| job.thread == thread && !job.claimed)
            .map(|job| {
                job.claimed = true;
                job.id
            })
            .collect()
    }
    pub(super) fn claimed_previews(&self, jobs: &[u64]) -> Vec<ImportPreview> {
        self.jobs
            .iter()
            .filter(|job| jobs.contains(&job.id) && !job.cancelled)
            .filter_map(|job| job.preview.clone())
            .take(3)
            .collect()
    }
    pub(super) fn release_claims(&mut self, jobs: &[u64]) {
        for job in &mut self.jobs {
            if jobs.contains(&job.id) {
                job.claimed = false;
            }
        }
    }
    fn claim_one(&mut self, id: u64) {
        if let Some(job) = self.jobs.iter_mut().find(|job| job.id == id) {
            job.claimed = true;
        }
    }
    fn ready(&mut self, id: u64, images: Vec<IncomingImage>) -> Result<()> {
        let bytes = images
            .iter()
            .map(|image| match image {
                IncomingImage::Clipboard(image) => image.bytes().len(),
                IncomingImage::Path(_) => 0,
            })
            .sum::<usize>();
        anyhow::ensure!(
            self.jobs
                .iter()
                .map(|job| job.bytes)
                .sum::<usize>()
                .saturating_add(bytes)
                <= 64 * 1024 * 1024,
            "Too many images are waiting to import; paste again after these finish"
        );
        let job = self
            .jobs
            .iter_mut()
            .find(|job| job.id == id)
            .context("Image import is no longer available")?;
        job.bytes = bytes;
        job.preview = images.first().map(|image| match image {
            IncomingImage::Path(path) => ImportPreview::Path(path.clone()),
            IncomingImage::Clipboard(image) => ImportPreview::Clipboard(image.clone()),
        });
        job.state = ImportState::Ready(images);
        Ok(())
    }
    pub fn previews(&self, thread: &str) -> Vec<(u64, ImportPreview)> {
        self.jobs
            .iter()
            .filter(|job| job.thread == thread && !job.claimed && !job.cancelled)
            .filter_map(|job| job.preview.clone().map(|preview| (job.id, preview)))
            .collect()
    }
    pub fn visible_count(&self, thread: &str) -> usize {
        self.jobs
            .iter()
            .filter(|job| {
                job.thread == thread && !job.claimed && !job.cancelled && job.preview.is_some()
            })
            .count()
    }
    fn cancel(&mut self, id: u64) {
        if let Some(job) = self
            .jobs
            .iter_mut()
            .find(|job| job.id == id && !job.claimed)
        {
            job.cancelled = true;
            job.preview = None;
            if !matches!(job.state, ImportState::Running) {
                self.finish(id);
            }
        }
    }
    pub(super) fn cancelled(&self, id: u64) -> bool {
        self.jobs.iter().any(|job| job.id == id && job.cancelled)
    }
    pub fn reserve_removal(&mut self, thread: &str) -> Option<u64> {
        let id = self.reserve(thread)?;
        self.jobs.iter_mut().find(|job| job.id == id)?.state = ImportState::Running;
        Some(id)
    }
    pub fn reserve_reference(&mut self, thread: &str, card: Value) -> Option<u64> {
        let id = self.reserve_removal(thread)?;
        self.jobs.iter_mut().find(|job| job.id == id)?.reference = Some(card);
        Some(id)
    }
    pub fn context_preview(&self, thread: &str, raw: &Value) -> Value {
        if !raw.is_array() && !raw.is_null() {
            return raw.clone();
        }
        let mut rows = raw.as_array().cloned().unwrap_or_default();
        for job in self.jobs.iter().filter(|job| job.thread == thread) {
            let Some(card) = &job.reference else { continue };
            if job.claimed || job.cancelled {
                rows.retain(|row| row["id"] != card["id"]);
            } else if !rows.iter().any(|row| row["id"] == card["id"]) {
                rows.push(card.clone());
            }
        }
        if rows.is_empty() && raw.is_null() {
            Value::Null
        } else {
            Value::Array(rows)
        }
    }
    pub fn reference_job(&self, thread: &str, card: &Value) -> Option<u64> {
        self.jobs
            .iter()
            .find(|job| {
                job.thread == thread
                    && !job.claimed
                    && !job.cancelled
                    && job
                        .reference
                        .as_ref()
                        .is_some_and(|row| row["id"] == card["id"])
            })
            .map(|job| job.id)
    }
    fn take_ready(&mut self) -> Vec<(u64, String, Vec<IncomingImage>)> {
        let mut slots = 4usize.saturating_sub(
            self.jobs
                .iter()
                .filter(|job| matches!(job.state, ImportState::Running))
                .count(),
        );
        let mut ready = Vec::new();
        for job in &mut self.jobs {
            if slots == 0 {
                break;
            }
            if matches!(job.state, ImportState::Ready(_)) {
                let ImportState::Ready(images) =
                    std::mem::replace(&mut job.state, ImportState::Running)
                else {
                    unreachable!()
                };
                ready.push((job.id, job.thread.clone(), images));
                slots -= 1;
            }
        }
        ready
    }
    fn finish(&mut self, id: u64) {
        self.jobs.retain(|job| job.id != id);
    }
}

impl Coincide {
    pub(super) fn copy_message(&mut self, source: &str, item: &str, cx: &mut Context<Self>) {
        let Some(thread) = self
            .selected
            .as_ref()
            .filter(|thread| thread["id"] == source)
        else {
            return;
        };
        let Some(message) = thread["items"]
            .as_array()
            .and_then(|items| items.iter().find(|message| message["id"] == item))
        else {
            self.status = "That message is no longer in this conversation.".into();
            cx.notify();
            return;
        };
        let full = text(message, "text");
        if full.is_empty() {
            self.status = "This message has no text to copy.".into();
        } else {
            cx.write_to_clipboard(ClipboardItem::new_string(full));
            self.status = "Copied the complete message text.".into();
        }
        cx.notify();
    }

    fn reserve_import_for_thread(&mut self, id: &str, cx: &mut Context<Self>) -> Option<u64> {
        let Some(job) = self.attachment_imports.reserve(id) else {
            self.show_local_error(
                "Too many attachments are being added; try again when they finish.",
            );
            cx.notify();
            return None;
        };
        if let Some(pending) = self.pending_follow_up.as_mut().filter(|pending| {
            pending.thread == id && pending.original_visible && pending.import_failed
        }) {
            pending.import_failed = false;
            pending.add_imports(vec![job]);
            self.attachment_imports.claim_one(job);
        }
        Some(job)
    }

    fn reserve_image_import(&mut self, cx: &mut Context<Self>) -> Option<(String, u64)> {
        let id = self.selected.as_ref().map(|thread| text(thread, "id"))?;
        let job = self.reserve_import_for_thread(&id, cx)?;
        Some((id, job))
    }

    /// Reuse the normal attachment pipeline while keeping the conversation
    /// that opened the folder picker, even if another thread became active.
    pub(super) fn attach_folder_path(
        &mut self,
        thread: String,
        path: PathBuf,
        cx: &mut Context<Self>,
    ) {
        if let Some(job) = self.reserve_import_for_thread(&thread, cx) {
            self.queue_image_import(job, thread, vec![IncomingImage::Path(path)], cx);
        }
    }

    pub(super) fn attach_images(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some((thread, job)) = self.reserve_image_import(cx) else {
            return;
        };
        if cx.can_select_mixed_files_and_dirs() {
            self.pick_attachment_paths(thread, job, AttachmentPickerKind::Mixed, cx);
            return;
        }
        // Windows and Linux native pickers cannot select files and folders in
        // the same dialog, so offer each kind without hiding either one.
        let choice = window.prompt(
            PromptLevel::Info,
            "Attach files or folders",
            None,
            &["Files", "Folders", "Cancel"],
            cx,
        );
        cx.spawn(async move |this, cx| {
            let kind = choice
                .await
                .ok()
                .and_then(AttachmentPickerKind::from_choice);
            let _ = this.update(cx, |this, cx| {
                if let Some(kind) = kind {
                    this.pick_attachment_paths(thread, job, kind, cx);
                } else {
                    this.finish_image_import(job, &thread, Vec::new(), None, cx);
                }
            });
        })
        .detach();
    }

    fn pick_attachment_paths(
        &mut self,
        thread: String,
        job: u64,
        kind: AttachmentPickerKind,
        cx: &mut Context<Self>,
    ) {
        let picker = cx.prompt_for_paths(kind.options());
        self.status = "Choose files or folders to attach.".into();
        cx.notify();
        cx.spawn(async move |this, cx| {
            let paths: Result<_> = async { picker.await? }.await;
            let _ = this.update(cx, |this, cx| match paths {
                Ok(Some(paths)) => this.queue_image_import(
                    job,
                    thread,
                    paths.into_iter().map(IncomingImage::Path).collect(),
                    cx,
                ),
                Ok(None) => this.finish_image_import(job, &thread, Vec::new(), None, cx),
                Err(error) => this.finish_image_import(job, &thread, Vec::new(), Some(error), cx),
            });
        })
        .detach();
    }

    /// Preserve normal text/caption paste. Only media-only payloads are consumed
    /// so the default text editor does not insert copied filenames as prose.
    pub(super) fn paste_images(&mut self, item: &ClipboardItem, cx: &mut Context<Self>) -> bool {
        let media = item.entries.iter().any(|entry| {
            matches!(
                entry,
                ClipboardEntry::Image(_) | ClipboardEntry::ExternalPaths(_)
            )
        });
        if !media {
            return false;
        }
        let text = item
            .entries
            .iter()
            .any(|entry| matches!(entry,ClipboardEntry::String(text) if !text.text.is_empty()));
        let Some((thread, job)) = self.reserve_image_import(cx) else {
            return !text;
        };
        let incoming = (|| -> Result<Vec<IncomingImage>> {
            let mut incoming = Vec::new();
            let mut total = 0usize;
            for entry in &item.entries {
                match entry {
                    ClipboardEntry::Image(image) => {
                        anyhow::ensure!(
                            matches!(
                                image.format(),
                                ImageFormat::Png
                                    | ImageFormat::Jpeg
                                    | ImageFormat::Gif
                                    | ImageFormat::Webp
                            ),
                            "Unsupported clipboard image format. Paste PNG, JPEG, GIF, or WebP, or attach an image file."
                        );
                        total = total
                            .checked_add(image.bytes().len())
                            .ok_or_else(|| anyhow::anyhow!("Clipboard images are too large"))?;
                        anyhow::ensure!(
                            total as u64 <= MAX_SOURCE_BYTES,
                            "Clipboard images exceed the 20 MiB combined limit"
                        );
                        incoming.push(IncomingImage::Clipboard(Arc::new(image.clone())));
                    }
                    ClipboardEntry::ExternalPaths(paths) => {
                        anyhow::ensure!(
                            incoming.len() + paths.0.len() <= 20,
                            "Attach at most 20 items at a time"
                        );
                        incoming.extend(paths.0.iter().cloned().map(IncomingImage::Path));
                    }
                    ClipboardEntry::String(_) => {}
                }
                anyhow::ensure!(incoming.len() <= 20, "Attach at most 20 items at a time");
            }
            Ok(incoming)
        })();
        match incoming {
            Ok(images) => self.queue_image_import(job, thread, images, cx),
            Err(error) => self.finish_image_import(job, &thread, Vec::new(), Some(error), cx),
        }
        !text
    }

    pub(super) fn drop_image_paths(&mut self, paths: &ExternalPaths, cx: &mut Context<Self>) {
        let Some((thread, job)) = self.reserve_image_import(cx) else {
            return;
        };
        if paths.0.len() > 20 {
            self.finish_image_import(
                job,
                &thread,
                Vec::new(),
                Some(anyhow::anyhow!("Drop at most 20 attachments at a time")),
                cx,
            );
            return;
        }
        self.queue_image_import(
            job,
            thread,
            paths.0.iter().cloned().map(IncomingImage::Path).collect(),
            cx,
        );
    }

    fn queue_image_import(
        &mut self,
        job: u64,
        thread: String,
        images: Vec<IncomingImage>,
        cx: &mut Context<Self>,
    ) {
        if images.is_empty() || images.len() > 20 {
            self.finish_image_import(
                job,
                &thread,
                Vec::new(),
                Some(anyhow::anyhow!("Choose 1–20 attachments at a time")),
                cx,
            );
            return;
        }
        // Each item owns its own preview and cancel action, including when a
        // single picker selection contains both images and other paths.
        if self.attachment_imports.jobs.len() + images.len().saturating_sub(1) > 32 {
            self.finish_image_import(
                job,
                &thread,
                Vec::new(),
                Some(anyhow::anyhow!(
                    "Too many attachments are being added; try again when they finish"
                )),
                cx,
            );
            return;
        }
        for (index, image) in images.into_iter().enumerate() {
            let current = if index == 0 {
                job
            } else {
                match self.reserve_import_for_thread(&thread, cx) {
                    Some(id) => id,
                    None => break,
                }
            };
            if let Err(error) = self.attachment_imports.ready(current, vec![image]) {
                self.finish_image_import(current, &thread, Vec::new(), Some(error), cx);
            }
        }
        self.pump_image_imports(cx);
    }
    fn pump_image_imports(&mut self, cx: &mut Context<Self>) {
        for (job, thread, images) in self.attachment_imports.take_ready() {
            self.start_image_import(job, thread, images, cx);
        }
    }
    fn start_image_import(
        &mut self,
        job: u64,
        thread: String,
        images: Vec<IncomingImage>,
        cx: &mut Context<Self>,
    ) {
        let engine = self.engine.clone();
        // The data directory is stable for this app instance and is already
        // cached for image previews. Clipboard staging must not wait for the
        // agent's shared engine merely to rediscover that same path.
        let cached_root = self.attachment_root.clone();
        self.status = "Adding attachments to the draft…".into();
        cx.notify();
        cx.spawn(async move |this, cx| {
            let mut imported = Vec::new();
            let mut references = Vec::new();
            let outcome: Result<()> = async {
                let data_directory = if let Some(root) = cached_root {
                    root
                } else {
                    let data_engine = engine.clone();
                    cx.background_executor()
                        .spawn(async move {
                            data_engine
                                .lock()
                                .map_err(|_| anyhow::anyhow!("Application state is unavailable"))?
                                .store
                                .data_directory()
                        })
                        .await?
                };
                for image in images {
                    this.update(cx, |_, _| ())?;
                    let (path, _owned_stage) = match image {
                        IncomingImage::Path(path) => {
                            anyhow::ensure!(path.is_absolute(), "Image file path must be absolute");
                            let inspected_path = path.clone();
                            let preview_root = data_directory.clone();
                            let picked = cx
                                .background_executor()
                                .spawn(async move {
                                    let picked =
                                        coincide_core::composer_context::PickedPath::inspect(
                                            &inspected_path,
                                        )?;
                                    Ok::<_, anyhow::Error>(picked.with_preview_image(&preview_root))
                                })
                                .await?;
                            if !picked.is_supported_image() {
                                let reference_engine = engine.clone();
                                let owner = thread.clone();
                                let card = cx
                                    .background_executor()
                                    .spawn(async move {
                                        reference_engine
                                            .lock()
                                            .map_err(|_| {
                                                anyhow::anyhow!("Application state is unavailable")
                                            })?
                                            .attach_picked_path(&owner, &picked)
                                    })
                                    .await?;
                                references.push(ImportedReference { card });
                                continue;
                            }
                            (path, None)
                        }
                        IncomingImage::Clipboard(image) => {
                            let root = data_directory.clone();
                            let staged = cx
                                .background_executor()
                                .spawn(async move { stage_clipboard_image(&root, image.bytes()) })
                                .await?;
                            (staged.path().to_owned(), Some(staged))
                        }
                    };
                    let import_engine = engine.clone();
                    let params = json!({"threadId":thread,"path":path});
                    let operation = cx
                        .background_executor()
                        .spawn(async move {
                            coincide_core::api::call(&import_engine, "attachments.add", params)
                        })
                        .await?;
                    let operation_id = operation["operationId"].as_str().ok_or_else(|| {
                        anyhow::anyhow!("Image import did not return an operation ID")
                    })?;
                    // A lost import job must end the import instead of keeping
                    // the composer blocked with "Wait for image imports…".
                    let deadline = Instant::now() + Duration::from_secs(90);
                    loop {
                        anyhow::ensure!(
                            Instant::now() < deadline,
                            "Image import timed out; attach the image again"
                        );
                        let poll_engine = engine.clone();
                        let params = json!({"threadId":thread,"operationId":operation_id});
                        let result = cx
                            .background_executor()
                            .spawn(async move {
                                coincide_core::api::call(&poll_engine, "workspace.result", params)
                            })
                            .await?;
                        if result["ready"] == true {
                            if let Some(error) = result["result"]["error"].as_str() {
                                anyhow::bail!("{error}");
                            }
                            let attachment = result["result"]["attachment"].clone();
                            anyhow::ensure!(
                                attachment.is_object(),
                                "Image import returned no attachment"
                            );
                            imported.push(attachment);
                            break;
                        }
                        cx.background_executor()
                            .timer(Duration::from_millis(150))
                            .await;
                    }
                    // Owned clipboard staging drops here after import; pasted
                    // or dropped external paths never enter that cleanup guard.
                }
                Ok(())
            }
            .await;
            let _ = this.update(cx, |this, cx| {
                if this.attachment_imports.cancelled(job) {
                    this.cleanup_cancelled_import(job, thread, imported, references, cx);
                } else {
                    this.finish_attachment_import(
                        job,
                        &thread,
                        imported,
                        references,
                        outcome.err(),
                        cx,
                    );
                }
            });
        })
        .detach();
    }

    pub(super) fn cancel_image_import(&mut self, job: u64, cx: &mut Context<Self>) {
        self.attachment_imports.cancel(job);
        self.pump_image_imports(cx);
        cx.notify();
    }

    fn cleanup_cancelled_import(
        &mut self,
        job: u64,
        thread: String,
        imported: Vec<Value>,
        references: Vec<ImportedReference>,
        cx: &mut Context<Self>,
    ) {
        if imported.is_empty() && references.is_empty() {
            self.finish_image_import(job, &thread, Vec::new(), None, cx);
            return;
        }
        let engine = self.engine.clone();
        cx.spawn(async move |this, cx| {
            let owner = thread.clone();
            let result = cx
                .background_executor()
                .spawn(async move {
                    for image in imported {
                        let id = image["id"].as_str().context("Imported image has no ID")?;
                        coincide_core::api::call(
                            &engine,
                            "attachments.remove",
                            json!({"threadId":owner,"attachmentId":id}),
                        )?;
                    }
                    for reference in references {
                        engine
                            .lock()
                            .map_err(|_| anyhow::anyhow!("Application state is unavailable"))?
                            .remove_cancelled_picked_path(&owner, &reference.card)?;
                    }
                    Ok::<(), anyhow::Error>(())
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.finish_image_import(job, &thread, Vec::new(), result.err(), cx)
            });
        })
        .detach();
    }

    pub(super) fn finish_image_import(
        &mut self,
        job: u64,
        thread: &str,
        imported: Vec<Value>,
        error: Option<anyhow::Error>,
        cx: &mut Context<Self>,
    ) {
        self.finish_attachment_import(job, thread, imported, Vec::new(), error, cx);
    }

    /// A reply reference is owned by the send that claimed its in-flight job.
    /// If the user already pressed Send, do not also put it on their next draft.
    pub(super) fn finish_reply_reference(
        &mut self,
        job: u64,
        thread: &str,
        card: Option<Value>,
        error: Option<anyhow::Error>,
        cx: &mut Context<Self>,
    ) {
        let dismissed = self.attachment_imports.cancelled(job);
        if dismissed
            && error.is_none()
            && let Some(preview) = self
                .attachment_imports
                .jobs
                .iter()
                .find(|entry| entry.id == job)
                .and_then(|entry| entry.reference.as_ref())
            && let Some(rows) = self
                .selected
                .as_mut()
                .filter(|selected| selected["id"] == thread)
                .and_then(|selected| selected["draftContext"].as_array_mut())
        {
            rows.retain(|row| row["id"] != preview["id"]);
            self.selected_generation = self.selected_generation.wrapping_add(1);
        }
        self.attachment_imports.finish(job);
        let cards = card.into_iter().collect::<Vec<_>>();
        let mut claimed = false;
        for pending in self
            .pending_follow_up
            .iter_mut()
            .chain(self.pending_follow_up_backlog.iter_mut())
        {
            claimed |= pending.complete_attachment_import(job, &[], &cards, error.is_some());
        }
        if !claimed
            && !cards.is_empty()
            && let Some(selected) = self
                .selected
                .as_mut()
                .filter(|selected| selected["id"] == thread)
        {
            if selected["draftContext"].is_null() {
                selected["draftContext"] = json!([]);
            }
            if let Some(context) = selected["draftContext"].as_array_mut() {
                for card in &cards {
                    if !context.iter().any(|row| row["id"] == card["id"]) {
                        context.push(card.clone());
                    }
                }
            }
            self.selected_generation = self.selected_generation.wrapping_add(1);
        }
        if let Some(error) = error {
            let action = if dismissed { "remove" } else { "attach" };
            self.status = format!("Could not {action} reply: {error}");
            if self
                .selected
                .as_ref()
                .is_some_and(|selected| selected["id"] == thread)
            {
                self.show_local_error(&self.status.clone());
            }
        } else if !dismissed {
            self.status = "Message reference added to your reply.".into();
        }
        self.reconcile_buffered_sends();
        self.pump_image_imports(cx);
        cx.notify();
    }

    fn finish_attachment_import(
        &mut self,
        job: u64,
        thread: &str,
        imported: Vec<Value>,
        references: Vec<ImportedReference>,
        error: Option<anyhow::Error>,
        cx: &mut Context<Self>,
    ) {
        self.attachment_imports.finish(job);
        let import_failed = error.is_some();
        let cards: Vec<Value> = references
            .iter()
            .map(|reference| reference.card.clone())
            .collect();
        let mut claimed = false;
        for pending in self
            .pending_follow_up
            .iter_mut()
            .chain(self.pending_follow_up_backlog.iter_mut())
        {
            if pending.complete_attachment_import(job, &imported, &cards, import_failed) {
                claimed = true;
                if pending.import_failed {
                    if let Some(sequence) = pending.image_send.take() {
                        self.pending_images.finish(sequence);
                    }
                } else if !pending.captured["rustDraftImages"]
                    .as_array()
                    .is_none_or(Vec::is_empty)
                {
                    let sequence = *pending.image_send.get_or_insert_with(|| {
                        self.pending_seq = self.pending_seq.wrapping_add(1);
                        self.pending_seq
                    });
                    self.pending_images.begin(
                        sequence,
                        thread,
                        pending.captured["rustDraftImages"]
                            .as_array()
                            .cloned()
                            .unwrap_or_default(),
                    );
                }
            }
        }
        let is_selected = self
            .selected
            .as_ref()
            .is_some_and(|value| value["id"] == thread);
        let destination = if is_selected {
            "the draft"
        } else {
            "the original conversation's draft"
        };
        self.status = match error {
            None if imported.is_empty() && cards.is_empty() => "Attachment updated.".into(),
            None => format!(
                "Added {} attachment(s) to {destination}.",
                imported.len() + cards.len()
            ),
            Some(error) => format!(
                "Attachment change could not be completed: {error}. Other attachments remain in {destination}."
            ),
        };
        if import_failed && is_selected && claimed {
            self.show_local_error(
                "The attachment change failed. Your message has not been sent; please try again.",
            );
        } else if import_failed && is_selected {
            self.show_local_error(
                "The attachment change failed. Your draft is preserved; please try again.",
            );
        }
        if is_selected && (!imported.is_empty() || !cards.is_empty()) {
            if let Some(selected) = self.selected.as_mut() {
                if selected["rustDraftImages"].is_null() {
                    selected["rustDraftImages"] = json!([]);
                }
                if let Some(images) = selected["rustDraftImages"].as_array_mut() {
                    for image in &imported {
                        if !images.iter().any(|existing| existing["id"] == image["id"]) {
                            images.push(image.clone());
                        }
                    }
                }
                if !cards.is_empty() {
                    if selected["draftContext"].is_null() {
                        selected["draftContext"] = json!([]);
                    }
                    if let Some(context) = selected["draftContext"].as_array_mut() {
                        for card in &cards {
                            if !context.iter().any(|existing| existing["id"] == card["id"]) {
                                context.push(card.clone());
                            }
                        }
                    }
                }
            }
            self.selected_generation = self.selected_generation.wrapping_add(1);
        }
        self.reconcile_buffered_sends();
        self.pump_image_imports(cx);
        cx.notify();
    }
}
