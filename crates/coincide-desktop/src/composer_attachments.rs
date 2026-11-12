use super::*;
use coincide_core::attachments::{MAX_SOURCE_BYTES, stage_clipboard_image};
use std::path::PathBuf;

enum IncomingImage {
    Path(PathBuf),
    Clipboard(Vec<u8>),
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::composer_follow_up_mount::PendingSend;

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
                .ready(job, vec![IncomingImage::Clipboard(vec![1])])
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
    fn claim_one(&mut self, id: u64) {
        if let Some(job) = self.jobs.iter_mut().find(|job| job.id == id) {
            job.claimed = true;
        }
    }
    fn ready(&mut self, id: u64, images: Vec<IncomingImage>) -> Result<()> {
        let bytes = images
            .iter()
            .map(|image| match image {
                IncomingImage::Clipboard(bytes) => bytes.len(),
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
        job.state = ImportState::Ready(images);
        Ok(())
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

    fn reserve_image_import(&mut self, cx: &mut Context<Self>) -> Option<(String, u64)> {
        let id = self.selected.as_ref().map(|thread| text(thread, "id"))?;
        let Some(job) = self.attachment_imports.reserve(&id) else {
            self.show_local_error(
                "Too many images are waiting to import; paste again after these finish.",
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
        Some((id, job))
    }

    pub(super) fn attach_images(&mut self, cx: &mut Context<Self>) {
        let Some((thread, job)) = self.reserve_image_import(cx) else {
            return;
        };
        let picker = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: true,
            prompt: Some("Attach images".into()),
        });
        self.status = "Choose PNG, JPEG, GIF, or WebP images to attach.".into();
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
                        incoming.push(IncomingImage::Clipboard(image.bytes().to_vec()));
                    }
                    ClipboardEntry::ExternalPaths(paths) => {
                        anyhow::ensure!(
                            incoming.len() + paths.0.len() <= 20,
                            "Attach at most 20 images at a time"
                        );
                        incoming.extend(paths.0.iter().cloned().map(IncomingImage::Path));
                    }
                    ClipboardEntry::String(_) => {}
                }
                anyhow::ensure!(incoming.len() <= 20, "Attach at most 20 images at a time");
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
                Some(anyhow::anyhow!("Drop at most 20 images at a time")),
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
                Some(anyhow::anyhow!("Choose 1–20 images to attach")),
                cx,
            );
            return;
        }
        if let Err(error) = self.attachment_imports.ready(job, images) {
            self.finish_image_import(job, &thread, Vec::new(), Some(error), cx);
            return;
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
        self.status = "Importing images into the draft…".into();
        cx.notify();
        cx.spawn(async move |this, cx| {
            let mut imported = Vec::new();
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
                            (path, None)
                        }
                        IncomingImage::Clipboard(bytes) => {
                            let root = data_directory.clone();
                            let staged = cx
                                .background_executor()
                                .spawn(async move { stage_clipboard_image(&root, &bytes) })
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
                this.finish_image_import(job, &thread, imported, outcome.err(), cx)
            });
        })
        .detach();
    }

    fn finish_image_import(
        &mut self,
        job: u64,
        thread: &str,
        imported: Vec<Value>,
        error: Option<anyhow::Error>,
        cx: &mut Context<Self>,
    ) {
        self.attachment_imports.finish(job);
        let import_failed = error.is_some();
        let mut claimed = false;
        for pending in self
            .pending_follow_up
            .iter_mut()
            .chain(self.pending_follow_up_backlog.iter_mut())
        {
            if pending.complete_import(job, &imported, import_failed) {
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
            None if imported.is_empty() => "Image selection cancelled.".into(),
            None => format!("Attached {} image(s) to {destination}.", imported.len()),
            Some(error) => format!(
                "Image import stopped: {error}. Any earlier successful imports remain in {destination}."
            ),
        };
        if import_failed && is_selected && claimed {
            self.show_local_error("The image could not be attached. Your message has not been sent; attach the image again to continue.");
        }
        if is_selected
            && let Ok(value) = call(&self.engine, "threads.read", json!({"threadId":thread}))
        {
            self.selected = Some(value);
        }
        self.pump_image_imports(cx);
        cx.notify();
    }
}
