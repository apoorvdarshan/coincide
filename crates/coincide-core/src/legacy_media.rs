//! Explicit compatibility for historical `items[].attachments` image paths.
//! No thread/manifest mutation, captured-BLOB reads, network, or provider delivery.
//! Approved roots must come from trusted native approval, never imported JSON.
use crate::attachments::{self, StoredImage};
use anyhow::{Context, Result, ensure};
use image::{DynamicImage, ImageDecoder, ImageFormat, ImageReader, Limits};
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    io::Cursor,
    path::{Component, Path, PathBuf},
};
use uuid::Uuid;

pub const MAX_CANDIDATES: usize = 100;
pub const MAX_BATCH_FILES: usize = 20;
pub const MAX_BATCH_BYTES: u64 = attachments::MAX_SOURCE_BYTES;
const MAX_ITEMS: usize = 1000;
#[derive(Clone, Debug)]
pub struct ApprovedRoot {
    id: String,
    legacy_prefix: PathBuf,
    source_directory: PathBuf,
}
impl ApprovedRoot {
    /// Caller is responsible for explicit native approval of both directories.
    /// Construction/inspection does not open either path. No deserialization API.
    pub fn new(id: String, legacy_prefix: PathBuf, source_directory: PathBuf) -> Result<Self> {
        ensure!(
            cfg!(unix),
            "Legacy physical media import is unsupported on this platform until safe relative-handle opening is available"
        );
        ensure!(!id.is_empty() && id.len() <= 200, "Invalid root ID");
        ensure!(
            safe_absolute(&legacy_prefix) && safe_absolute(&source_directory),
            "Root must be an absolute non-root directory without traversal"
        );
        Ok(Self {
            id,
            legacy_prefix,
            source_directory,
        })
    }
}
#[derive(Clone, Debug, Default)]
pub struct InspectOptions {
    pub item_offset: usize,
    pub relative_base_root_id: Option<String>,
}
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Status {
    Mapped,
    Ready,
    Materialized,
    Missing,
    OutsideApprovedRoots,
    UnresolvedRelative,
    InvalidReference,
    UnknownShape,
    UnsupportedFormat,
    RemoteUnsupported,
    InlineUnsupported,
    Changed,
    LimitExceeded,
    PlatformUnsupported,
    UnsafeFile,
    IoError,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    pub candidate_id: String,
    pub thread_id: String,
    pub item_id: Option<String>,
    pub item_index: usize,
    pub attachment_index: usize,
    pub raw_reference: Value,
    pub root_id: Option<String>,
    pub relative_path: Option<PathBuf>,
    pub status: Status,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InspectionLimit {
    pub item_index: usize,
    pub skipped_attachments: usize,
}
#[derive(Clone, Debug)]
pub struct MediaPlan {
    thread_sha256: String,
    candidates: Vec<Candidate>,
    roots: Vec<ApprovedRoot>,
    next_item_offset: Option<usize>,
    limits: Vec<InspectionLimit>,
}
impl MediaPlan {
    pub fn thread_sha256(&self) -> &str {
        &self.thread_sha256
    }
    pub fn candidates(&self) -> &[Candidate] {
        &self.candidates
    }
    pub fn next_item_offset(&self) -> Option<usize> {
        self.next_item_offset
    }
    pub fn inspection_limits(&self) -> &[InspectionLimit] {
        &self.limits
    }
    pub fn matches_thread(&self, thread: &Value) -> Result<bool> {
        Ok(thread_digest(thread)? == self.thread_sha256)
    }
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckedReference {
    pub candidate: Candidate,
    pub status: Status,
    pub byte_len: Option<u64>,
    pub source_sha256: Option<String>,
    pub mime_type: Option<String>,
}
#[derive(Clone, Debug)]
pub struct MediaPreview {
    plan: MediaPlan,
    references: Vec<CheckedReference>,
}
impl MediaPreview {
    pub fn references(&self) -> &[CheckedReference] {
        &self.references
    }
    pub fn thread_sha256(&self) -> &str {
        &self.plan.thread_sha256
    }
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MaterializedReference {
    pub reference: CheckedReference,
    pub image: Option<StoredImage>,
    pub normalized_sha256: Option<String>,
    /// If final managed validation fails, retain newly-created identity for parent
    /// recovery/owned cleanup; never lose identity after ingestion succeeded.
    pub validation_error: Option<String>,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaBatch {
    pub thread_sha256: String,
    pub references: Vec<MaterializedReference>,
}
fn digest(bytes: &[u8]) -> String {
    crate::digest_hex::lower_hex(Sha256::digest(bytes))
}
fn thread_digest(thread: &Value) -> Result<String> {
    let bytes = serde_json::to_vec(thread)?;
    ensure!(bytes.len() <= 16_000_000, "Thread document too large");
    Ok(digest(&bytes))
}
fn safe_relative(path: &Path) -> bool {
    !path.as_os_str().is_empty()
        && path.components().all(|p| matches!(p, Component::Normal(_)))
        && path.to_str().is_some_and(|s| {
            !s.contains('\\') && !s.contains('\0') && !s.split('/').any(|p| matches!(p, "." | ".."))
        })
}
fn safe_absolute(path: &Path) -> bool {
    path.is_absolute()
        && path.components().count() > 1
        && path
            .components()
            .all(|p| matches!(p, Component::RootDir | Component::Normal(_)))
        && path.to_str().is_some_and(|s| {
            !s.contains('\\') && !s.contains('\0') && !s.split('/').any(|p| matches!(p, "." | ".."))
        })
}
fn map(
    reference: &str,
    roots: &[ApprovedRoot],
    relative_base: Option<&str>,
) -> std::result::Result<(String, PathBuf), Status> {
    if reference.is_empty()
        || reference.len() > 16 * 1024
        || reference.chars().any(char::is_control)
    {
        return Err(Status::InvalidReference);
    }
    if reference.starts_with('~') {
        return Err(Status::UnresolvedRelative);
    }
    let path = if reference.starts_with('/') {
        PathBuf::from(reference)
    } else if let Ok(url) = url::Url::parse(reference) {
        match url.scheme() {
            "http" | "https" => return Err(Status::RemoteUnsupported),
            "data" => return Err(Status::InlineUnsupported),
            "file" => {
                let lower = reference.to_ascii_lowercase();
                if !url.username().is_empty()
                    || url.password().is_some()
                    || url.query().is_some()
                    || url.fragment().is_some()
                    || !matches!(url.host_str(), None | Some("localhost"))
                    || reference.split('/').any(|part| matches!(part, "." | ".."))
                    || ["%2f", "%5c", "%00", "%2e"]
                        .iter()
                        .any(|value| lower.contains(value))
                {
                    return Err(Status::InvalidReference);
                }
                url.to_file_path()
                    .map_err(|_| Status::PlatformUnsupported)?
            }
            _ => return Err(Status::InvalidReference),
        }
    } else {
        if reference.contains(':') {
            return Err(Status::InvalidReference);
        }
        PathBuf::from(reference)
    };
    if !path.is_absolute() {
        if !safe_relative(&path) {
            return Err(Status::InvalidReference);
        }
        let root = relative_base
            .and_then(|id| roots.iter().find(|root| root.id == id))
            .ok_or(Status::UnresolvedRelative)?;
        return Ok((root.id.clone(), path));
    }
    if !safe_absolute(&path) {
        return Err(Status::InvalidReference);
    }
    let root = roots
        .iter()
        .filter(|root| path.starts_with(&root.legacy_prefix))
        .max_by_key(|root| root.legacy_prefix.components().count())
        .ok_or(Status::OutsideApprovedRoots)?;
    let relative = path
        .strip_prefix(&root.legacy_prefix)
        .map_err(|_| Status::OutsideApprovedRoots)?;
    if !safe_relative(relative) {
        return Err(Status::InvalidReference);
    }
    Ok((root.id.clone(), relative.to_owned()))
}

/// Only explicit attachment arrays are inspected. Markdown/media fences remain
/// unsupported in this slice. Call continuation only with the unchanged thread.
pub fn inspect(
    thread: &Value,
    roots: &[ApprovedRoot],
    options: InspectOptions,
) -> Result<MediaPlan> {
    ensure!(roots.len() <= 32, "Too many approved roots");
    let mut ids = HashSet::new();
    let mut prefixes = HashSet::new();
    ensure!(
        roots
            .iter()
            .all(|root| ids.insert(root.id.clone()) && prefixes.insert(root.legacy_prefix.clone())),
        "Ambiguous/duplicate approved roots"
    );
    let thread_sha256 = thread_digest(thread)?;
    let thread_id = thread["id"].as_str().context("Missing thread identity")?;
    Uuid::parse_str(thread_id)?;
    let items = thread["items"].as_array().context("Missing transcript")?;
    ensure!(options.item_offset <= items.len(), "Invalid item offset");
    let mut candidates = Vec::new();
    let mut limits = Vec::new();
    let end = (options.item_offset + MAX_ITEMS).min(items.len());
    let mut next = (end < items.len()).then_some(end);
    for (item_index, item) in items.iter().enumerate().take(end).skip(options.item_offset) {
        let Some(raw) = item.get("attachments").filter(|value| !value.is_null()) else {
            continue;
        };
        let item_id = item["id"]
            .as_str()
            .filter(|id| Uuid::parse_str(id).is_ok())
            .map(str::to_owned);
        let values = raw
            .as_array()
            .map(Vec::as_slice)
            .unwrap_or_else(|| std::slice::from_ref(raw));
        // Never split an item across pages; one excessive item gets an explicit
        // limit summary rather than endless same-offset continuation.
        if !candidates.is_empty()
            && candidates.len() + values.len().min(MAX_CANDIDATES) > MAX_CANDIDATES
        {
            next = Some(item_index);
            break;
        }
        for (index, value) in values
            .iter()
            .take(MAX_CANDIDATES - candidates.len())
            .enumerate()
        {
            let mut candidate = Candidate {
                candidate_id: digest(&serde_json::to_vec(&json!([
                    thread_id, item_index, item_id, index, value
                ]))?),
                thread_id: thread_id.into(),
                item_id: item_id.clone(),
                item_index,
                attachment_index: index,
                raw_reference: value.clone(),
                root_id: None,
                relative_path: None,
                status: Status::UnknownShape,
            };
            if raw.is_array() {
                candidate.status = if item_id.is_none() {
                    Status::InvalidReference
                } else if let Some(reference) = value.as_str() {
                    match map(reference, roots, options.relative_base_root_id.as_deref()) {
                        Ok((root, path)) => {
                            candidate.root_id = Some(root);
                            candidate.relative_path = Some(path);
                            Status::Mapped
                        }
                        Err(status) => status,
                    }
                } else {
                    Status::InvalidReference
                };
            }
            candidates.push(candidate);
        }
        if values.len() > MAX_CANDIDATES {
            limits.push(InspectionLimit {
                item_index,
                skipped_attachments: values.len() - MAX_CANDIDATES,
            });
        }
    }
    Ok(MediaPlan {
        thread_sha256,
        candidates,
        roots: roots.to_vec(),
        next_item_offset: next,
        limits,
    })
}

#[cfg(unix)]
fn read_source(
    root: &ApprovedRoot,
    relative: &Path,
    limit: u64,
) -> std::result::Result<Vec<u8>, Status> {
    use std::{
        ffi::CString,
        fs::File,
        io::Read,
        os::{
            fd::{AsRawFd, FromRawFd},
            unix::{ffi::OsStrExt, fs::MetadataExt},
        },
    };
    let read = || -> Result<Vec<u8>> {
        ensure!(safe_relative(relative), "Invalid relative source");
        let mut directory = File::open("/")?;
        let full = root.source_directory.join(relative);
        let parts = full.components().collect::<Vec<_>>();
        for (index, part) in parts.iter().enumerate().skip(1) {
            let Component::Normal(name) = part else {
                anyhow::bail!("Invalid source component")
            };
            let name = CString::new(name.as_bytes())?;
            let last = index == parts.len() - 1;
            let flags = libc::O_RDONLY
                | libc::O_CLOEXEC
                | libc::O_NOFOLLOW
                | libc::O_NONBLOCK
                | if last { 0 } else { libc::O_DIRECTORY };
            // SAFETY: directory owns its FD; name is one NUL-terminated component.
            let fd = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags) };
            if fd < 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            // SAFETY: successful openat returned a new descriptor, owned here.
            let file = unsafe { File::from_raw_fd(fd) };
            if !last {
                directory = file;
                continue;
            }
            let before = file.metadata()?;
            ensure!(before.is_file(), "Source is not a regular file");
            ensure!(
                before.len() > 0 && before.len() <= limit.min(MAX_BATCH_BYTES),
                "Source byte limit exceeded"
            );
            let mut bytes = Vec::new();
            let mut reader = file.take(limit.min(MAX_BATCH_BYTES) + 1);
            reader.read_to_end(&mut bytes)?;
            let after = reader.get_ref().metadata()?;
            ensure!(
                before.dev() == after.dev()
                    && before.ino() == after.ino()
                    && before.len() == after.len()
                    && before.mtime() == after.mtime()
                    && before.mtime_nsec() == after.mtime_nsec()
                    && before.ctime() == after.ctime()
                    && before.ctime_nsec() == after.ctime_nsec()
                    && before.len() == bytes.len() as u64,
                "Source changed during read"
            );
            return Ok(bytes);
        }
        anyhow::bail!("No source file")
    };
    read().map_err(|error| {
        if let Some(io) = error.downcast_ref::<std::io::Error>() {
            match io.raw_os_error() {
                Some(libc::ENOENT) => Status::Missing,
                Some(libc::ELOOP) | Some(libc::ENOTDIR) => Status::UnsafeFile,
                _ => Status::IoError,
            }
        } else if error.to_string().contains("limit") {
            Status::LimitExceeded
        } else if error.to_string().contains("changed") {
            Status::Changed
        } else {
            Status::UnsafeFile
        }
    })
}
#[cfg(not(unix))]
fn read_source(
    _root: &ApprovedRoot,
    _relative: &Path,
    _limit: u64,
) -> std::result::Result<Vec<u8>, Status> {
    Err(Status::PlatformUnsupported)
}
fn image_mime(bytes: &[u8]) -> std::result::Result<&'static str, Status> {
    let format = image::guess_format(bytes).map_err(|_| Status::UnsupportedFormat)?;
    let mime = match format {
        ImageFormat::Png => "image/png",
        ImageFormat::Jpeg => "image/jpeg",
        ImageFormat::Gif => "image/gif",
        ImageFormat::WebP => "image/webp",
        _ => return Err(Status::UnsupportedFormat),
    };
    let mut reader = ImageReader::with_format(Cursor::new(bytes), format);
    let mut limits = Limits::default();
    limits.max_image_width = Some(32768);
    limits.max_image_height = Some(32768);
    limits.max_alloc = Some(256 * 1024 * 1024);
    reader.limits(limits);
    let decoder = reader.into_decoder().map_err(|error| {
        if error.to_string().to_ascii_lowercase().contains("limit") {
            Status::LimitExceeded
        } else {
            Status::UnsupportedFormat
        }
    })?;
    let (width, height) = decoder.dimensions();
    if width == 0
        || height == 0
        || u64::from(width) * u64::from(height) > 64_000_000
        || decoder.total_bytes() > 256 * 1024 * 1024
    {
        return Err(Status::LimitExceeded);
    }
    DynamicImage::from_decoder(decoder).map_err(|_| Status::UnsupportedFormat)?;
    Ok(mime)
}
/// Validate at most20 files/20MiB in a plan, returning explicit states for every
/// remaining reference. No files are created during preview.
pub fn validate(plan: &MediaPlan, candidate_ids: &[String]) -> Result<MediaPreview> {
    ensure!(
        candidate_ids.len() <= MAX_BATCH_FILES,
        "Select at most20 references to validate"
    );
    let selected = candidate_ids.iter().cloned().collect::<HashSet<_>>();
    ensure!(
        selected.len() == candidate_ids.len()
            && selected
                .iter()
                .all(|id| plan.candidates.iter().any(|c| &c.candidate_id == id)),
        "Unknown/duplicate validation selection"
    );
    let (mut total, mut count) = (0u64, 0usize);
    let references = plan
        .candidates
        .iter()
        .map(|candidate| {
            let mut reference = CheckedReference {
                candidate: candidate.clone(),
                status: candidate.status.clone(),
                byte_len: None,
                source_sha256: None,
                mime_type: None,
            };
            if candidate.status != Status::Mapped || !selected.contains(&candidate.candidate_id) {
                return reference;
            }
            if count >= MAX_BATCH_FILES || total >= MAX_BATCH_BYTES {
                reference.status = Status::LimitExceeded;
                return reference;
            }
            count += 1;
            let result = (|| {
                let root = plan
                    .roots
                    .iter()
                    .find(|r| Some(&r.id) == candidate.root_id.as_ref())
                    .ok_or(Status::OutsideApprovedRoots)?;
                let bytes = read_source(
                    root,
                    candidate
                        .relative_path
                        .as_deref()
                        .ok_or(Status::InvalidReference)?,
                    MAX_BATCH_BYTES.saturating_sub(total),
                )?;
                total = total.saturating_add(bytes.len() as u64);
                if total > MAX_BATCH_BYTES {
                    return Err(Status::LimitExceeded);
                }
                let mime = image_mime(&bytes)?;
                reference.byte_len = Some(bytes.len() as u64);
                reference.source_sha256 = Some(digest(&bytes));
                reference.mime_type = Some(mime.into());
                Ok(())
            })();
            reference.status = match result {
                Ok(()) => Status::Ready,
                Err(status) => status,
            };
            reference
        })
        .collect();
    Ok(MediaPreview {
        plan: plan.clone(),
        references,
    })
}

/// Caller must recheck the originating plan.matches_thread against current Store state
/// before persisting. Per-reference results ALWAYS retain ingested identities;
/// this function never hides successes when a later reference fails.
pub fn materialize(
    preview: &MediaPreview,
    candidate_ids: &[String],
    data_directory: &Path,
) -> Result<MediaBatch> {
    materialize_internal(preview, candidate_ids, data_directory, false, |_, _| Ok(()))
}
pub(crate) fn materialize_with_ownership(
    preview: &MediaPreview,
    candidate_ids: &[String],
    data_directory: &Path,
    own: impl FnMut(&CheckedReference, &StoredImage) -> Result<()>,
) -> Result<MediaBatch> {
    materialize_internal(preview, candidate_ids, data_directory, true, own)
}
fn materialize_internal(
    preview: &MediaPreview,
    candidate_ids: &[String],
    data_directory: &Path,
    owned: bool,
    mut own: impl FnMut(&CheckedReference, &StoredImage) -> Result<()>,
) -> Result<MediaBatch> {
    ensure!(
        candidate_ids.len() <= MAX_BATCH_FILES,
        "Select at most20 references"
    );
    let selected = candidate_ids.iter().cloned().collect::<HashSet<_>>();
    ensure!(selected.len() == candidate_ids.len(), "Duplicate selection");
    ensure!(
        selected.iter().all(|id| preview
            .references
            .iter()
            .any(|r| &r.candidate.candidate_id == id)),
        "Unknown candidate selection"
    );
    let managed_root = data_directory
        .canonicalize()
        .context("Rust media store is unavailable")?;
    ensure!(
        preview
            .plan
            .roots
            .iter()
            .all(|root| !managed_root.starts_with(&root.source_directory)
                && !root.source_directory.starts_with(&managed_root)),
        "Rust managed media store must be separate from approved source directories"
    );
    let mut references = Vec::new();
    let mut total = 0u64;
    let mut reused = HashMap::<String, (StoredImage, String)>::new();
    for original in preview
        .references
        .iter()
        .filter(|r| selected.contains(&r.candidate.candidate_id))
    {
        let mut result = MaterializedReference {
            reference: original.clone(),
            image: None,
            normalized_sha256: None,
            validation_error: None,
        };
        if original.status != Status::Ready {
            references.push(result);
            continue;
        }
        let prepared = (|| -> std::result::Result<Vec<u8>, Status> {
            let root = preview
                .plan
                .roots
                .iter()
                .find(|r| Some(&r.id) == original.candidate.root_id.as_ref())
                .ok_or(Status::OutsideApprovedRoots)?;
            let bytes = read_source(
                root,
                original
                    .candidate
                    .relative_path
                    .as_deref()
                    .ok_or(Status::InvalidReference)?,
                MAX_BATCH_BYTES.saturating_sub(total),
            )?;
            total = total.saturating_add(bytes.len() as u64);
            if total > MAX_BATCH_BYTES {
                return Err(Status::LimitExceeded);
            }
            if Some(bytes.len() as u64) != original.byte_len
                || Some(digest(&bytes)).as_ref() != original.source_sha256.as_ref()
            {
                return Err(Status::Changed);
            }
            Ok(bytes)
        })();
        let bytes = match prepared {
            Ok(bytes) => bytes,
            Err(status) => {
                result.reference.status = status;
                references.push(result);
                continue;
            }
        };
        let hash = original.source_sha256.clone().expect("Ready has digest");
        if let Some((image, normalized)) = reused.get(&hash) {
            result.image = Some(image.clone());
            result.normalized_sha256 = Some(normalized.clone());
            result.reference.status = Status::Materialized;
            references.push(result);
            continue;
        }
        let ingested = {
            let name = original
                .candidate
                .relative_path
                .as_deref()
                .and_then(Path::file_name)
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_else(|| "Historical image".into());
            if owned {
                attachments::ingest_image_bytes_owned(data_directory, &bytes, &name, |image| {
                    own(original, image)
                })
            } else {
                attachments::ingest_image_bytes(data_directory, &bytes, &name)
            }
        };
        match ingested {
            Err(error) => {
                result.reference.status = Status::IoError;
                result.validation_error = Some(error.to_string());
            }
            Ok(mut image) => {
                if let Some(name) = original
                    .candidate
                    .relative_path
                    .as_deref()
                    .and_then(Path::file_name)
                {
                    image.original_name = name.to_string_lossy().into_owned();
                }
                // From this point the identity is ALWAYS returned, even if final
                // verification fails; parent owns persistence/orphan recovery.
                result.image = Some(image.clone());
                let verified = (|| -> Result<String> {
                    image.prepare_in(data_directory)?;
                    let directory = data_directory.canonicalize()?;
                    let managed = ApprovedRoot {
                        id: "managed".into(),
                        legacy_prefix: directory.clone(),
                        source_directory: directory.clone(),
                    };
                    let original = read_source(
                        &managed,
                        image.original_path.strip_prefix(&directory)?,
                        MAX_BATCH_BYTES,
                    )
                    .map_err(|status| {
                        anyhow::anyhow!("Managed original validation failed: {status:?}")
                    })?;
                    ensure!(
                        digest(&original) == hash,
                        "Ingested original digest mismatch"
                    );
                    let normalized = read_source(
                        &managed,
                        image.path.strip_prefix(&directory)?,
                        attachments::MAX_NORMALIZED_BYTES,
                    )
                    .map_err(|status| {
                        anyhow::anyhow!("Managed normalized validation failed: {status:?}")
                    })?;
                    ensure!(
                        normalized.len() as u64 == image.byte_len
                            && image.byte_len <= attachments::MAX_NORMALIZED_BYTES,
                        "Managed normalized length changed"
                    );
                    Ok(digest(&normalized))
                })();
                match verified {
                    Ok(normalized) => {
                        result.normalized_sha256 = Some(normalized.clone());
                        result.reference.status = Status::Materialized;
                        reused.insert(hash, (image, normalized));
                    }
                    Err(error) => {
                        result.reference.status = Status::Changed;
                        result.validation_error = Some(error.to_string());
                    }
                }
            }
        }
        references.push(result);
    }
    Ok(MediaBatch {
        thread_sha256: preview.plan.thread_sha256.clone(),
        references,
    })
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::{fs, os::unix::fs::symlink};
    const THREAD: &str = "00000000-0000-4000-8000-000000000001";
    const ITEM: &str = "00000000-0000-4000-8000-000000000002";
    fn thread(refs: Value) -> Value {
        json!({"id":THREAD,"future":{"keep":true},"items":[{"id":ITEM,"attachments":refs,"text":"Original text","unknown":17}]})
    }
    fn png() -> Vec<u8> {
        let mut bytes = Cursor::new(Vec::new());
        DynamicImage::new_rgba8(2, 2)
            .write_to(&mut bytes, ImageFormat::Png)
            .unwrap();
        bytes.into_inner()
    }
    fn fixture() -> (tempfile::TempDir, PathBuf, PathBuf, ApprovedRoot) {
        let dir = tempfile::tempdir().unwrap();
        let base = dir.path().canonicalize().unwrap();
        let source = base.join("source");
        let data = base.join("rust");
        fs::create_dir(&source).unwrap();
        fs::create_dir(&data).unwrap();
        let root = ApprovedRoot::new(
            "approved".into(),
            PathBuf::from("/retired-coincide"),
            source.clone(),
        )
        .unwrap();
        (dir, source, data, root)
    }
    fn all(plan: &MediaPlan) -> Vec<String> {
        plan.candidates
            .iter()
            .map(|c| c.candidate_id.clone())
            .collect()
    }
    #[test]
    fn public_materialize_cleans_partial_copy_but_journal_owned_materialize_retains_it() {
        let (_dir, source, data, root) = fixture();
        let bytes = png();
        fs::write(source.join("image.png"), &bytes).unwrap();
        let thread = thread(json!(["/retired-coincide/image.png"]));
        let plan = inspect(&thread, &[root], InspectOptions::default()).unwrap();
        let ids = all(&plan);
        let preview = validate(&plan, &ids).unwrap();
        let normal = attachments::with_copy_fault(|| materialize(&preview, &ids, &data)).unwrap();
        assert_eq!(normal.references[0].reference.status, Status::IoError);
        assert_eq!(
            fs::read_dir(data.join("attachments")).unwrap().count(),
            0,
            "unowned public path cleans partial original"
        );
        let data = data.canonicalize().unwrap();
        let database = data.join("state.sqlite");
        drop(crate::store::Store::open(&database).unwrap());
        let config = crate::legacy_media_service::ServiceConfig {
            database_path: database,
            expected_data_directory: data.clone(),
        };
        let mut journal = crate::legacy_media_recovery::IngestionStore::open(&config).unwrap();
        let context = crate::legacy_media_recovery::IngestionContext {
            operation_id: Uuid::new_v4().to_string(),
            reserved_receipt_id: Uuid::new_v4().to_string(),
            thread_id: THREAD.into(),
            generation: 1,
        };
        let owned = attachments::with_copy_fault(|| {
            materialize_with_ownership(&preview, &ids, &data, |reference, image| {
                journal
                    .allocate(
                        &context,
                        &reference.candidate.candidate_id,
                        reference.source_sha256.as_deref().unwrap(),
                        image,
                    )
                    .map_err(|error| anyhow::anyhow!("{error:?}"))
            })
        })
        .unwrap();
        assert_eq!(owned.references[0].reference.status, Status::IoError);
        drop(journal);
        let journal = crate::legacy_media_recovery::IngestionStore::open(&config).unwrap();
        let records = journal.retained().unwrap();
        assert_eq!(records.len(), 1);
        let image: StoredImage =
            serde_json::from_value(records[0].record["image"].clone()).unwrap();
        assert!(image.original_path.is_file());
        assert!(!image.path.exists());
        assert_eq!(fs::read_dir(data.join("attachments")).unwrap().count(), 1);
        assert_eq!(fs::read(source.join("image.png")).unwrap(), bytes);
    }
    #[test]
    fn materializes_unicode_paths_and_duplicates_without_modifying_sources_or_json() {
        let (_dir, source, data, root) = fixture();
        let bytes = png();
        fs::write(source.join("图 image.png"), &bytes).unwrap();
        let original = thread(json!([
            "/retired-coincide/图 image.png",
            "/retired-coincide/图 image.png"
        ]));
        let before = serde_json::to_vec(&original).unwrap();
        let plan = inspect(&original, &[root], InspectOptions::default()).unwrap();
        assert_ne!(
            plan.candidates[0].candidate_id,
            plan.candidates[1].candidate_id
        );
        let preview = validate(&plan, &all(&plan)).unwrap();
        assert!(preview.references.iter().all(|r| r.status == Status::Ready));
        let result = materialize(&preview, &all(&plan), &data).unwrap();
        assert_eq!(result.references.len(), 2);
        let first = result.references[0].image.as_ref().unwrap();
        assert_eq!(first.id, result.references[1].image.as_ref().unwrap().id);
        assert!(
            result
                .references
                .iter()
                .all(|r| r.reference.status == Status::Materialized)
        );
        assert_eq!(fs::read(&first.original_path).unwrap(), bytes);
        assert_eq!(fs::read(source.join("图 image.png")).unwrap(), bytes);
        assert_eq!(serde_json::to_vec(&original).unwrap(), before);
        assert!(plan.matches_thread(&original).unwrap());
        let mut changed = original;
        changed["items"][0]["text"] = json!("edited");
        assert!(!plan.matches_thread(&changed).unwrap());
        assert_eq!(fs::read_dir(data.join("attachments")).unwrap().count(), 1);
        let staging = data.join("clipboard-staging");
        assert!(!staging.exists() || fs::read_dir(staging).unwrap().count() == 0);
    }
    #[test]
    fn partial_batch_returns_success_identity_when_later_source_changes() {
        let (_dir, source, data, root) = fixture();
        let bytes = png();
        for name in ["first.png", "second.png"] {
            fs::write(source.join(name), &bytes).unwrap();
        }
        let plan = inspect(
            &thread(json!([
                "/retired-coincide/first.png",
                "/retired-coincide/second.png"
            ])),
            &[root],
            InspectOptions::default(),
        )
        .unwrap();
        let preview = validate(&plan, &all(&plan)).unwrap();
        fs::write(source.join("second.png"), b"changed after preview").unwrap();
        let batch = materialize(&preview, &all(&plan), &data).unwrap();
        assert_eq!(batch.references[0].reference.status, Status::Materialized);
        assert!(batch.references[0].image.as_ref().unwrap().path.is_file());
        assert_eq!(batch.references[1].reference.status, Status::Changed);
        assert!(batch.references[1].image.is_none());
        assert_eq!(
            batch.references[0].reference.source_sha256,
            Some(digest(&bytes))
        );
        assert!(batch.references[0].normalized_sha256.is_some());
    }
    #[test]
    fn no_basename_fallback_missing_outside_and_non_image_are_explicit() {
        let (_dir, source, _data, root) = fixture();
        fs::write(source.join("same.png"), png()).unwrap();
        fs::write(source.join("bad.png"), b"not an image").unwrap();
        let plan = inspect(
            &thread(json!([
                "/elsewhere/same.png",
                "/retired-coincide/missing.png",
                "/retired-coincide/bad.png",
                "https://example.invalid/image.png",
                "data:image/png;base64,AA==",
                7
            ])),
            &[root],
            InspectOptions::default(),
        )
        .unwrap();
        let preview = validate(&plan, &all(&plan)).unwrap();
        let states = preview
            .references
            .iter()
            .map(|r| r.status.clone())
            .collect::<Vec<_>>();
        assert_eq!(
            states,
            [
                Status::OutsideApprovedRoots,
                Status::Missing,
                Status::UnsupportedFormat,
                Status::RemoteUnsupported,
                Status::InlineUnsupported,
                Status::InvalidReference
            ]
        );
    }
    #[test]
    fn rejects_source_symlinks_directories_fifo_and_traversal() {
        use std::{ffi::CString, os::unix::ffi::OsStrExt};
        let (_dir, source, _data, root) = fixture();
        fs::write(source.join("real.png"), png()).unwrap();
        symlink(source.join("real.png"), source.join("link.png")).unwrap();
        fs::create_dir(source.join("nested")).unwrap();
        symlink(source.join("nested"), source.join("linked-parent")).unwrap();
        fs::write(source.join("nested/image.png"), png()).unwrap();
        let fifo = CString::new(source.join("fifo").as_os_str().as_bytes()).unwrap();
        // SAFETY: valid path to an owned fixture directory, no live user paths.
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        let plan = inspect(
            &thread(json!([
                "/retired-coincide/link.png",
                "/retired-coincide/linked-parent/image.png",
                "/retired-coincide/nested",
                "/retired-coincide/fifo",
                "/retired-coincide/../outside.png"
            ])),
            &[root],
            InspectOptions::default(),
        )
        .unwrap();
        let preview = validate(&plan, &all(&plan)).unwrap();
        assert!(
            preview.references[..4]
                .iter()
                .all(|r| r.status == Status::UnsafeFile)
        );
        assert_eq!(preview.references[4].status, Status::InvalidReference);
    }
    #[test]
    fn file_urls_relative_approval_and_ambiguous_roots_are_handled_literally() {
        let (_dir, source, _data, root) = fixture();
        fs::write(source.join("space name.png"), png()).unwrap();
        let url = url::Url::from_file_path("/retired-coincide/space name.png").unwrap();
        let original = thread(json!([
            url.to_string(),
            "space name.png",
            "file:///retired-coincide/%2fsecret.png",
            "~/private.png"
        ]));
        let plan = inspect(
            &original,
            std::slice::from_ref(&root),
            InspectOptions::default(),
        )
        .unwrap();
        assert_eq!(plan.candidates[1].status, Status::UnresolvedRelative);
        assert_eq!(plan.candidates[2].status, Status::InvalidReference);
        assert_eq!(plan.candidates[3].status, Status::UnresolvedRelative);
        let plan = inspect(
            &original,
            std::slice::from_ref(&root),
            InspectOptions {
                relative_base_root_id: Some("approved".into()),
                ..Default::default()
            },
        )
        .unwrap();
        let selected = all(&plan);
        let preview = validate(&plan, &selected).unwrap();
        assert_eq!(preview.references[0].status, Status::Ready);
        assert_eq!(preview.references[1].status, Status::Ready);
        assert!(inspect(&original, &[root.clone(), root], InspectOptions::default()).is_err());
    }
    #[test]
    fn limits_and_unknown_shapes_never_silently_disappear() {
        let (_dir, source, _data, root) = fixture();
        let large = fs::File::create(source.join("large.png")).unwrap();
        large.set_len(MAX_BATCH_BYTES + 1).unwrap();
        let plan = inspect(
            &thread(json!(["/retired-coincide/large.png"])),
            std::slice::from_ref(&root),
            InspectOptions::default(),
        )
        .unwrap();
        assert_eq!(
            validate(&plan, &all(&plan)).unwrap().references[0].status,
            Status::LimitExceeded
        );
        let refs = (0..101)
            .map(|i| format!("/retired-coincide/{i}.png"))
            .collect::<Vec<_>>();
        let original = thread(json!(refs));
        let plan = inspect(
            &original,
            std::slice::from_ref(&root),
            InspectOptions::default(),
        )
        .unwrap();
        assert_eq!(plan.candidates.len(), 100);
        assert_eq!(plan.limits[0].skipped_attachments, 1);
        assert_eq!(
            plan.candidates[99].raw_reference,
            "/retired-coincide/99.png"
        );
        assert!(validate(&plan, &all(&plan)[..21]).is_err());
        assert!(validate(&plan, &["forged".into()]).is_err());
        let unknown = inspect(
            &thread(json!({"futureSchema":["keep"]})),
            &[root],
            InspectOptions::default(),
        )
        .unwrap();
        assert_eq!(unknown.candidates[0].status, Status::UnknownShape);
    }
    #[test]
    fn two_approved_roots_with_duplicate_names_keep_distinct_bindings() {
        let (dir, source, data, root) = fixture();
        let second = dir.path().canonicalize().unwrap().join("second");
        fs::create_dir(&second).unwrap();
        fs::write(source.join("same.png"), png()).unwrap();
        let mut cursor = Cursor::new(Vec::new());
        DynamicImage::new_rgb8(3, 3)
            .write_to(&mut cursor, ImageFormat::Png)
            .unwrap();
        fs::write(second.join("same.png"), cursor.into_inner()).unwrap();
        let root2 =
            ApprovedRoot::new("other".into(), PathBuf::from("/other-approved"), second).unwrap();
        let plan = inspect(
            &thread(json!([
                "/retired-coincide/same.png",
                "/other-approved/same.png"
            ])),
            &[root, root2],
            InspectOptions::default(),
        )
        .unwrap();
        let preview = validate(&plan, &all(&plan)).unwrap();
        let batch = materialize(&preview, &all(&plan), &data).unwrap();
        assert_ne!(
            batch.references[0].image.as_ref().unwrap().id,
            batch.references[1].image.as_ref().unwrap().id
        );
        assert_ne!(
            batch.references[0].reference.candidate.root_id,
            batch.references[1].reference.candidate.root_id
        );
    }
    #[test]
    fn managed_output_must_be_separate_and_decoder_dimensions_are_bounded() {
        let (_dir, source, data, root) = fixture();
        fs::write(source.join("image.png"), png()).unwrap();
        let plan = inspect(
            &thread(json!(["/retired-coincide/image.png"])),
            std::slice::from_ref(&root),
            InspectOptions::default(),
        )
        .unwrap();
        let preview = validate(&plan, &all(&plan)).unwrap();
        assert!(materialize(&preview, &all(&plan), &source).is_err());
        assert_eq!(fs::read_dir(&source).unwrap().count(), 1);
        let mut bytes = Cursor::new(Vec::new());
        DynamicImage::new_rgba8(32769, 1)
            .write_to(&mut bytes, ImageFormat::Png)
            .unwrap();
        fs::write(source.join("too-wide.png"), bytes.into_inner()).unwrap();
        let plan = inspect(
            &thread(json!(["/retired-coincide/too-wide.png"])),
            &[root],
            InspectOptions::default(),
        )
        .unwrap();
        let preview = validate(&plan, &all(&plan)).unwrap();
        assert_ne!(preview.references[0].status, Status::Ready);
        assert!(
            materialize(&preview, &all(&plan), &data)
                .unwrap()
                .references[0]
                .image
                .is_none()
        );
        assert!(!data.join("attachments").exists());
    }
}
