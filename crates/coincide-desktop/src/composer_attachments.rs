use super::*;
use coincide_core::attachments::{MAX_SOURCE_BYTES, stage_clipboard_image};
use std::path::PathBuf;

enum IncomingImage {
    Path(PathBuf),
    Clipboard(Vec<u8>),
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

    fn reserve_image_import(&mut self, cx: &mut Context<Self>) -> Option<String> {
        let id = self.selected.as_ref().map(|thread| text(thread, "id"))?;
        if !self.attachment_import_threads.insert(id.clone()) {
            self.status = "Wait for the current image import to finish.".into();
            cx.notify();
            return None;
        }
        Some(id)
    }

    pub(super) fn attach_images(&mut self, cx: &mut Context<Self>) {
        let Some(thread) = self.reserve_image_import(cx) else {
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
            let paths: Result<_> = async { Ok(picker.await??) }.await;
            let _ = this.update(cx, |this, cx| match paths {
                Ok(Some(paths)) => this.start_image_import(
                    thread,
                    paths.into_iter().map(IncomingImage::Path).collect(),
                    cx,
                ),
                Ok(None) => this.finish_image_import(&thread, Ok(0), cx),
                Err(error) => this.finish_image_import(&thread, Err(error), cx),
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
        let Some(thread) = self.reserve_image_import(cx) else {
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
            Ok(images) => self.start_image_import(thread, images, cx),
            Err(error) => self.finish_image_import(&thread, Err(error), cx),
        }
        !text
    }

    pub(super) fn drop_image_paths(&mut self, paths: &ExternalPaths, cx: &mut Context<Self>) {
        let Some(thread) = self.reserve_image_import(cx) else {
            return;
        };
        if paths.0.len() > 20 {
            self.finish_image_import(
                &thread,
                Err(anyhow::anyhow!("Drop at most 20 images at a time")),
                cx,
            );
            return;
        }
        self.start_image_import(
            thread,
            paths.0.iter().cloned().map(IncomingImage::Path).collect(),
            cx,
        );
    }

    fn start_image_import(
        &mut self,
        thread: String,
        images: Vec<IncomingImage>,
        cx: &mut Context<Self>,
    ) {
        if images.is_empty() || images.len() > 20 {
            self.finish_image_import(
                &thread,
                Err(anyhow::anyhow!("Choose 1–20 images to attach")),
                cx,
            );
            return;
        }
        let engine = self.engine.clone();
        self.status = "Importing images into the draft…".into();
        cx.notify();
        cx.spawn(async move |this, cx| {
            let outcome: Result<usize> = async {
                let data_engine = engine.clone();
                let data_directory = cx
                    .background_executor()
                    .spawn(async move {
                        data_engine
                            .lock()
                            .map_err(|_| anyhow::anyhow!("Application state is unavailable"))?
                            .store
                            .data_directory()
                    })
                    .await?;
                let mut imported = 0;
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
                    loop {
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
                            imported += 1;
                            break;
                        }
                        cx.background_executor()
                            .timer(Duration::from_millis(150))
                            .await;
                    }
                    // Owned clipboard staging drops here after import; pasted
                    // or dropped external paths never enter that cleanup guard.
                }
                Ok(imported)
            }
            .await;
            let _ = this.update(cx, |this, cx| {
                this.finish_image_import(&thread, outcome, cx)
            });
        })
        .detach();
    }

    fn finish_image_import(
        &mut self,
        thread: &str,
        outcome: Result<usize>,
        cx: &mut Context<Self>,
    ) {
        self.attachment_import_threads.remove(thread);
        let is_selected = self
            .selected
            .as_ref()
            .is_some_and(|value| value["id"] == thread);
        let destination = if is_selected {
            "the draft"
        } else {
            "the original conversation's draft"
        };
        self.status = match outcome {
            Ok(0) => "Image selection cancelled.".into(),
            Ok(count) => format!("Attached {count} image(s) to {destination}."),
            Err(error) => format!(
                "Image import stopped: {error}. Any earlier successful imports remain in {destination}."
            ),
        };
        if is_selected
            && let Ok(value) = call(&self.engine, "threads.read", json!({"threadId":thread}))
        {
            self.selected = Some(value);
        }
        cx.notify();
    }
}
