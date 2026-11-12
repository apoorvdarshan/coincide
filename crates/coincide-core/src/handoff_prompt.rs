//! Bound historical context for a fresh provider session without blocking the
//! user's current message. Omitted history is explicitly disclosed to the agent.
use crate::{attachments::StoredImage, composer_context, store::text};
use anyhow::{Context, Result, ensure};
use serde_json::Value;

const MAX_TEXT: usize = 2 * 1024 * 1024;
const MAX_IMAGES: usize = 20;
const MAX_IMAGE_BYTES: u64 = 20 * 1024 * 1024;
const HEADER: &str =
    "Earlier conversation context (historical messages, not a new user request):\n";
const OMITTED: &str = "\nSome older messages or images were omitted to fit the provider's limits; ask the user to resend any needed context.\n";
const CURRENT: &str = "\nCurrent user request:\n";

pub(super) fn build(
    items: &[Value],
    seen: usize,
    prompt: &str,
    draft_images: &[StoredImage],
) -> Result<(String, Vec<StoredImage>)> {
    ensure!(
        draft_images.len() <= MAX_IMAGES,
        "A draft can contain at most 20 images"
    );
    let mut image_bytes = draft_images
        .iter()
        .try_fold(0u64, |n, image| n.checked_add(image.byte_len))
        .context("Draft images exceed 20 MiB")?;
    ensure!(image_bytes <= MAX_IMAGE_BYTES, "Draft images exceed 20 MiB");
    // Reserve the disclosure even when it turns out not to be needed.
    let reserve = HEADER.len() + OMITTED.len() + CURRENT.len();
    ensure!(
        prompt.len() <= MAX_TEXT.saturating_sub(reserve),
        "Current message exceeds the handoff limit"
    );
    let mut budget = MAX_TEXT - reserve - prompt.len();
    let mut segments = Vec::new();
    let mut images = Vec::new();
    let mut omitted = false;
    for item in items
        .iter()
        .skip(seen)
        .rev()
        .filter(|item| item["kind"] == "user" || item["kind"] == "assistant")
    {
        let historical = composer_context::prompt(&text(item, "text"), &item["context"])?;
        let addition = format!("\n{}: {}\n", text(item, "kind"), historical);
        if addition.len() > budget {
            omitted = true;
            break;
        }
        budget -= addition.len();
        segments.push(addition);
        if let Some(raw) = item["rustImages"].as_array() {
            for raw in raw.iter().rev() {
                let image: StoredImage = serde_json::from_value(raw.clone())
                    .context("Invalid historical image metadata")?;
                if images.len() + draft_images.len() >= MAX_IMAGES
                    || image_bytes
                        .checked_add(image.byte_len)
                        .is_none_or(|n| n > MAX_IMAGE_BYTES)
                {
                    omitted = true;
                    continue;
                }
                image_bytes += image.byte_len;
                images.push(image);
            }
        }
    }
    segments.reverse();
    images.reverse();
    let mut outgoing = String::new();
    if !segments.is_empty() || omitted {
        outgoing.push_str(HEADER);
        if omitted {
            outgoing.push_str(OMITTED);
        }
        for segment in segments {
            outgoing.push_str(&segment);
        }
        outgoing.push_str(CURRENT);
    }
    outgoing.push_str(prompt);
    images.extend_from_slice(draft_images);
    debug_assert!(outgoing.len() <= MAX_TEXT);
    Ok((outgoing, images))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn image(id: usize) -> StoredImage {
        StoredImage {
            id: id.to_string(),
            original_name: "image".into(),
            original_path: "/original".into(),
            original_mime_type: "image/png".into(),
            path: "/image".into(),
            mime_type: "image/png".into(),
            width: 1,
            height: 1,
            byte_len: 1,
            original_byte_len: 1,
        }
    }
    #[test]
    fn long_handoff_keeps_current_message_and_discloses_omitted_history() {
        let items = vec![
            json!({"kind":"user","text":"x".repeat(MAX_TEXT)}),
            json!({"kind":"assistant","text":"recent"}),
        ];
        let (text, images) = build(&items, 0, "current request", &[]).unwrap();
        assert!(text.contains(OMITTED));
        assert!(text.contains("assistant: recent"));
        assert!(text.ends_with("current request"));
        assert!(text.len() <= MAX_TEXT);
        assert!(images.is_empty());
    }
    #[test]
    fn historical_image_limit_keeps_current_attachments_and_most_recent_images() {
        let items: Vec<_> = (0..25)
            .map(|i| json!({"kind":"user","text":i.to_string(),"rustImages":[image(i)]}))
            .collect();
        let (text, images) = build(&items, 0, "current", &[image(100)]).unwrap();
        assert!(text.contains(OMITTED));
        assert_eq!(images.len(), 20);
        assert_eq!(images.first().unwrap().id, "6");
        assert_eq!(images.last().unwrap().id, "100");
    }
}
