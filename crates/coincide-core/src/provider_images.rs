//! Prepared image snapshots shared by provider adapters. The storage layer owns
//! full image decoding, dimension limits, normalization and original retention.
use super::*;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use std::path::Path;

const MAX_IMAGE_BYTES: usize = 10 * 1024 * 1024;
const MAX_TOTAL_IMAGE_BYTES: usize = 20 * 1024 * 1024;
const MAX_IMAGES: usize = 20;
const CLAUDE_IMAGE_BYTES: usize = 3_750_000;

/// Immutable, validated bytes and the private file containing those same bytes.
/// The caller must retain the materialized file for the whole Session lifetime.
/// A MIME signature check here supplements, rather than replaces, full decoding
/// and normalization in the attachment store.
pub struct ImageAttachment {
    path: PathBuf,
    mime_type: String,
    bytes: Vec<u8>,
}

impl ImageAttachment {
    pub fn new(path: PathBuf, mime_type: String, bytes: Vec<u8>) -> Result<Self> {
        ensure!(
            path.is_absolute() && path.is_file(),
            "Prepared image must be an existing absolute file path"
        );
        ensure!(path.to_str().is_some(), "Prepared image path must be UTF-8");
        ensure!(
            !bytes.is_empty() && bytes.len() <= MAX_IMAGE_BYTES,
            "Prepared image must contain at most 10 MiB"
        );
        let mut file = std::fs::File::open(&path)?;
        ensure!(
            file.metadata()?.len() == bytes.len() as u64,
            "Prepared image file and byte snapshot have different lengths"
        );
        let mut buffer = [0u8; 8192];
        for chunk in bytes.chunks(buffer.len()) {
            file.read_exact(&mut buffer[..chunk.len()])?;
            ensure!(
                &buffer[..chunk.len()] == chunk,
                "Prepared image file does not match its byte snapshot"
            );
        }
        ensure!(
            file.read(&mut buffer[..1])? == 0,
            "Prepared image changed while preparing it"
        );
        let signature_matches = match mime_type.as_str() {
            "image/png" => bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
            "image/jpeg" => bytes.starts_with(&[0xff, 0xd8, 0xff]),
            "image/gif" => bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a"),
            "image/webp" => bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP"),
            _ => false,
        };
        ensure!(
            signature_matches,
            "Prepared image MIME type does not match supported image bytes"
        );
        Ok(Self {
            path,
            mime_type,
            bytes,
        })
    }
    pub fn path(&self) -> &Path {
        &self.path
    }
    pub fn mime_type(&self) -> &str {
        &self.mime_type
    }
    pub fn byte_len(&self) -> usize {
        self.bytes.len()
    }

    pub(super) fn claude_block(&self) -> Value {
        json!({"type":"image","source":{"type":"base64","media_type":self.mime_type,"data":STANDARD.encode(&self.bytes)}})
    }
    pub(super) fn acp_block(&self) -> Value {
        json!({"type":"image","mimeType":self.mime_type,"data":STANDARD.encode(&self.bytes)})
    }
}

/// Can be called before saving a message, so unsupported sizes fail without a
/// partial send. ACP image support is additionally checked after its handshake.
pub fn validate_images(provider: &Provider, images: &[ImageAttachment]) -> Result<()> {
    ensure!(
        images.len() <= MAX_IMAGES,
        "A turn can contain at most 20 images"
    );
    let bytes: usize = images.iter().map(ImageAttachment::byte_len).sum();
    ensure!(
        bytes <= MAX_TOTAL_IMAGE_BYTES,
        "Prepared images exceed 20 MiB in one turn"
    );
    if matches!(provider, Provider::Claude) {
        ensure!(
            images
                .iter()
                .all(|image| image.byte_len() <= CLAUDE_IMAGE_BYTES),
            "Claude images must be normalized to at most 3,750,000 bytes each"
        );
    }
    Ok(())
}

pub(super) fn claude_content(text: &str, images: &[ImageAttachment]) -> Value {
    if images.is_empty() {
        return json!(text);
    }
    let mut blocks = images
        .iter()
        .map(ImageAttachment::claude_block)
        .collect::<Vec<_>>();
    // Claude recognizes slash commands only at the start of the final text block.
    if !text.is_empty() {
        blocks.push(json!({"type":"text","text":text}));
    }
    json!(blocks)
}

pub(super) fn acp_content(text: &str, images: &[ImageAttachment]) -> Value {
    let mut blocks = Vec::new();
    if !text.is_empty() {
        blocks.push(json!({"type":"text","text":text}));
    }
    blocks.extend(images.iter().map(ImageAttachment::acp_block));
    json!(blocks)
}
